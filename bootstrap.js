import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';

const SUPABASE_URL='https://sskkgtgboftvbzckrrhe.supabase.co';
const SUPABASE_KEY='sb_publishable_t5elcUG2x7uW3Oluz9xQ_A_DaOEZFu3';
const client=createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
const publicStateKeys={'viento-admin-content':'content','viento-admin-settings':'store-settings'};

function reportSyncError(error){
  console.error('Viento Supabase sync:',error);
  document.dispatchEvent(new CustomEvent('viento-sync-error',{detail:error}));
}

async function loadProducts(includeInactive=false){
  let query=client.from('viento_catalog_products').select('product_id,data,active').order('product_id');
  if(!includeInactive)query=query.eq('active',true);
  const {data,error}=await query;
  if(error)throw error;
  return(data||[]).map(row=>({...row.data,id:Number(row.product_id),active:row.active}));
}

async function loadPublicSettings(){
  const {data,error}=await client.from('viento_public_settings').select('key,value');
  if(error)throw error;
  (data||[]).forEach(row=>{
    if(row.key==='content')localStorage.setItem('viento-admin-content',JSON.stringify(row.value));
    if(row.key==='store-settings')localStorage.setItem('viento-admin-settings',JSON.stringify(row.value));
  });
}

async function loadAdminState(){
  const [{data:state,error:stateError},{data:orders,error:orderError},{data:requests,error:requestError},{data:subscribers,error:subscriberError}]=await Promise.all([
    client.from('viento_app_state').select('key,value'),
    client.from('viento_orders').select('*').order('date',{ascending:false}),
    client.from('viento_service_requests').select('*').order('created_at',{ascending:false}),
    client.from('viento_newsletter_subscribers').select('id,email,status,source,consented_at,created_at').order('created_at',{ascending:false})
  ]);
  if(stateError)throw stateError;
  if(orderError)throw orderError;
  if(requestError)throw requestError;
  if(subscriberError)throw subscriberError;
  const remoteKeys=new Set((state||[]).map(row=>row.key));
  const managedKeys=['viento-admin-discounts','viento-admin-drafts','viento-admin-abandoned','viento-admin-returns','viento-admin-collections','viento-admin-campaigns','viento-admin-payouts','viento-admin-channels','viento-admin-installed-apps','viento-admin-custom-apps','viento-admin-customers','viento-admin-activity','viento-shipping-zones','viento-payment-methods','viento-tax-settings','viento-notification-rules'];
  managedKeys.filter(key=>!remoteKeys.has(key)).forEach(key=>localStorage.removeItem(key));
  (state||[]).forEach(row=>localStorage.setItem(row.key,JSON.stringify(row.value)));
  localStorage.setItem('viento-admin-orders',JSON.stringify((orders||[]).map(row=>({
    id:row.order_id,customer:row.customer,email:row.email,phone:row.phone,city:row.city,date:row.date,
    district:row.district||'',address:row.address||'',postcode:row.postcode||'',
    status:row.status,payment:row.payment,items:row.items,total:Number(row.total),notes:row.notes||'',
    trackingCompany:row.tracking_company||'',trackingNumber:row.tracking_number||'',
    paymentProvider:row.payment_provider||'',paymentReference:row.payment_reference||''
  }))));
  localStorage.setItem('viento-service-requests',JSON.stringify(requests||[]));
  localStorage.setItem('viento-newsletter-subscribers',JSON.stringify(subscribers||[]));
}

function normalizeEmail(email){return String(email||'').trim().toLocaleLowerCase('tr-TR').slice(0,320)}

async function subscribeNewsletter(email){
  const normalized=normalizeEmail(email);
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized))throw new Error('Geçerli bir e-posta adresi girin.');
  const {error}=await client.from('viento_newsletter_subscribers').insert({email:normalized,status:'active',source:'storefront',consented_at:new Date().toISOString()});
  if(error&&error.code!=='23505')throw error;
  return{email:normalized,existing:error?.code==='23505'};
}

