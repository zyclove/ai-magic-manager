/** Explicit opt-in integration test for an isolated loopback Compose workspace.
 * Temporary IdP identities and a labeled test workspace are created. Tokens and
 * passwords stay in memory, screenshots/reports stay in the restricted workspace.
 * PLAYWRIGHT_MODULE optionally locates an already installed verification runtime.
 */
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repository = path.resolve(__dirname, '../..');
const workspace = path.resolve(repository, process.env.DEPLOYMENT_WORKSPACE || '.local/deployment');
assert(workspace.startsWith(path.join(repository, '.local') + path.sep), 'Workspace must be ignored and repository-local');
assert.equal(process.env.ALLOW_DEPLOYMENT_FIXTURES, '1', 'Explicitly opt in to isolated integration fixtures');
let phase = 'setup';
const nativeFetch = globalThis.fetch;
const fetch = (url, options = {}) => nativeFetch(url, {
  ...options, signal: AbortSignal.timeout(20000)
});

async function main() {
  const settings = JSON.parse(await fs.readFile(path.join(workspace, 'deployment.json'), 'utf8'));
  const origin = settings.publicUrl;
  const url = new URL(origin);
  assert(['localhost', '127.0.0.1', '[::1]'].includes(url.hostname), 'Integration fixtures require an isolated loopback origin');
  assert(origin !== 'http://localhost:3000' && origin !== 'http://localhost:8081', 'Existing local runtime must not be used');
  const password = (await fs.readFile(path.join(workspace, 'secrets/bootstrap_admin'), 'utf8')).trim();
  const adminResponse = await fetch(`${origin}/identity/realms/master/protocol/openid-connect/token`, {
    method: 'POST', body: new URLSearchParams({client_id:'admin-cli', grant_type:'password', username:'bootstrap-admin', password})
  });
  assert.equal(adminResponse.status, 200, 'Bootstrap authentication failed');
  const admin = (await adminResponse.json()).access_token;
  async function request(method, route, body, status = 200) {
    const response = await fetch(`${origin}/identity/admin${route}`, {method,
      headers: {Authorization:`Bearer ${admin}`, 'Content-Type':'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body)});
    assert.equal(response.status, status, `Identity ${method} operation failed`);
    return status === 204 || status === 201 ? null : response.json();
  }
  const realmRoute = '/realms/ai-manager';
  const identities = [];
  let browser, freshRealm;
  const report = {publicUrl:origin, fixture:true, checks:[], issues:[]};
  try {
    // A fresh 1.0.0 identity environment must already have the required mapper.
    const scopes = await request('GET', `${realmRoute}/client-scopes`);
    const emailScope = scopes.find(s => s.name === 'email');
    const mappings = await request('GET', `${realmRoute}/client-scopes/${emailScope.id}/protocol-mappers/models`);
    assert.ok(mappings.some(m => m.config?.['claim.name'] === 'email_verified'), 'Initialize identity from the current 1.0.0 realm template');
    async function createIdentity(adult) {
      const username = `deployment-${adult ? 'adult' : 'student'}-${crypto.randomUUID()}`;
      const secret = crypto.randomBytes(32).toString('base64url');
      await request('POST', `${realmRoute}/users`, {username, enabled:true, email:`${username}@example.invalid`, emailVerified:true,
        firstName:'部署验收', lastName:adult ? '管理员' : '普通用户', credentials:[{type:'password', value:secret, temporary:false}]}, 201);
      const users = await request('GET', `${realmRoute}/users?exact=true&username=${encodeURIComponent(username)}`);
      assert.equal(users.length, 1);
      identities.push(users[0].id);
      if (adult) {
        const role = await request('GET', `${realmRoute}/roles/tenant-creator`);
        await request('POST', `${realmRoute}/users/${users[0].id}/role-mappings/realm`, [role], 204);
      }
      return {username, secret};
    }
    const adult = await createIdentity(true), student = await createIdentity(false);
    phase = 'Flutter login';
    const launchOptions = {headless:true};
    if (process.env.PLAYWRIGHT_CHANNEL) launchOptions.channel = process.env.PLAYWRIGHT_CHANNEL;
    browser = await chromium.launch(launchOptions);
    async function enterCredentials(page, identity) {
      await page.locator('#username').fill(identity.username);
      await page.locator('#password').fill(identity.secret);
      await page.locator('#kc-login').click();
    }
    // The real Flutter app owns PKCE and exchanges its code against this IdP.
    const context = await browser.newContext({viewport:{width:1440,height:1000}});
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.name));
    page.on('console', message => { if (message.type() === 'error') errors.push('browser console error'); });
    await page.goto(origin, {waitUntil:'networkidle'});
    await page.locator('flt-semantics-placeholder').waitFor({state:'attached'});
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    await page.getByRole('button', {name:'安全登录', exact:true}).click();
    await enterCredentials(page, adult);
    await page.waitForURL(`${origin}/`, {timeout:30000});
    await page.waitForFunction(() => sessionStorage.getItem('ai-manager.session') !== null, {timeout:30000});
    await page.locator('flt-semantics-placeholder').waitFor({state:'attached'});
    await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
    const credentials = await page.evaluate(() => JSON.parse(sessionStorage.getItem('ai-manager.session')));
    assert(credentials?.accessToken, 'Flutter OIDC credentials were not established');
    const access = credentials.accessToken;
    const claims = JSON.parse(Buffer.from(access.split('.')[1], 'base64url').toString());
    assert(claims.scope.split(' ').includes('tenant:create'));
    assert.equal(claims.email_verified, true);
    assert(claims.amr.includes('pwd') && !claims.amr.includes('otp'));
    assert(Number.isInteger(claims.auth_time));
    phase = 'authenticated API and MFA';
    const profile = await fetch(`${origin}/api/v1/me`, {headers:{Authorization:`Bearer ${access}`}});
    assert.equal(profile.status, 200, 'Backend did not validate real Keycloak credentials');
    const created = await fetch(`${origin}/api/v1/tenants`, {method:'POST', headers:{Authorization:`Bearer ${access}`,
      'Content-Type':'application/json', 'Idempotency-Key':crypto.randomUUID()},
      body:JSON.stringify({name:'部署联调验收工作空间', kind:'FAMILY', timeZone:'Asia/Shanghai'})});
    assert.equal(created.status, 201);
    const tenant = await created.json();
    report.testTenantId = tenant.id;
    const invitation = await fetch(`${origin}/api/v1/tenants/${tenant.id}/invitations`, {method:'POST', headers:{Authorization:`Bearer ${access}`,
      'Content-Type':'application/json', 'Idempotency-Key':crypto.randomUUID()}, body:JSON.stringify({recipientEmail:'deployment-invitation@example.invalid', role:'GUARDIAN'})});
    assert.equal(invitation.status, 401, 'Password-only session must not perform a sensitive invitation');
    assert.equal((await invitation.json()).errorCode, 'REAUTH_REQUIRED');
    await page.reload({waitUntil:'networkidle'});
    await page.screenshot({path:path.join(workspace, 'browser-desktop.png'), fullPage:true});
    await page.setViewportSize({width:390,height:844});
    await page.screenshot({path:path.join(workspace, 'browser-mobile.png'), fullPage:true});
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    assert.deepEqual(errors, [], 'Management browser errors');
    await context.close();
    report.checks.push('Flutter PKCE login', 'real API authentication', 'adult workspace creation', 'password-only MFA denial', 'desktop/mobile rendering');
    // Explicitly requesting tenant:create cannot grant it to an unassigned user.
    phase = 'unassigned user authorization';
    const studentContext = await browser.newContext({serviceWorkers:'block'});
    const studentPage = await studentContext.newPage();
    const verifier = crypto.randomBytes(48).toString('base64url');
    const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
    const state = crypto.randomUUID();
    const callbackPattern = new RegExp('^' + origin.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '/auth/callback(?:\\?|$)');
    // Route interception only covers the first request of a redirect chain.
    // Request events observe the actual callback, with a bounded wait.
    const callbackReceived = studentPage.waitForRequest(callbackPattern, {timeout:30000})
      .then(request => ({request}), error => ({error}));
    const auth = new URL(`${origin}/identity/realms/ai-manager/protocol/openid-connect/auth`);
    auth.search = new URLSearchParams({client_id:'ai-manager-guardian', response_type:'code', scope:'openid profile email tenant:create',
      redirect_uri:`${origin}/auth/callback`, code_challenge:challenge, code_challenge_method:'S256', state}).toString();
    await studentPage.goto(auth.toString());
    await enterCredentials(studentPage, student);
    const received = await callbackReceived;
    if (received.error) throw received.error;
    const callback = new URL(received.request.url());
    assert.equal(callback.searchParams.get('state'), state);
    const issued = await fetch(`${origin}/identity/realms/ai-manager/protocol/openid-connect/token`, {method:'POST', body:new URLSearchParams({
      client_id:'ai-manager-guardian', grant_type:'authorization_code', code:callback.searchParams.get('code'), code_verifier:verifier, redirect_uri:`${origin}/auth/callback`})});
    assert.equal(issued.status, 200);
    const studentAccess = (await issued.json()).access_token;
    const denied = await fetch(`${origin}/api/v1/tenants`, {method:'POST', headers:{Authorization:`Bearer ${studentAccess}`, 'Content-Type':'application/json'},
      body:JSON.stringify({name:'Forbidden verification workspace', kind:'FAMILY', timeZone:'Asia/Shanghai'})});
    assert.equal(denied.status, 403);
    await studentContext.close();
    report.checks.push('unassigned user requests creation scope -> HTTP 403');
    // Import the current full template into a new empty verification realm.
    phase = 'empty realm template import';
    const template = JSON.parse(await fs.readFile(path.join(repository, 'deploy/keycloak/realm-template.json'), 'utf8'));
    template.realm = `deployment-template-${crypto.randomUUID()}`;
    if (url.protocol === 'http:') template.sslRequired = 'none';
    const client = template.clients.find(c => c.clientId === 'ai-manager-guardian');
    client.redirectUris = [`${origin}/auth/callback`]; client.webOrigins = [origin];
    await request('POST', '/realms', template, 201);
    freshRealm = template.realm;
    const imported = await request('GET', `/realms/${freshRealm}`);
    assert.equal(imported.browserFlow, 'manager-browser');
    report.checks.push('current full realm template accepted in empty realm');
    await fs.writeFile(path.join(workspace, 'browser-qa.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify({checks:report.checks, issues:report.issues, fixture:true}));
  } finally {
    if (browser) await browser.close();
    for (const id of identities) await request('DELETE', `${realmRoute}/users/${id}`, undefined, 204);
    if (freshRealm) await request('DELETE', `/realms/${freshRealm}`, undefined, 204);
  }
}
// Browser exception call logs can contain typed passwords. Never print them.
main().catch(error => { console.error(`Deployment journey failed in ${phase} (${error.name}).`); process.exitCode = 1; });
