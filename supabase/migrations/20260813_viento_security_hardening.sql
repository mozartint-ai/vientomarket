create or replace function public.viento_is_admin()
returns boolean
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select exists(
    select 1 from public.viento_admins
    where user_id = (select auth.uid())
  );
$$;

revoke all on function public.viento_is_admin() from public, anon;
grant execute on function public.viento_is_admin() to authenticated;
revoke all on function public.viento_claim_admin(text) from public, anon;
grant execute on function public.viento_claim_admin(text) to authenticated;

drop policy if exists "viento admins self read" on public.viento_admins;
create policy "viento admins self read"
on public.viento_admins for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "viento public catalog read" on public.viento_catalog_products;
drop policy if exists "viento admin catalog write" on public.viento_catalog_products;
create policy "viento anonymous catalog read"
on public.viento_catalog_products for select to anon
using (active);
create policy "viento authenticated catalog read"
on public.viento_catalog_products for select to authenticated
using (active or public.viento_is_admin());
create policy "viento admin catalog insert"
on public.viento_catalog_products for insert to authenticated
with check (public.viento_is_admin());
create policy "viento admin catalog update"
on public.viento_catalog_products for update to authenticated
using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento admin catalog delete"
on public.viento_catalog_products for delete to authenticated
using (public.viento_is_admin());

drop policy if exists "viento public settings read" on public.viento_public_settings;
drop policy if exists "viento admin settings write" on public.viento_public_settings;
create policy "viento public settings read"
on public.viento_public_settings for select to anon, authenticated
using (true);
create policy "viento admin settings insert"
on public.viento_public_settings for insert to authenticated
with check (public.viento_is_admin());
create policy "viento admin settings update"
on public.viento_public_settings for update to authenticated
using (public.viento_is_admin()) with check (public.viento_is_admin());
create policy "viento admin settings delete"
on public.viento_public_settings for delete to authenticated
using (public.viento_is_admin());

create index if not exists viento_admin_bootstrap_claimed_by_idx
on private.viento_admin_bootstrap(claimed_by);
