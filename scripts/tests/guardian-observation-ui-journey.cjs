// Credential-free public component fixture, never a real workspace session.
const { chromium } = require('playwright');
const { expect } = require('playwright/test');
const fs = require('node:fs/promises');
const path = require('node:path');
const preview = new URL(process.env.GUARDIAN_OBSERVATION_PREVIEW_URL || 'http://127.0.0.1:8177');
if (preview.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(preview.hostname)
    || preview.username || preview.password || preview.search || preview.hash || preview.pathname !== '/') {
  throw Error('Only the public loopback fixture is permitted');
}
const output = path.resolve(__dirname, '../../docs/design/observation-guardian');
let stage = 'launch';
(async () => {
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  const results = [];
  try {
    await fs.mkdir(output, { recursive: true });
    for (const [name, width, height] of [['mobile', 390, 844], ['desktop', 1280, 900]]) {
      const context = await browser.newContext({ viewport: { width, height }, locale: 'zh-CN' });
      const page = await context.newPage(), errors = [];
      page.on('pageerror', () => errors.push('PAGE_ERROR'));
      stage = 'navigate';
      await page.goto(preview.href, { waitUntil: 'networkidle' });
      await page.locator('flt-semantics-placeholder').waitFor({ state: 'attached', timeout: 20000 });
      await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
      const select = async label => {
        // Flutter scrolls its canvas rather than the document. Return to the
        // public fixture's state controls before changing scenarios.
        await page.mouse.move(width / 2, height * .5);
        await page.mouse.wheel(0, -5000);
        await page.getByRole('button', { name: label, exact: true }).click();
      };
      const text = label => page.locator('flt-semantics[role="text"]').filter({ hasText: label }).first();
      await text(/^使用情况与隐私$/).waitFor();
      await page.screenshot({ path: path.join(output, `browser-${name}.png`), fullPage: false });
      stage = 'batch';
      await text(/^报告 #9/).click();
      await text(/^资料：/).scrollIntoViewIfNeeded();
      await page.mouse.move(width / 2, height * .7);
      await page.mouse.wheel(0, 500);
      await expect(page.getByText(/演示阅读应用，org\.example\.reader，前台 2 分钟/)).toBeVisible();
      await page.screenshot({ path: path.join(output, `browser-${name}-expanded.png`), fullPage: false });
      stage = 'read-only';
      await select('只读');
      await expect(page.getByRole('button', { name: '修改观察授权', exact: true })).toHaveCount(0);
      stage = 'withdrawn';
      await select('已撤回');
      await expect(text(/^使用摘要未授权$/)).toBeVisible();
      stage = 'error';
      await select('服务错误');
      await expect(text(/未通过校验/)).toBeVisible();
      stage = 'unknown-retry';
      await select('重试演示');
      await page.getByRole('button', { name: '修改观察授权', exact: true }).click();
      stage = 'edit-switch';
      await page.getByRole('switch', { name: /系统使用摘要/ }).click();
      stage = 'edit-reason';
      const reason = page.getByRole('textbox', { name: '本次变更原因', exact: true });
      // Flutter 3.22's semantic textarea is pointer-transparent until its
      // rendered field receives focus. Click the observed field bounds, then
      // type through the browser keyboard so TextEditingController updates.
      const bounds = await reason.boundingBox();
      if (!bounds) throw Error('Reason field is not rendered');
      await page.mouse.click(bounds.x + bounds.width / 2, bounds.y + bounds.height / 3);
      await page.keyboard.insertText('公开界面验收撤回原因');
      await expect(reason).toHaveValue('公开界面验收撤回原因');
      stage = 'edit-acknowledgement';
      await page.mouse.move(width / 2, height * .6);
      await page.mouse.wheel(0, 600);
      await page.getByRole('checkbox', { name: /我已确认采集范围和撤回影响/ }).click();
      await expect(page.getByRole('checkbox', { name: /我已确认采集范围和撤回影响/ })).toBeChecked();
      stage = 'edit-submit';
      await page.getByRole('button', { name: '确认授权变更', exact: true }).click();
      stage = 'edit-frozen-switch';
      await expect(page.getByRole('switch', { name: /系统使用摘要/ })).toBeDisabled();
      stage = 'edit-frozen-reason';
      await expect(page.getByRole('textbox', { name: '本次变更原因', exact: true })).toHaveCount(0);
      await expect(page.getByText('本次变更原因（已锁定）：公开界面验收撤回原因', { exact: true })).toHaveCount(1);
      await page.screenshot({ path: path.join(output, `browser-${name}-retry.png`), fullPage: false });
      stage = 'edit-retry';
      await page.getByRole('button', { name: '重试原提交', exact: true }).click();
      stage = 'edit-result';
      await expect(text(/^演示提交次数：2$/)).toBeVisible();
      await expect(text(/^使用摘要未授权$/)).toBeVisible();
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      if (overflow || errors.length) throw Error('Viewport failed');
      results.push({ viewport: name, width, height, pageErrors: errors.length,
        horizontalOverflow: overflow, batchExpanded: true, readonlyHidden: true,
        withdrawnEmpty: true, invalidResponseHidden: true, unknownWriteFrozenAndRetried: true });
      await context.close();
    }
    await fs.writeFile(path.join(output, 'browser-qa.json'), JSON.stringify({
      scope: 'Actual Chrome public component fixture only; no real data, native access, OIDC session or backend request.',
      engine: 'Installed Chrome via Playwright', results
    }, null, 2) + '\n');
    process.stdout.write('PASS guardian observation mobile/desktop state and mutation retry\n');
  } finally { await browser.close(); }
})().catch(error => {
  process.stderr.write(`Guardian observation UI failed: ${error.name}, stage=${stage}. No page content logged.\n`);
  process.exitCode = 1;
});
