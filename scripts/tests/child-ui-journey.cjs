// Public, read-only Flutter Web preview. Never enters device/adult credentials.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const preview = new URL(process.env.CHILD_PREVIEW_URL || 'http://127.0.0.1:8175');
if (preview.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(preview.hostname)
    || preview.username || preview.password || preview.search || preview.hash || preview.pathname !== '/') {
  throw Error('Use an explicit loopback-only public preview');
}
const output = path.resolve(__dirname, '../../docs/design/child');
let stage = 'launch';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const results = [];
  try {
    await fs.mkdir(output, { recursive: true });
    for (const [name, width, height] of [['mobile', 390, 844], ['desktop', 1280, 900]]) {
      const context = await browser.newContext({ viewport: { width, height }, locale: 'zh-CN' });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', () => errors.push('PAGE_ERROR'));
      stage = 'navigate';
      await page.goto(preview.href, { waitUntil: 'networkidle' });
      const enable = page.locator('flt-semantics-placeholder');
      stage = 'enable-semantics';
      await enable.waitFor({ state: 'attached', timeout: 20000 });
      await enable.evaluate(element => element.click());
      stage = 'semantic-heading';
      await page.getByRole('heading', { name: '连接我的设备' }).waitFor({ timeout: 15000 });
      stage = 'browser-boundary';
      const scope = page.locator('flt-semantics[role="text"]').filter({ hasText: /^浏览器仅供查看界面$/ });
      if (!await scope.isVisible()) throw Error('Browser boundary missing');
      stage = 'enrollment-disabled';
      if (await page.getByRole('button', { name: '安全连接', exact: true }).isEnabled()) {
        throw Error('Browser must not enroll identity');
      }
      stage = 'viewport';
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow || errors.length) throw Error('Viewport failed');
      await page.screenshot({ path: path.join(output, `browser-${name}.png`), fullPage: true });
      stage = 'help';
      await page.locator('flt-semantics').filter({ hasText: /^如何获取注册凭据$/ }).first().click();
      const dialog = page.locator('flt-semantics').filter({ hasText: /^连接设备需要监护人$/ }).first();
      await dialog.waitFor();
      await page.getByRole('button', { name: '知道了', exact: true }).click();
      await dialog.waitFor({ state: 'hidden' });
      if (errors.length) throw Error('Help interaction failed');
      results.push({ viewport: name, width, height, horizontalOverflow: overflow,
        pageErrors: errors.length, browserEnrollmentDisabled: true, helpDialog: true });
      await context.close();
    }
    await fs.writeFile(path.join(output, 'browser-qa.json'), JSON.stringify({
      scope: 'Actual built Flutter Web; unsupported native identity explicitly disabled. No child data or credentials entered.',
      engine: 'Installed Chrome via Playwright', results
    }, null, 2) + '\n');
    process.stdout.write('PASS child browser mobile/desktop, boundary and help\n');
  } finally { await browser.close(); }
})().catch(error => {
  process.stderr.write(`Child browser verification failed: ${error.name}, stage=${stage}. No page content or credentials logged.\n`);
  process.exitCode = 1;
});
