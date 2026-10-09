// Only the public Flutter component fixture; never opens device/adult sessions.
const { chromium } = require('playwright');
const { expect } = require('playwright/test');
const fs = require('node:fs/promises');
const path = require('node:path');
const preview = new URL(process.env.OBSERVATION_PREVIEW_URL || 'http://127.0.0.1:8176');
if (preview.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(preview.hostname)
    || preview.username || preview.password || preview.search || preview.hash || preview.pathname !== '/') {
  throw Error('Use an explicit loopback-only public fixture');
}
const output = path.resolve(__dirname, '../../docs/design/observation');
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
      await enable.waitFor({ state: 'attached', timeout: 20000 });
      await enable.evaluate(element => element.click());
      await page.getByRole('heading', { name: '使用情况与隐私', exact: true }).waitFor();
      const sync = page.getByRole('button', { name: '同步已授权数据', exact: true });
      await expect(sync).toBeDisabled();
      const select = async label => {
        await page.locator('flt-semantics').filter({ hasText: new RegExp(`^${label}$`) }).first().click();
      };
      stage = 'system-permission-confirmation';
      await select('待系统许可');
      await page.getByRole('button', { name: '打开系统使用情况访问', exact: true }).click();
      await page.getByRole('button', { name: '暂不打开', exact: true }).click();
      await expect(page.locator('flt-semantics[role="text"]').filter({ hasText: /^演示设置确认次数：0$/ }).first()).toBeVisible();
      await page.getByRole('button', { name: '打开系统使用情况访问', exact: true }).click();
      await page.getByRole('button', { name: '前往系统设置', exact: true }).click();
      await expect(page.locator('flt-semantics[role="text"]').filter({ hasText: /^演示设置确认次数：1$/ }).first()).toBeVisible();
      stage = 'granted';
      await select('已授权');
      await expect(sync).toBeEnabled();
      await page.screenshot({ path: path.join(output, `browser-${name}.png`), fullPage: true });
      stage = 'offline-and-withdrawal';
      await select('离线待发');
      await expect(sync).toBeDisabled();
      await select('已撤回');
      await expect(sync).toBeDisabled();
      stage = 'keyboard';
      await page.keyboard.press('Tab');
      const focused = await page.evaluate(() => document.activeElement !== document.body);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow || errors.length || !focused) throw Error('Viewport or keyboard check failed');
      results.push({ viewport: name, width, height, horizontalOverflow: overflow, pageErrors: errors.length,
        unknownDisabled: true, confirmationRequired: true, grantedEnabled: true,
        offlineDisabled: true, withdrawnDisabled: true, keyboardFocused: focused });
      await context.close();
    }
    await fs.writeFile(path.join(output, 'browser-qa.json'), JSON.stringify({
      scope: 'Actual Chrome rendering of a public state fixture; no native permissions, real data, identity or backend interaction.',
      engine: 'Installed Chrome via Playwright', results
    }, null, 2) + '\n');
    process.stdout.write('PASS observation public fixture mobile/desktop and explicit confirmation\n');
  } finally { await browser.close(); }
})().catch(error => {
  process.stderr.write(`Observation browser verification failed: ${error.name}, stage=${stage}. No page content logged.\n`);
  process.exitCode = 1;
});
