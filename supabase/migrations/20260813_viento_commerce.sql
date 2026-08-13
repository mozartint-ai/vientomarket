create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists public.viento_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

create table if not exists private.viento_admin_bootstrap (
  singleton boolean primary key default true check (singleton),
  secret_hash text not null,
  claimed_at timestamptz,
  claimed_by uuid references auth.users(id)
);

insert into private.viento_admin_bootstrap(singleton, secret_hash)
values (true, encode(extensions.digest('hVxCypNE6f7c80xe6dIpfYWo', 'sha256'), 'hex'))
on conflict (singleton) do nothing;

create table if not exists public.viento_catalog_products (
  product_id bigint primary key,
  data jsonb not null,
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.viento_public_settings (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.viento_app_state (
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create sequence if not exists public.viento_order_seq start with 1100;

create table if not exists public.viento_orders (
  order_id text primary key,
  customer text not null,
  email text not null,
  phone text,
  city text,
  date timestamptz not null default now(),
  status text not null default 'Hazırlanıyor',
  payment text not null default 'Bekliyor',
  items jsonb not null check (jsonb_typeof(items) = 'array'),
  total numeric(12,2) not null check (total >= 0),
  notes text,
  updated_at timestamptz not null default now()
);

create or replace function public.viento_is_admin()
returns boolean
language sql
stable
security definer set search_path = public, pg_temp
as $$
  select exists(select 1 from public.viento_admins where user_id = auth.uid());
$$;

create or replace function public.viento_claim_admin(p_secret text)
returns boolean
language plpgsql
security definer set search_path = public, private, extensions, pg_temp
as $$
declare
  bootstrap private.viento_admin_bootstrap%rowtype;
begin
  if auth.uid() is null then raise exception 'Oturum gerekli'; end if;
  select * into bootstrap from private.viento_admin_bootstrap where singleton = true for update;
  if bootstrap.claimed_at is not null then raise exception 'İlk yönetici kurulumu tamamlanmış'; end if;
  if bootstrap.secret_hash <> encode(digest(p_secret, 'sha256'), 'hex') then raise exception 'Kurulum kodu geçersiz'; end if;
  insert into public.viento_admins(user_id, email)
  select auth.uid(), email from auth.users where id = auth.uid()
  on conflict (user_id) do nothing;
  update private.viento_admin_bootstrap set claimed_at = now(), claimed_by = auth.uid() where singleton = true;
  return true;
end;
$$;

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
  insert into public.viento_orders(order_id, customer, email, phone, city, status, payment, items, total, notes)
  values (
    generated_id,
    left(coalesce(p_order->>'customer','Misafir müşteri'), 160),
    left(p_order->>'email', 320),
    left(coalesce(p_order->>'phone',''), 40),
    left(coalesce(p_order->>'city',''), 100),
    'Hazırlanıyor',
    'Bekliyor',
    p_order->'items',
    calculated_total,
    left(coalesce(p_order->>'notes',''), 1000)
  );
  return jsonb_build_object('id', generated_id, 'total', calculated_total);
end;
$$;

alter table public.viento_admins enable row level security;
alter table public.viento_catalog_products enable row level security;
alter table public.viento_public_settings enable row level security;
alter table public.viento_app_state enable row level security;
alter table public.viento_orders enable row level security;

create policy "viento admins self read" on public.viento_admins for select to authenticated using (user_id = auth.uid());
create policy "viento public catalog read" on public.viento_catalog_products for select to anon, authenticated using (active or public.viento_is_admin());
create policy "viento admin catalog write" on public.viento_catalog_products for all to authenticated using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento public settings read" on public.viento_public_settings for select to anon, authenticated using (true);
create policy "viento admin settings write" on public.viento_public_settings for all to authenticated using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento admin state access" on public.viento_app_state for all to authenticated using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento admin orders access" on public.viento_orders for all to authenticated using (public.viento_is_admin()) with check (public.viento_is_admin());

grant select on public.viento_catalog_products, public.viento_public_settings to anon, authenticated;
grant select, insert, update, delete on public.viento_catalog_products, public.viento_public_settings, public.viento_app_state, public.viento_orders to authenticated;
grant select on public.viento_admins to authenticated;
grant execute on function public.viento_is_admin() to anon, authenticated;
revoke all on function public.viento_claim_admin(text) from public;
grant execute on function public.viento_claim_admin(text) to authenticated;
revoke all on function public.viento_place_order(jsonb) from public;
grant execute on function public.viento_place_order(jsonb) to anon, authenticated;

insert into public.viento_public_settings(key, value) values
  ('content', '{"announcementActive":true,"announcementText":"25.000 TL üzeri ücretsiz planlı teslimat","heroEyebrow":"YENİ KOLEKSİYON · 2026","heroTitle":"Evinizin ritmini yeniden kurun","heroDescription":"Doğal malzemeler, rafine detaylar ve uzun yıllar sizinle yaşayacak zamansız mobilyalar."}'::jsonb),
  ('store', '{"name":"Viento Market","currency":"TRY","founded":2021}'::jsonb)
on conflict (key) do nothing;