async function submitServiceRequest(values){
  const request={
    service:String(values.service||''),name:String(values.name||'').trim().slice(0,160),
    email:normalizeEmail(values.email),phone:String(values.phone||'').trim().slice(0,40),
    city:String(values.city||'').trim().slice(0,100),message:String(values.message||'').trim().slice(0,1500),status:'new'
  };
  if(request.name.length<2)throw new Error('Ad soyad alanını doldurun.');
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(request.email))throw new Error('Geçerli bir e-posta adresi girin.');
  if(request.phone.length<7)throw new Error('Geçerli bir telefon numarası girin.');
  if(request.message.length<10)throw new Error('Talebinizi en az 10 karakterle açıklayın.');
  const {error}=await client.from('viento_service_requests').insert(request);
  if(error)throw error;
  return true;
}

async function updateServiceRequestStatus(id,status){
  if(!['new','contacted','closed'].includes(status))throw new Error('Geçersiz talep durumu');
  const {error}=await client.from('viento_service_requests').update({status,updated_at:new Date().toISOString()}).eq('id',id);
  if(error)throw error;
}

async function saveState(key,value){
  if(key==='viento-admin-orders')return saveOrders(value);
  if(publicStateKeys[key]){
    const {error}=await client.from('viento_public_settings').upsert({key:publicStateKeys[key],value,updated_at:new Date().toISOString()});
    if(error)throw error;
    return;
  }
  const {error}=await client.from('viento_app_state').upsert({key,value,updated_at:new Date().toISOString()});
  if(error)throw error;
}

async function saveOrders(orders){
  if(!Array.isArray(orders)||!orders.length)return;
  const rows=orders.map(order=>({order_id:String(order.id),customer:order.customer,email:order.email,phone:order.phone||'',city:order.city||'',district:order.district||'',address:order.address||'',postcode:order.postcode||'',date:order.date,status:order.status,payment:order.payment,items:order.items,total:order.total,notes:order.notes||'',tracking_company:order.trackingCompany||'',tracking_number:order.trackingNumber||'',payment_provider:order.paymentProvider||'',payment_reference:order.paymentReference||'',updated_at:new Date().toISOString()}));
  const {error}=await client.from('viento_orders').upsert(rows,{onConflict:'order_id'});
  if(error)throw error;
}

async function saveProduct(product){
  const {error}=await client.from('viento_catalog_products').upsert({product_id:product.id,data:product,active:product.active!==false,updated_at:new Date().toISOString()},{onConflict:'product_id'});
  if(error)throw error;
}

async function demoCheckout(order,provider,scenario='success'){
  const {data,error}=await client.rpc('viento_demo_checkout',{p_order:order,p_provider:provider,p_scenario:scenario});
  if(error)throw error;
  return data;
}

async function currentUser(){
  const {data:{session}}=await client.auth.getSession();
  if(!session)return null;
  const {data:{user},error}=await client.auth.getUser();
  if(error)throw error;
  return user||null;
}

async function ensureCustomerProfile(){
  const user=await currentUser();
  if(!user)return null;
  const {data,error}=await client.from('viento_customer_profiles').select('*').eq('user_id',user.id).maybeSingle();
  if(error)throw error;
  if(data)return data;
  const profile={user_id:user.id,email:user.email||'',full_name:user.user_metadata?.full_name||'',phone:user.user_metadata?.phone||''};
  const {data:created,error:createError}=await client.from('viento_customer_profiles').upsert(profile,{onConflict:'user_id'}).select().single();
  if(createError)throw createError;
  return created;
}

async function getCustomerAccount(){
  const user=await currentUser();
  if(!user)return null;
  const profile=await ensureCustomerProfile();
  const [{data:addresses,error:addressError},{data:orders,error:orderError},{data:attempts,error:attemptError}]=await Promise.all([
    client.from('viento_customer_addresses').select('*').order('is_default',{ascending:false}).order('created_at'),
    client.from('viento_orders').select('*').order('date',{ascending:false}),
    client.from('viento_payment_attempts').select('*').order('created_at',{ascending:false}).limit(10)
  ]);
  if(addressError)throw addressError;
  if(orderError)throw orderError;
  if(attemptError)throw attemptError;
  return{user,profile,addresses:addresses||[],orders:orders||[],attempts:attempts||[]};
}

