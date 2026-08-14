import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const read = name => readFile(new URL(name, root), 'utf8');

test('every static admin button has an explicit action contract', async () => {
  const [html, admin, bootstrap] = await Promise.all([
    read('admin.html'),
    read('admin.js'),
    read('bootstrap.js'),
  ]);
  const code = `${admin}\n${bootstrap}`;
  const buttons = [...html.matchAll(/<button\b([^>]*)>/gi)];
  assert.ok(buttons.length >= 150, 'expected the full admin control surface');

  for (const [, attributes] of buttons) {
    const id = attributes.match(/\bid="([^"]+)"/)?.[1];
    const hasDataAction = /\bdata-[\w-]+(?:=|\s|$)/.test(attributes);
    const isSubmit = /\btype="submit"/.test(attributes);
    assert.ok(id || hasDataAction || isSubmit, `button lacks action contract: ${attributes}`);
    if (id) {
      assert.ok(
        code.includes(`#${id}`) || code.includes(`'${id}'`) || code.includes(`"${id}"`),
        `button #${id} is not referenced by the application code`,
      );
    }
  }
});

test('critical admin controls are wired to real behavior', async () => {
  const [html, admin] = await Promise.all([read('admin.html'), read('admin.js')]);
  for (const marker of [
    'data-chart-metric="revenue"',
    'data-return-filter="İnceleniyor"',
    'data-discount-filter="Aktif"',
    'id="productSortToggle"',
    'id="customizeTheme"',
    'data-provider-action="bank"',
    'data-notification-filter="action"',
    'id="shippingZonesTable"',
  ]) assert.match(html, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));

  for (const marker of [
    'renderDashboardChart',
    'importProductFile',
    'parseCsv',
    'renderPaymentMethods',
    'renderShippingZones',
    "toast('Dışa aktarılacak kayıt yok')",
  ]) assert.ok(admin.includes(marker), `missing behavior: ${marker}`);
});

test('admin does not ship fabricated operational metrics or demo users', async () => {
  const [html, admin] = await Promise.all([read('admin.html'), read('admin.js')]);
  const source = `${html}\n${admin}`;
  for (const fabricated of [
    'Operasyon Demo',
    'Pazarlama Ajansı',
    '>284<',
    '%18,6',
    '126400',
    '28440',
    'Dosya okundu. Canlı içe aktarım için alan eşleştirmesi hazır.',
    'İadeyi tamamla',
    'Banka hesabına',
    'style="--score:86"',
    "rating:'5.0'",
    'fast:true',
  ]) assert.ok(!source.includes(fabricated), `fabricated value remains: ${fabricated}`);
});

test('database hardening migration preserves browser RPCs with least privilege', async () => {
  const sql = await read('supabase/migrations/20260814000000_viento_runtime_hardening.sql');
  assert.match(sql, /private\.viento_claim_admin_impl/);
  assert.match(sql, /private\.viento_demo_checkout_impl/);
  assert.match(sql, /security invoker/);
  assert.match(sql, /grant execute on function private\.viento_demo_checkout_impl[^;]+to authenticated/);
  assert.match(sql, /revoke all on table public\.viento_catalog_products from anon, authenticated/);
  assert.match(sql, /grant insert on table public\.viento_service_requests to anon/);
  assert.match(sql, /viento_service_requests_user_id_idx/);
});

test('admin renders untrusted state defensively and avoids an unusable order RPC', async () => {
  const [admin, bootstrap] = await Promise.all([read('admin.js'), read('bootstrap.js')]);
  assert.match(admin, /adminSafeColor/);
  assert.match(admin, /formatShortDate/);
  assert.match(admin, /data-lead-status="\$\{adminSafe\(request\.id\)\}"/);
  assert.doesNotMatch(bootstrap, /\bplaceOrder\b/);
  assert.doesNotMatch(bootstrap, /\bfetch\s*=|fetch:\s*fetch\b/);
});
