// Run only against a disposable environment initialized by test/ui/fixtures.rb.
// Requires Playwright and Chrome; no application or storage credentials are logged.
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const origin = process.env.ZEALOT_UI_URL || 'http://127.0.0.1:18912';
  const fixture = JSON.parse(fs.readFileSync(process.env.ZEALOT_UI_FIXTURE || '/tmp/zealot-ui-fixture.json'));
  const output = process.env.ZEALOT_UI_OUTPUT || path.resolve('tmp/ui-review');
  fs.mkdirSync(output, { recursive: true });
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, reducedMotion: 'reduce' });
  const page = await context.newPage();
  const errors = [];
  const report = { layouts: [], checks: [], contrast: [] };
  page.on('pageerror', error => errors.push(error.message));
  page.on('response', response => {
    if (response.status() >= 400 && new URL(response.url()).origin === origin) errors.push(`${response.status()} ${new URL(response.url()).pathname}`);
  });
  async function visit(route) {
    const response = await page.goto(origin + route);
    assert.equal(response.status(), 200, route);
    await page.locator('body[data-controller="global"]').waitFor();
    await page.waitForFunction(() => window.Stimulus || document.querySelector('[data-appearance][aria-checked="true"]'));
  }
  async function theme(mode) {
    await page.locator('.theme-switch > button').click();
    await page.locator(`[data-appearance="${mode}"]`).click();
    await page.waitForFunction(mode => document.querySelector(`[data-appearance="${mode}"]`)?.getAttribute('aria-checked') === 'true', mode);
  }
  try {
    await page.goto(origin + '/users/sign_in');
    await page.locator('#user_email').first().fill(process.env.ZEALOT_UI_EMAIL || 's3-test@zealot.test');
    await page.locator('#user_password').fill(process.env.ZEALOT_UI_PASSWORD || 's3-test-admin-password');
    await Promise.all([page.waitForURL(url => !url.pathname.includes('sign_in')), page.locator('input[type=submit]').first().click()]);
    await page.locator('.metric-card').first().waitFor();
    assert.equal(await page.locator('.metric-card').count(), 8);
    report.checks.push('Admin dashboard renders all eight statistics');

    for (const mode of ['light', 'dark']) {
      await theme(mode);
      await page.reload();
      assert.equal(await page.locator('html').getAttribute('data-bs-theme'), mode);
      for (const width of [375, 768, 1024, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        for (const [name, route, required] of [
          ['dashboard', '/', '.metric-card'],
          ['apps', '/apps', '.widget-app'],
          ['channel', fixture.channel, '.channel-summary']
        ]) {
          await visit(route);
          await page.locator(required).first().waitFor();
          const layout = await page.evaluate(() => ({ width: innerWidth, scroll: document.documentElement.scrollWidth }));
          assert.ok(layout.scroll <= width + 1, `${mode}/${width}/${name} overflows: ${layout.scroll}`);
          if (name === 'channel' && width >= 1024) assert.ok((await page.locator('.channel-summary').boundingBox()).height < 150);
          if (name === 'dashboard') {
            for (const metric of await page.locator('.metric-card').all()) assert.ok(await metric.isVisible());
          }
          assert.equal(await page.locator('h1').count(), 1, `${name} has a single page heading`);
          await page.screenshot({ path: path.join(output, `${name}-${mode}-${width}.png`), fullPage: true });
          report.layouts.push({ name, mode, width, horizontalOverflow: false });
        }
      }
      // Check actual semantic foreground/background pairs, including muted text and primary links.
      const pairs = await page.evaluate(() => {
        const style = getComputedStyle(document.documentElement);
        return ['--zl-text', '--zl-muted', '--zl-primary'].flatMap(fg => ['--zl-surface', '--zl-canvas'].map(bg => [fg, bg, style.getPropertyValue(fg).trim(), style.getPropertyValue(bg).trim()]));
      });
      const luminance = hex => {
        assert.match(hex, /^#[0-9a-f]{6}$/i, 'Expected rendered semantic color token');
        const rgb = hex.replace('#', '').match(/../g).map(value => parseInt(value, 16) / 255).map(value => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
        return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
      };
      for (const [foreground, background, fg, bg] of pairs) {
        const a = luminance(fg), b = luminance(bg), ratio = (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
        assert.ok(ratio >= 4.5, `${mode} ${foreground}/${background}: ${ratio}`);
        report.contrast.push({ mode, foreground, background, ratio: +ratio.toFixed(2) });
      }
    }
    report.checks.push('Explicit theme persists across full reloads and all navigation');
    await page.setViewportSize({ width: 1440, height: 1000 });
    await visit('/apps');
    await theme('auto');
    for (const mode of ['dark', 'light']) {
      await page.emulateMedia({ colorScheme: mode });
      await page.waitForFunction(mode => document.documentElement.dataset.bsTheme === mode, mode);
    }
    report.checks.push('System theme reacts live to OS appearance changes');

    // Search, sorting, no-results recovery and archived search preserve their route.
    await page.locator('input[name="search"]').fill('Orbit');
    await Promise.all([page.waitForURL(url => url.searchParams.get('search') === 'Orbit'), page.locator('.catalog-search button[type="submit"]').click()]);
    assert.equal(await page.locator('.widget-app').count(), 1);
    await page.locator('.catalog-search a').first().click();
    await page.waitForURL(url => url.searchParams.get('sort') === 'asc');
    assert.equal(new URL(page.url()).searchParams.get('search'), 'Orbit');
    await page.locator('input[name="search"]').fill('nonexistent-application');
    await page.locator('.catalog-search button[type="submit"]').click();
    await page.waitForURL(url => url.searchParams.get('search') === 'nonexistent-application');
    assert.equal(await page.locator('.widget-app').count(), 0);
    assert.ok(await page.locator('input[name="search"]').isVisible());
    await visit(fixture.archived);
    await page.locator('input[name="search"]').fill('Archived');
    await page.locator('.catalog-search button[type="submit"]').click();
    await page.waitForURL(url => url.searchParams.get('search') === 'Archived');
    assert.equal(new URL(page.url()).pathname, fixture.archived);
    assert.equal(await page.locator('.widget-app').count(), 1);
    report.checks.push('Search, sort, no-results recovery and archived search');

    // Turbo modal still renders and closes, without navigating out of the catalog.
    await visit('/apps');
    await page.locator('.page-actions a[data-turbo-frame="modal"]').click();
    await page.locator('.modal.show').waitFor();
    assert.ok(await page.locator('.modal.show input:not([type=hidden])').first().isVisible());
    await page.screenshot({ path: path.join(output, 'new-app-modal.png'), fullPage: true });
    await page.locator('.modal.show [data-bs-dismiss="modal"]').first().click();
    await page.locator('.modal.show').waitFor({ state: 'hidden' });
    report.checks.push('Turbo create-app modal opens and closes');

    await visit(fixture.channel + '?per_page=2');
    assert.equal(await page.locator('.channel-webhooks .card-body').isVisible(), false);
    await page.locator('.channel-webhooks > summary').click();
    await page.locator('.channel-webhooks .card-body').waitFor({ state: 'visible' });
    await page.locator('.channel-webhooks > summary').click();
    await page.locator('.channel-webhooks .card-body').waitFor({ state: 'hidden' });
    report.checks.push('Secondary channel configuration expands and collapses');
    assert.ok(await page.locator('.channel-workspace .pagination').isVisible());
    const next = page.locator('.channel-workspace .pagination a[rel=next]').first();
    await next.click();
    await page.waitForURL(url => url.searchParams.get('page') === '2');
    assert.equal(await page.locator('.channel-workspace .product-item').count(), 2);
    await page.locator('.channel-summary a.btn').click();
    await page.locator('[data-controller="direct-upload"]').waitFor();
    report.checks.push('Channel pagination and upload navigation');
    await visit(fixture.empty_channel);
    assert.equal(await page.locator('.channel-workspace .product-item').count(), 0);
    report.checks.push('Channel empty state');

    // Shared components on secondary pages use the same theme and responsive shell.
    for (const mode of ['light', 'dark']) {
      await theme(mode);
      for (const width of [375, 1440]) {
        await page.setViewportSize({ width, height: 1000 });
        for (const route of ['/groups', '/storage_profiles', '/debug_files', '/admin/users', '/admin/settings']) {
          await visit(route);
          const scroll = await page.evaluate(() => document.documentElement.scrollWidth);
          assert.ok(scroll <= width + 1, `${mode}/${width}/${route} overflows: ${scroll}`);
          report.layouts.push({ name: route, mode, width, horizontalOverflow: false });
        }
      }
    }
    report.checks.push('Shared shell on groups, storage, debug files, users and settings');

    await visit('/');
    await page.waitForFunction(() => window.frameworkManager?.initialized);
    await page.locator('[data-zealot-toggle="sidebar"]').click();
    await page.waitForFunction(() => document.body.classList.contains('sidebar-collapse'));
    await page.locator('[data-zealot-toggle="sidebar"]').click();
    await page.waitForFunction(() => !document.body.classList.contains('sidebar-collapse'));
    report.checks.push('Desktop sidebar collapses and expands once per click');

    // Native keyboard navigation reaches the skip link and main content.
    await visit('/');
    await page.keyboard.press('Tab');
    assert.equal(await page.locator(':focus').getAttribute('class'), 'skip-link');
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => document.activeElement?.id === 'main-content');
    report.checks.push('Keyboard skip navigation');
    await page.setViewportSize({ width: 375, height: 812 });
    await visit('/');
    await page.waitForFunction(() => window.frameworkManager?.initialized);
    await page.locator('[data-zealot-toggle="sidebar"]').click();
    await page.waitForFunction(() => document.body.classList.contains('sidebar-open'));
    await page.screenshot({ path: path.join(output, 'mobile-navigation.png'), fullPage: false });
    await page.locator('.sidebar-menu a[href="/apps"]').click();
    await page.waitForURL(url => url.pathname === '/apps');
    assert.ok(await page.locator('.widget-app').first().isVisible());
    await page.waitForFunction(() => document.querySelector('[data-zealot-toggle="sidebar"]')?.getAttribute('aria-expanded') !== null);
    await page.locator('[data-zealot-toggle="sidebar"]').click();
    await page.waitForFunction(() => document.body.classList.contains('sidebar-open'));
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.body.classList.contains('sidebar-open'));
    await page.locator('[data-zealot-toggle="sidebar"]').click();
    await page.waitForFunction(() => document.body.classList.contains('sidebar-open'));
    await page.locator('.sidebar-overlay').click({ position: { x: 330, y: 100 } });
    await page.waitForFunction(() => !document.body.classList.contains('sidebar-open'));
    report.checks.push('Mobile navigation, Escape and overlay dismissal after Turbo navigation');
    assert.deepEqual(errors, [], 'Browser runtime and HTTP errors');
    report.checks.push('No browser JavaScript errors or same-origin HTTP errors');
    report.complete = true;
    console.log(JSON.stringify({ layouts: report.layouts.length, contrastPairs: report.contrast.length, checks: report.checks }, null, 2));
  } finally {
    fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