async function saveCustomerProfile(values){
  const user=await currentUser();
  if(!user)throw new Error('Oturum gerekli');
  const row={user_id:user.id,email:user.email||'',full_name:String(values.full_name||'').slice(0,160),phone:String(values.phone||'').slice(0,40),updated_at:new Date().toISOString()};
  const {data,error}=await client.from('viento_customer_profiles').upsert(row,{onConflict:'user_id'}).select().single();
  if(error)throw error;
  return data;
}

async function saveCustomerAddress(values){
  const user=await currentUser();
  if(!user)throw new Error('Oturum gerekli');
  if(values.is_default)await client.from('viento_customer_addresses').update({is_default:false}).eq('user_id',user.id);
  const row={user_id:user.id,title:String(values.title||'Ev').slice(0,80),city:String(values.city||'').slice(0,100),district:String(values.district||'').slice(0,100),address:String(values.address||'').slice(0,500),postcode:String(values.postcode||'').slice(0,20),is_default:Boolean(values.is_default),updated_at:new Date().toISOString()};
  if(values.id)row.id=values.id;
  const {data,error}=await client.from('viento_customer_addresses').upsert(row).select().single();
  if(error)throw error;
  return data;
}

async function deleteCustomerAddress(id){
  const {error}=await client.from('viento_customer_addresses').delete().eq('id',id);
  if(error)throw error;
}

async function uploadCatalogImage(file,productId,kind='main'){
  if(!['image/jpeg','image/png','image/webp'].includes(file?.type))throw new Error('JPEG, PNG veya WebP görsel seçin.');
  if(file.size>10*1024*1024)throw new Error('Görsel en fazla 10 MB olabilir.');
  const {data:{session},error:sessionError}=await client.auth.getSession();
  if(sessionError||!session)throw new Error('Yönetici oturumunuz sona ermiş. Tekrar giriş yapıp yüklemeyi deneyin.');
  const extension=({"image/jpeg":'jpg',"image/png":'png',"image/webp":'webp'})[file.type]||'webp';
  const safeKind=String(kind).replace(/[^a-z0-9-]/gi,'-').toLowerCase();
  const path=`products/${productId}/${safeKind}-${Date.now()}-${crypto.randomUUID()}.${extension}`;
  const {error}=await client.storage.from('viento-assets').upload(path,file,{cacheControl:'31536000',contentType:file.type,upsert:false});
  if(error){
    const status=Number(error.statusCode||error.status||0);
    if(status===401||status===403)throw new Error('Bu hesabın medya yükleme yetkisi doğrulanamadı. Yönetici hesabıyla yeniden giriş yapın.');
    throw new Error(`Supabase medya yüklemesi başarısız: ${error.message}`);
  }
  const {data}=client.storage.from('viento-assets').getPublicUrl(path);
  if(!data?.publicUrl)throw new Error('Yüklenen görselin genel adresi oluşturulamadı.');
  return data.publicUrl;
}

async function isAdmin(){
  const {data:{user}}=await client.auth.getUser();
  if(!user)return false;
  const {data,error}=await client.from('viento_admins').select('user_id').eq('user_id',user.id).maybeSingle();
  if(error)throw error;
  return Boolean(data);
}

window.VientoDB={
  client,saveState,saveProduct,demoCheckout,uploadCatalogImage,subscribeNewsletter,submitServiceRequest,updateServiceRequestStatus,reportSyncError,
  signOut:()=>client.auth.signOut()
};

