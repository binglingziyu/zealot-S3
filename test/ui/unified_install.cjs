const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const origin = process.env.ZEALOT_UI_URL || 'http://127.0.0.1:18913';
  const fixture = JSON.parse(fs.readFileSync(process.env.ZEALOT_UI_FIXTURE || 'tmp/unified-ui-fixture.json'));
  const output = path.resolve(process.env.ZEALOT_UI_OUTPUT || 'tmp/unified-install-review');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ reducedMotion: 'reduce' });
  const page = await context.newPage();
  const errors = [];
  const checks = [];
  page.on('pageerror', e => errors.push(e.message));
  try {
    for (const mode of ['light', 'dark']) {
      await page.goto(`${origin}/${fixture.path}`);
      await page.evaluate(mode => localStorage.setItem('zealot:appearance:guest', mode), mode);
      for (const [width, height] of [[1440, 1000], [768, 1000], [375, 900], [812, 375]]) {
        await page.setViewportSize({ width, height });
        const response = await page.goto(`${origin}/${fixture.path}`);
        assert.equal(response.status(), 200);
        assert.equal(await page.locator('html').getAttribute('data-bs-theme'), mode);
        await page.locator(`img[src*='/install_links/']`).waitFor();
        await page.waitForFunction(() => {
          const qr = document.querySelector("img[src*='/install_links/']");
          return qr?.complete && qr.naturalWidth > 0;
        });
        assert.equal(await page.locator(`a[href='/install_links/${fixture.path}/channels/${fixture.android_id}']`).count(), 1);
        assert.equal(await page.locator(`a[href='/install_links/${fixture.path}/channels/${fixture.ios_id}']`).count(), 1);
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        for (const button of await page.locator('.card-body a.btn').all()) {
          assert.ok((await button.boundingBox()).height >= 44);
        }
        await page.screenshot({ path: path.join(output, `install-${mode}-${width}x${height}.png`), fullPage: true });
        checks.push(`${mode} ${width}x${height}: both platforms, QR, no overflow, touch targets`);
      }
    }

    for (const [agent, channel] of [
      ['Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36', fixture.android_id],
      ['Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1', fixture.ios_id]
    ]) {
      const mobile = await browser.newContext({ userAgent: agent, viewport: { width: 390, height: 844 } });
      const tab = await mobile.newPage();
      await tab.goto(`${origin}/${fixture.path}`);
      assert.equal(new URL(tab.url()).pathname, `/install_links/${fixture.path}/channels/${channel}`);
      await mobile.close();
    }
    checks.push('Android and iPhone browsers reach the correct channel');

    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(`${origin}/users/sign_in`);
    await page.locator('#user_email').first().fill('s3-test@zealot.test');
    await page.locator('#user_password').fill('s3-test-admin-password');
    await Promise.all([
      page.waitForURL(url => !url.pathname.includes('sign_in')),
      page.locator('input[type=submit]').first().click()
    ]);
    await page.goto(`${origin}/apps/${fixture.app}`);
    const edit = `/apps/${fixture.app}/schemes/${fixture.scheme}/edit`;
    await page.getByRole('link', { name: '设置', exact: true }).click();
    await page.locator('#scheme_install_alias').waitFor({ state: 'visible' });
    await page.locator('#scheme_install_alias').fill('OrbitUnified');
    await page.locator('.modal form input[type=submit]').click();
    await page.locator("a[href='/OrbitUnified']").waitFor();
    await page.getByRole('link', { name: '设置', exact: true }).click();
    await page.locator('#scheme_install_alias').waitFor({ state: 'visible' });
    await page.locator('#scheme_install_alias').fill('apps');
    const invalid = page.waitForResponse(response => response.url().endsWith(`/schemes/${fixture.scheme}`) && response.status() === 422);
    await page.locator('.modal form input[type=submit]').click();
    assert.equal((await invalid).status(), 422);
    await page.locator('#scheme_install_alias.is-invalid').waitFor({ state: 'visible' });
    assert.ok(await page.locator('.invalid-feedback').first().isVisible());
    await page.screenshot({ path: path.join(output, 'alias-validation.png'), fullPage: true });
    checks.push('Management modal saves aliases and keeps invalid aliases visible with feedback');

    const guest = await browser.newContext();
    const tab = await guest.newPage();
    for (const suffix of [fixture.code, fixture.path, 'OrbitUnified']) {
      assert.equal((await tab.goto(`${origin}/${suffix}`)).status(), 200);
    }
    await guest.close();
    checks.push('Original code, previous alias and new alias all remain available');
    assert.deepEqual(errors, []);
    fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify({ checks, errors }, null, 2));
    console.log(JSON.stringify({ checks: checks.length, errors, output }));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exit(1); });
