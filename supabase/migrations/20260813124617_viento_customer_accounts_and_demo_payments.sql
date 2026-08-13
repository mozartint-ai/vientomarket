create table if not exists public.viento_customer_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null default '',
  full_name text not null default '',
  phone text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.viento_customer_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null default 'Ev',
  city text not null,
  district text not null,
  address text not null,
  postcode text not null default '',
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.viento_orders
  add column if not exists user_id uuid references auth.users(id) on delete set null,
  add column if not exists district text,
  add column if not exists address text,
  add column if not exists postcode text,
  add column if not exists tracking_company text,
  add column if not exists tracking_number text,
  add column if not exists payment_provider text,
  add column if not exists payment_reference text;

create table if not exists public.viento_payment_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  provider text not null check (provider in ('iyzico_demo', 'paytr_demo')),
  status text not null check (status in ('success', 'failed')),
  amount numeric(12,2) not null check (amount >= 0),
  reference text not null unique,
  order_id text references public.viento_orders(order_id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists viento_customer_addresses_user_id_idx
  on public.viento_customer_addresses(user_id);
create index if not exists viento_orders_user_id_date_idx
  on public.viento_orders(user_id, date desc);
create index if not exists viento_payment_attempts_user_id_created_at_idx
  on public.viento_payment_attempts(user_id, created_at desc);
create index if not exists viento_payment_attempts_order_id_idx
  on public.viento_payment_attempts(order_id);

alter table public.viento_customer_profiles enable row level security;
alter table public.viento_customer_addresses enable row level security;
alter table public.viento_payment_attempts enable row level security;

drop policy if exists "viento customer profile read" on public.viento_customer_profiles;
drop policy if exists "viento customer profile insert" on public.viento_customer_profiles;
drop policy if exists "viento customer profile update" on public.viento_customer_profiles;
create policy "viento customer profile read"
on public.viento_customer_profiles for select to authenticated
using (user_id = (select auth.uid()) or public.viento_is_admin());
create policy "viento customer profile insert"
on public.viento_customer_profiles for insert to authenticated
with check (user_id = (select auth.uid()));
create policy "viento customer profile update"
on public.viento_customer_profiles for update to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

drop policy if exists "viento customer addresses read" on public.viento_customer_addresses;
drop policy if exists "viento customer addresses insert" on public.viento_customer_addresses;
drop policy if exists "viento customer addresses update" on public.viento_customer_addresses;
drop policy if exists "viento customer addresses delete" on public.viento_customer_addresses;
create policy "viento customer addresses read"
on public.viento_customer_addresses for select to authenticated
using (user_id = (select auth.uid()) or public.viento_is_admin());
create policy "viento customer addresses insert"
on public.viento_customer_addresses for insert to authenticated
with check (user_id = (select auth.uid()));
create policy "viento customer addresses update"
on public.viento_customer_addresses for update to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "viento customer addresses delete"
on public.viento_customer_addresses for delete to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "viento admin orders access" on public.viento_orders;
drop policy if exists "viento customer orders read" on public.viento_orders;
drop policy if exists "viento authenticated orders read" on public.viento_orders;
drop policy if exists "viento admin orders insert" on public.viento_orders;
drop policy if exists "viento admin orders update" on public.viento_orders;
drop policy if exists "viento admin orders delete" on public.viento_orders;
create policy "viento authenticated orders read"
on public.viento_orders for select to authenticated
using (user_id = (select auth.uid()) or public.viento_is_admin());
create policy "viento admin orders insert"
on public.viento_orders for insert to authenticated
with check (public.viento_is_admin());
create policy "viento admin orders update"
on public.viento_orders for update to authenticated
using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento admin orders delete"
on public.viento_orders for delete to authenticated
using (public.viento_is_admin());

drop policy if exists "viento customer payment attempts read" on public.viento_payment_attempts;
drop policy if exists "viento admin payment attempts read" on public.viento_payment_attempts;
drop policy if exists "viento authenticated payment attempts read" on public.viento_payment_attempts;
create policy "viento authenticated payment attempts read"
on public.viento_payment_attempts for select to authenticated
using (user_id = (select auth.uid()) or public.viento_is_admin());

grant select, insert, update on public.viento_customer_profiles to authenticated;
grant select, insert, update, delete on public.viento_customer_addresses to authenticated;
grant select on public.viento_payment_attempts to authenticated;

create or replace function public.viento_place_order(p_order jsonb)
returns jsonb
language plpgsql
security definer set search_path = public, pg_temp
as $$
declare
  item jsonb;
  product_price numeric;
  quantity integer;
  calculated_total numeric := 0;
  generated_id text;
begin
  if jsonb_array_length(coalesce(p_order->'items', '[]'::jsonb)) = 0 then raise exception 'Sepet boş'; end if;
  if coalesce(p_order->>'email','') !~ '^[^@]+@[^@]+\.[^@]+$' then raise exception 'Geçerli e-posta gerekli'; end if;
  for item in select value from jsonb_array_elements(p_order->'items') loop
    quantity := greatest(1, least(20, coalesce((item->>'qty')::integer, 1)));
    select (data->>'price')::numeric into product_price
    from public.viento_catalog_products
    where product_id = (item->>'id')::bigint and active = true;
    if product_price is null then raise exception 'Ürün bulunamadı'; end if;
    calculated_total := calculated_total + product_price * quantity;
  end loop;
  generated_id := 'VM' || lpad(nextval('public.viento_order_seq')::text, 5, '0');
  insert into public.viento_orders(
    order_id, user_id, customer, email, phone, city, district, address, postcode,
    status, payment, items, total, notes
  ) values (
    generated_id, auth.uid(), left(coalesce(p_order->>'customer','Misafir müşteri'), 160),
    left(p_order->>'email', 320), left(coalesce(p_order->>'phone',''), 40),
    left(coalesce(p_order->>'city',''), 100), left(coalesce(p_order->>'district',''), 100),
    left(coalesce(p_order->>'address',''), 500), left(coalesce(p_order->>'postcode',''), 20),
    'Hazırlanıyor', 'Bekliyor', p_order->'items', calculated_total,
    left(coalesce(p_order->>'notes',''), 1000)
  );
  return jsonb_build_object('id', generated_id, 'total', calculated_total);
end;
$$;

create or replace function public.viento_demo_checkout(
  p_order jsonb,
  p_provider text,
  p_scenario text default 'success'
)
returns jsonb
language plpgsql
security definer set search_path = public, extensions, pg_temp
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
  if auth.uid() is null then raise exception 'Demo ödeme için müşteri oturumu gerekli'; end if;
  if p_provider not in ('iyzico_demo', 'paytr_demo') then raise exception 'Demo ödeme sağlayıcısı geçersiz'; end if;
  if jsonb_array_length(coalesce(p_order->'items', '[]'::jsonb)) = 0 then raise exception 'Sepet boş'; end if;
  if coalesce(p_order->>'email','') !~ '^[^@]+@[^@]+\.[^@]+$' then raise exception 'Geçerli e-posta gerekli'; end if;

  for item in select value from jsonb_array_elements(p_order->'items') loop
    quantity := greatest(1, least(20, coalesce((item->>'qty')::integer, 1)));
    select (data->>'price')::numeric into product_price
    from public.viento_catalog_products
    where product_id = (item->>'id')::bigint and active = true;
    if product_price is null then raise exception 'Ürün bulunamadı'; end if;
    calculated_total := calculated_total + product_price * quantity;
  end loop;

  generated_reference := upper(replace(p_provider, '_demo', '')) || '-DEMO-' || upper(encode(gen_random_bytes(6), 'hex'));
  attempt_status := case when p_scenario = 'failure' then 'failed' else 'success' end;

  insert into public.viento_payment_attempts(user_id, provider, status, amount, reference)
  values (auth.uid(), p_provider, attempt_status, calculated_total, generated_reference);

  if attempt_status = 'failed' then
    return jsonb_build_object('success', false, 'reference', generated_reference, 'total', calculated_total);
  end if;

  generated_id := 'VM' || lpad(nextval('public.viento_order_seq')::text, 5, '0');
  insert into public.viento_orders(
    order_id, user_id, customer, email, phone, city, district, address, postcode,
    status, payment, payment_provider, payment_reference, items, total, notes
  ) values (
    generated_id, auth.uid(), left(coalesce(p_order->>'customer','Misafir müşteri'), 160),
    left(p_order->>'email', 320), left(coalesce(p_order->>'phone',''), 40),
    left(coalesce(p_order->>'city',''), 100), left(coalesce(p_order->>'district',''), 100),
    left(coalesce(p_order->>'address',''), 500), left(coalesce(p_order->>'postcode',''), 20),
    'Hazırlanıyor', 'Demo ödendi', p_provider, generated_reference,
    p_order->'items', calculated_total, left(coalesce(p_order->>'notes',''), 1000)
  );

  update public.viento_payment_attempts set order_id = generated_id where reference = generated_reference;
  return jsonb_build_object('success', true, 'id', generated_id, 'reference', generated_reference, 'total', calculated_total);
end;
$$;

revoke all on function public.viento_demo_checkout(jsonb, text, text) from public, anon;
grant execute on function public.viento_demo_checkout(jsonb, text, text) to authenticated;
revoke all on function public.viento_place_order(jsonb) from public, anon, authenticated;

drop policy if exists "viento admin media insert" on storage.objects;
drop policy if exists "viento admin media update" on storage.objects;
drop policy if exists "viento admin media delete" on storage.objects;
create policy "viento admin media insert"
on storage.objects for insert to authenticated
with check (bucket_id = 'viento-assets' and public.viento_is_admin());
create policy "viento admin media update"
on storage.objects for update to authenticated
using (bucket_id = 'viento-assets' and public.viento_is_admin())
with check (bucket_id = 'viento-assets' and public.viento_is_admin());
create policy "viento admin media delete"
on storage.objects for delete to authenticated
using (bucket_id = 'viento-assets' and public.viento_is_admin());

update storage.buckets
set public = true,
    allowed_mime_types = array['image/jpeg','image/png','image/webp'],
    file_size_limit = 10485760
where id = 'viento-assets';