window.VientoAuth={
  getSession:async()=>{const {data,error}=await client.auth.getSession();if(error)throw error;return data.session},
  signIn:async(email,password)=>{const {data,error}=await client.auth.signInWithPassword({email,password});if(error)throw error;return data},
  signUp:async({email,password,fullName,phone})=>{const {data,error}=await client.auth.signUp({email,password,options:{data:{full_name:fullName,phone},emailRedirectTo:`${location.origin}/#account`}});if(error)throw error;return data},
  signInWithGoogle:async()=>{const {data,error}=await client.auth.signInWithOAuth({provider:'google',options:{redirectTo:`${location.origin}/#account`}});if(error)throw error;return data},
  signOut:()=>client.auth.signOut(),getCustomerAccount,saveCustomerProfile,saveCustomerAddress,deleteCustomerAddress,
  onAuthStateChange:callback=>client.auth.onAuthStateChange(callback)
};

function setAuthMessage(message,type=''){
  const output=document.querySelector('#adminAuthMessage');
  if(!output)return;
  output.textContent=message;
  output.className=`admin-auth-message ${type}`;
}

async function claimAdminIfRequested(code){
  if(!code)return false;
  const {error}=await client.rpc('viento_claim_admin',{p_secret:code});
  if(error)throw error;
  return true;
}

async function waitForAdmin(){
  const gate=document.querySelector('#adminAuth');
  if(await isAdmin()){gate?.classList.remove('active');return}
  gate?.classList.add('active');
  const form=document.querySelector('#adminAuthForm'),submit=document.querySelector('#adminLogin'),signup=document.querySelector('#adminSignup');
  await new Promise(resolve=>{
    const finish=async code=>{
      if(code)await claimAdminIfRequested(code);
      if(!await isAdmin())throw new Error('Bu hesap Viento yöneticisi değil. İlk kurulumda yönetici kodunu girin.');
      gate.classList.remove('active');resolve();
    };
    form.addEventListener('submit',async event=>{
      event.preventDefault();submit.disabled=true;setAuthMessage('Giriş yapılıyor…');
      const values=new FormData(form);
      try{
        const {error}=await client.auth.signInWithPassword({email:values.get('email'),password:values.get('password')});
        if(error)throw error;
        await finish(String(values.get('bootstrapCode')||'').trim());
      }catch(error){setAuthMessage(error.message,'error')}finally{submit.disabled=false}
    });
    signup.addEventListener('click',async()=>{
      signup.disabled=true;setAuthMessage('Güvenli yönetici hesabı oluşturuluyor…');
      const values=new FormData(form),email=String(values.get('email')||''),password=String(values.get('password')||''),code=String(values.get('bootstrapCode')||'').trim();
      try{
        if(!code)throw new Error('İlk yönetici hesabı için kurulum kodu gerekli.');
        const {data,error}=await client.auth.signUp({email,password,options:{data:{full_name:'Viento Admin'},emailRedirectTo:`${location.origin}/admin`}});
        if(error)throw error;
        if(!data.session){setAuthMessage('Doğrulama bağlantısı e-posta adresinize gönderildi. Doğruladıktan sonra giriş yapın.','success');return}
        await finish(code);
      }catch(error){setAuthMessage(error.message,'error')}finally{signup.disabled=false}
    });
  });
}

async function start(){
  const adminPage=location.pathname.endsWith('/admin')||location.pathname.endsWith('/admin.html');
  try{
    if(adminPage){
      await waitForAdmin();
      const [remoteProducts]=await Promise.all([loadProducts(true),loadPublicSettings(),loadAdminState()]);
      window.VientoRemoteProducts=remoteProducts;
      await import('./app.js');
      await import('./admin.js');
      document.documentElement.classList.add('viento-ready');
    }else{
      const [remoteProducts]=await Promise.all([loadProducts(false),loadPublicSettings()]);
      window.VientoRemoteProducts=remoteProducts;
      await import('./app.js');
      document.documentElement.classList.add('viento-ready');
    }
  }catch(error){
    reportSyncError(error);
    setAuthMessage(`Canlı altyapıya bağlanılamadı: ${error.message}`,'error');
    document.querySelector('#siteBootError')?.classList.add('active');
  }
}

start();
