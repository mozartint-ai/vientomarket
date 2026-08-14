-- Reconcile the production Viento schema with least-privilege Data API access.
-- This migration preserves all existing catalog, order, customer, and state data.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

create index if not exists viento_service_requests_user_id_idx
  on public.viento_service_requests (user_id);

-- Keep privileged implementations out of the exposed public API schema.
create or replace function private.viento_claim_admin_impl(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  bootstrap private.viento_admin_bootstrap%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Oturum gerekli';
  end if;

  select * into bootstrap
  from private.viento_admin_bootstrap
  where singleton = true
  for update;

  if not found then
    raise exception 'İlk yönetici kurulum kaydı bulunamadı';
  end if;
  if bootstrap.claimed_at is not null then
    raise exception 'İlk yönetici kurulumu tamamlanmış';
  end if;
  if bootstrap.secret_hash <> encode(digest(p_secret, 'sha256'), 'hex') then
    raise exception 'Kurulum kodu geçersiz';
  end if;

  insert into public.viento_admins (user_id, email)
  select auth.uid(), email from auth.users where id = auth.uid()
  on conflict (user_id) do nothing;

  update private.viento_admin_bootstrap
  set claimed_at = now(), claimed_by = auth.uid()
  where singleton = true;

  return true;
end;
$$;

revoke all on function private.viento_claim_admin_impl(text) from public;
grant execute on function private.viento_claim_admin_impl(text) to authenticated;

create or replace function public.viento_claim_admin(p_secret text)
returns boolean
language sql
security invoker
set search_path = private, pg_temp
as $$
  select private.viento_claim_admin_impl(p_secret);
$$;

revoke all on function public.viento_claim_admin(text) from public, anon;
grant execute on function public.viento_claim_admin(text) to authenticated;

create or replace function private.viento_demo_checkout_impl(
  p_order jsonb,
  p_provider text,
  p_scenario text default 'success'
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  item jsonb;
  product_price numeric;
  quantity integer;
  calculated_total numeric := 0;
  generated_id text;
  generated_reference text;
  attempt_status text;
begin
  if auth.uid() is null then
    raise exception 'Demo ödeme için müşteri oturumu gerekli';
  end if;
  if p_provider not in ('iyzico_demo', 'paytr_demo') then
    raise exception 'Demo ödeme sağlayıcısı geçersiz';
  end if;
  if p_scenario not in ('success', 'failure') then
    raise exception 'Demo senaryosu geçersiz';
  end if;
  if jsonb_typeof(coalesce(p_order -> 'items', '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_order -> 'items', '[]'::jsonb)) = 0 then
    raise exception 'Sepet boş';
  end if;
  if coalesce(p_order ->> 'email', '') !~ '^[^@]+@[^@]+\.[^@]+$' then
    raise exception 'Geçerli e-posta gerekli';
  end if;

  for item in select value from jsonb_array_elements(p_order -> 'items') loop
    begin
      quantity := greatest(1, least(20, coalesce((item ->> 'qty')::integer, 1)));
    exception when invalid_text_representation then
      raise exception 'Ürün adedi geçersiz';
    end;

    select (data ->> 'price')::numeric into product_price
    from public.viento_catalog_products
    where product_id = (item ->> 'id')::bigint and active = true;

    if product_price is null then
      raise exception 'Ürün bulunamadı';
    end if;
    calculated_total := calculated_total + product_price * quantity;
  end loop;

  generated_reference := upper(replace(p_provider, '_demo', ''))
    || '-DEMO-' || upper(encode(gen_random_bytes(6), 'hex'));
  attempt_status := case when p_scenario = 'failure' then 'failed' else 'success' end;

  insert into public.viento_payment_attempts
    (user_id, provider, status, amount, reference)
  values
    (auth.uid(), p_provider, attempt_status, calculated_total, generated_reference);

  if attempt_status = 'failed' then
    return jsonb_build_object(
      'success', false,
      'reference', generated_reference,
      'total', calculated_total
    );
  end if;

  generated_id := 'VM' || lpad(nextval('public.viento_order_seq')::text, 5, '0');
  insert into public.viento_orders (
    order_id, user_id, customer, email, phone, city, district, address,
    postcode, status, payment, payment_provider, payment_reference,
    items, total, notes
  ) values (
    generated_id,
    auth.uid(),
    left(coalesce(p_order ->> 'customer', 'Misafir müşteri'), 160),
    left(p_order ->> 'email', 320),
    left(coalesce(p_order ->> 'phone', ''), 40),
    left(coalesce(p_order ->> 'city', ''), 100),
    left(coalesce(p_order ->> 'district', ''), 100),
    left(coalesce(p_order ->> 'address', ''), 500),
    left(coalesce(p_order ->> 'postcode', ''), 20),
    'Hazırlanıyor',
    'Demo ödendi',
    p_provider,
    generated_reference,
    p_order -> 'items',
    calculated_total,
    left(coalesce(p_order ->> 'notes', ''), 1000)
  );

  update public.viento_payment_attempts
  set order_id = generated_id
  where reference = generated_reference;

  return jsonb_build_object(
    'success', true,
    'id', generated_id,
    'reference', generated_reference,
    'total', calculated_total
  );
end;
$$;

revoke all on function private.viento_demo_checkout_impl(jsonb, text, text) from public;
grant execute on function private.viento_demo_checkout_impl(jsonb, text, text) to authenticated;

create or replace function public.viento_demo_checkout(
  p_order jsonb,
  p_provider text,
  p_scenario text default 'success'
)
returns jsonb
language sql
security invoker
set search_path = private, pg_temp
as $$
  select private.viento_demo_checkout_impl(p_order, p_provider, p_scenario);
$$;

revoke all on function public.viento_demo_checkout(jsonb, text, text) from public, anon;
grant execute on function public.viento_demo_checkout(jsonb, text, text) to authenticated;

-- Remove automatic broad grants and add only what the browser application uses.
revoke all on table public.viento_admins from anon, authenticated;
grant select on table public.viento_admins to authenticated;

revoke all on table public.viento_app_state from anon, authenticated;
grant select, insert, update, delete on table public.viento_app_state to authenticated;

revoke all on table public.viento_catalog_products from anon, authenticated;
grant select on table public.viento_catalog_products to anon;
grant select, insert, update, delete on table public.viento_catalog_products to authenticated;

revoke all on table public.viento_customer_profiles from anon, authenticated;
grant select, insert, update, delete on table public.viento_customer_profiles to authenticated;

revoke all on table public.viento_customer_addresses from anon, authenticated;
grant select, insert, update, delete on table public.viento_customer_addresses to authenticated;

revoke all on table public.viento_orders from anon, authenticated;
grant select, insert, update, delete on table public.viento_orders to authenticated;

revoke all on table public.viento_payment_attempts from anon, authenticated;
grant select on table public.viento_payment_attempts to authenticated;

revoke all on table public.viento_public_settings from anon, authenticated;
grant select on table public.viento_public_settings to anon;
grant select, insert, update, delete on table public.viento_public_settings to authenticated;

revoke all on table public.viento_newsletter_subscribers from anon, authenticated;
grant insert on table public.viento_newsletter_subscribers to anon;
grant select, insert on table public.viento_newsletter_subscribers to authenticated;

revoke all on table public.viento_service_requests from anon, authenticated;
grant insert on table public.viento_service_requests to anon;
grant select, insert, update on table public.viento_service_requests to authenticated;

revoke all on sequence public.viento_order_seq from anon, authenticated;

-- Recreate Viento policies with one-time helper evaluation per statement.
drop policy if exists "viento admin state access" on public.viento_app_state;
create policy "viento admin state access"
on public.viento_app_state for all to authenticated
using ((select public.viento_is_admin()))
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin catalog insert" on public.viento_catalog_products;
create policy "viento admin catalog insert"
on public.viento_catalog_products for insert to authenticated
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin catalog update" on public.viento_catalog_products;
create policy "viento admin catalog update"
on public.viento_catalog_products for update to authenticated
using ((select public.viento_is_admin()))
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin catalog delete" on public.viento_catalog_products;
create policy "viento admin catalog delete"
on public.viento_catalog_products for delete to authenticated
using ((select public.viento_is_admin()));

drop policy if exists "viento authenticated catalog read" on public.viento_catalog_products;
create policy "viento authenticated catalog read"
on public.viento_catalog_products for select to authenticated
using (active or (select public.viento_is_admin()));

drop policy if exists "viento customer profile read" on public.viento_customer_profiles;
create policy "viento customer profile read"
on public.viento_customer_profiles for select to authenticated
using (user_id = (select auth.uid()) or (select public.viento_is_admin()));

drop policy if exists "viento customer addresses read" on public.viento_customer_addresses;
create policy "viento customer addresses read"
on public.viento_customer_addresses for select to authenticated
using (user_id = (select auth.uid()) or (select public.viento_is_admin()));

drop policy if exists "viento admin orders insert" on public.viento_orders;
create policy "viento admin orders insert"
on public.viento_orders for insert to authenticated
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin orders update" on public.viento_orders;
create policy "viento admin orders update"
on public.viento_orders for update to authenticated
using ((select public.viento_is_admin()))
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin orders delete" on public.viento_orders;
create policy "viento admin orders delete"
on public.viento_orders for delete to authenticated
using ((select public.viento_is_admin()));

drop policy if exists "viento authenticated orders read" on public.viento_orders;
create policy "viento authenticated orders read"
on public.viento_orders for select to authenticated
using (user_id = (select auth.uid()) or (select public.viento_is_admin()));

drop policy if exists "viento authenticated payment attempts read" on public.viento_payment_attempts;
create policy "viento authenticated payment attempts read"
on public.viento_payment_attempts for select to authenticated
using (user_id = (select auth.uid()) or (select public.viento_is_admin()));

drop policy if exists "viento admin settings insert" on public.viento_public_settings;
create policy "viento admin settings insert"
on public.viento_public_settings for insert to authenticated
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin settings update" on public.viento_public_settings;
create policy "viento admin settings update"
on public.viento_public_settings for update to authenticated
using ((select public.viento_is_admin()))
with check ((select public.viento_is_admin()));

drop policy if exists "viento admin settings delete" on public.viento_public_settings;
create policy "viento admin settings delete"
on public.viento_public_settings for delete to authenticated
using ((select public.viento_is_admin()));

drop policy if exists "viento admin media insert" on storage.objects;
create policy "viento admin media insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'viento-assets' and (select public.viento_is_admin()));

drop policy if exists "viento admin media update" on storage.objects;
create policy "viento admin media update"
on storage.objects for update to authenticated
using (bucket_id = 'viento-assets' and (select public.viento_is_admin()))
with check (bucket_id = 'viento-assets' and (select public.viento_is_admin()));

drop policy if exists "viento admin media delete" on storage.objects;
create policy "viento admin media delete"
on storage.objects for delete to authenticated
using (bucket_id = 'viento-assets' and (select public.viento_is_admin()));
