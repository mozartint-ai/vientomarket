import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir, stat } from 'node:fs/promises';

const read = file => readFile(new URL(`../${file}`, import.meta.url), 'utf8');

test('storefront has real newsletter and service request forms', async () => {
  const [html, app, bootstrap] = await Promise.all([read('index.html'), read('app.js'), read('bootstrap.js')]);
  assert.match(html, /id="newsletterForm"/);
  assert.match(html, /id="serviceRequestForm"/);
  assert.match(app, /subscribeNewsletter/);
  assert.match(app, /submitServiceRequest/);
  assert.match(bootstrap, /viento_newsletter_subscribers/);
  assert.match(bootstrap, /viento_service_requests/);
});

test('admin exposes no fake visitor count or placeholder order customer', async () => {
  const [html, js] = await Promise.all([read('admin.html'), read('admin.js')]);
  assert.doesNotMatch(html, />24<\/strong><span>aktif ziyaretçi/);
  assert.doesNotMatch(js, /musteri@example\.com/);
  assert.match(html, /id="orderCreateForm"/);
  assert.match(html, /id="view-leads"/);
});

test('all seeded catalog variant image paths exist', async () => {
  const files = await readdir(new URL('../assets/furniture/variants/', import.meta.url));
  const expected = [];
  for (const slug of ['oturma', 'salon', 'yemek', 'yatak', 'ofis']) {
    for (let product = 1; product <= 30; product++) {
      for (let variant = 1; variant <= 5; variant++) expected.push(`${slug}-${String(product).padStart(2, '0')}-v${variant}.webp`);
    }
  }
  assert.equal(files.length, 750);
  for (const file of expected) {
    assert.ok(files.includes(file), `missing ${file}`);
    assert.ok((await stat(new URL(`../assets/furniture/variants/${file}`, import.meta.url))).size > 0, `empty ${file}`);
  }
});

test('product links use clean URL rewrite', async () => {
  const [app, vercel] = await Promise.all([read('app.js'), read('vercel.json')]);
  assert.match(app, /\/products\/\$\{productSlug\(p\)\}/);
  assert.equal(JSON.parse(vercel).rewrites[0].source, '/products/:slug');
});

test('every static storefront button has an explicit action contract', async () => {
  const [html, app, bootstrap] = await Promise.all([read('index.html'), read('app.js'), read('bootstrap.js')]);
  const code = `${app}\n${bootstrap}`;
  const buttons = [...html.matchAll(/<button\b([^>]*)>/gi)];
  assert.ok(buttons.length >= 75, 'expected the full storefront control surface');

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

test('storefront does not fabricate ratings or delivery dates and escapes remote content', async () => {
  const [html, app] = await Promise.all([read('index.html'), read('app.js')]);
  const source = `${html}\n${app}`;
  assert.doesNotMatch(source, /code\.startsWith\('34'\).*3–7/);
  assert.doesNotMatch(app, /heroTitle\.replace\([^)]*<br>/);
  assert.match(app, /verifiedReviews/);
  assert.match(app, /safeText\(product\.name\)/);
  assert.match(source, /Kesin süre lojistik bağlantısı kurulduğunda hesaplanır/);
  assert.doesNotMatch(source, /12\.000\+ mutlu müşteri/);
  assert.doesNotMatch(source, /4\.8\/5/);
  assert.doesNotMatch(source, /7–21 iş günü/);
  assert.doesNotMatch(source, /Peşin fiyatına 6 taksit/);
  assert.match(app, /hydrateProductHotspots/);
});
