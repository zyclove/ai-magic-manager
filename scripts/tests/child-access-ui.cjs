// Public synthetic preview only; never enrolls or reads device credentials.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const preview = new URL(process.env.CHILD_ACCESS_PREVIEW_URL || 'http://127.0.0.1:8181');
if (preview.protocol !== 'http:' || !['127.0.0.1', 'localhost'].includes(preview.hostname)
    || preview.username || preview.password || preview.search || preview.hash || preview.pathname !== '/') {
  throw Error('Only a local public preview is allowed');
}
const output = path.resolve(__dirname, '../../docs/design/child-access');
let stage = 'launch';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const results = [];
  try {
    await fs.mkdir(output, { recursive: true });
    for (const [name, width, height] of [['mobile', 390, 844], ['desktop', 1280, 1000]]) {
      const context = await browser.newContext({ viewport: { width, height }, locale: 'zh-CN' });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', () => errors.push('PAGE_ERROR'));
      stage = 'navigate';
      await page.goto(preview.href, { waitUntil: 'networkidle' });
      const semantics = page.locator('flt-semantics-placeholder');
      await semantics.waitFor({ state: 'attached', timeout: 20000 });
      await semantics.evaluate(element => element.click());
      await page.getByRole('heading', { name: '临时访问', exact: true }).waitFor();
      stage = 'offline';
      const text = value => page.locator('flt-semantics[role="text"]').filter({ hasText: value });
      await text(/^尚未在线核对最新状态$/).waitFor();
      await page.getByRole('button', { name: /阅读练习\s+等待服务确认/ }).waitFor();
      await page.waitForTimeout(400); // Flutter paints transitions outside DOM animations.
      await page.screenshot({ path: path.join(output, `${name}-offline.png`) });
      stage = 'details';
      await page.getByRole('button', { name: /阅读练习/ }).click();
      await text(/^原截止时间$/).waitFor();
      await text(/离线、重启或重试都不会自动延长/).waitFor();
      await page.waitForTimeout(400); // Capture the completed dialog transition.
      await page.screenshot({ path: path.join(output, `${name}-details.png`) });
      await page.getByRole('button', { name: '知道了', exact: true }).click();
      stage = 'states';
      for (const value of ['已到期', '已撤回', '需要核对']) {
        await page.getByRole('button', { name: value, exact: true }).click();
        await page.getByRole('button', { name: new RegExp(
          `阅读练习\\s+${value === '需要核对' ? '需要重新核对' : value}`) }).waitFor();
      }
      stage = 'sync';
      await page.getByRole('button', { name: '同步临时访问', exact: true }).click();
      await text(/^样例同步次数：1$/).waitFor();
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow || errors.length) throw Error('Viewport or runtime error');
      results.push({ viewport: name, width, height, offline: true, originalDeadlineDetails: true,
        expired: true, revoked: true, review: true, syncAction: true,
        horizontalOverflow: overflow, pageErrors: errors.length });
      await context.close();
    }
    await fs.writeFile(path.join(output, 'browser-qa.json'), JSON.stringify({
      scope: 'Built Flutter Web public synthetic component only; no native storage, real identity or OS enforcement.',
      engine: 'Installed Chrome via Playwright', results
    }, null, 2) + '\n');
    process.stdout.write('PASS child access mobile/desktop, states, details and sync\n');
  } finally { await browser.close(); }
})().catch(error => {
  process.stderr.write(`Child access UI failed: ${error.name}, stage=${stage}. No private data logged.\n`);
  process.exitCode = 1;
});
