import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

function readBootstrap() {
  const artifact = process.env.GUARDIAN_BOOTSTRAP_ARTIFACT;
  if (artifact) {
    const filename = path.resolve(artifact);
    return { filename, source: readFileSync(filename, 'utf8') };
  }

  const filename = path.join(repositoryRoot, 'apps/guardian/web/flutter_bootstrap.js');
  const template = readFileSync(filename, 'utf8');
  assert.ok(process.env.FLUTTER_SDK, 'FLUTTER_SDK is required when testing the source template');
  const loader = readFileSync(path.join(process.env.FLUTTER_SDK,
    'bin/cache/flutter_web_sdk/flutter_js/flutter.js'), 'utf8');
  assert.ok(template.includes('{{flutter_js}}'), 'The source template must include the real Flutter loader');
  assert.ok(template.includes('{{flutter_build_config}}'), 'The source template must include the generated build configuration');
  const buildConfig = `window._flutter.buildConfig = ${JSON.stringify({
    engineRevision: 'guardian-bootstrap-test-html-build',
    builds: [{ compileTarget: 'dart2js', renderer: 'html', mainJsPath: 'main.dart.js' }],
  })};`;
  const source = template.replaceAll('{{flutter_js}}', () => loader)
    .replaceAll('{{flutter_build_config}}', () => buildConfig);
  assert.doesNotMatch(source, /\{\{flutter_[^}]+\}\}/,
    'Unresolved Flutter template tokens are invalid test input');
  return { filename, source };
}

// Read failures are setup errors, not evidence of the service worker regression.
const bootstrap = readBootstrap();
const bootstrapSha256 = createHash('sha256').update(bootstrap.source).digest('hex');

function createBrowser({ baseHref, existingWorker, serviceWorkerApi }) {
  const location = new URL(`https://console.example.test${baseHref}index.html`);
  const calls = {
    scripts: [], registrations: [], unregisters: 0, storageMutations: [],
    timers: [], warnings: [], errors: [], engineInitializations: 0, appRuns: 0,
  };
  const storedValues = new Map([['unrelated-preference', 'keep']]);
  function storage(name) {
    return {
      getItem: (key) => storedValues.get(`${name}:${key}`) ?? null,
      setItem: (key, value) => {
        calls.storageMutations.push([name, 'setItem', key]);
        storedValues.set(`${name}:${key}`, String(value));
      },
      removeItem: (key) => {
        calls.storageMutations.push([name, 'removeItem', key]);
        storedValues.delete(`${name}:${key}`);
      },
      clear: () => {
        calls.storageMutations.push([name, 'clear']);
        storedValues.clear();
      },
    };
  }
  const controller = existingWorker ? {
    scriptURL: `${location.origin}${baseHref}flutter_service_worker.js?v=previous`,
    state: 'activated',
  } : null;
  const registration = {
    active: controller,
    installing: null,
    waiting: null,
    scope: `${location.origin}${baseHref}`,
    unregister: async () => { calls.unregisters += 1; return true; },
    update: async () => registration,
  };
  const navigator = { vendor: 'Browser without optional image codecs', userAgent: 'Guardian bootstrap regression' };
  if (serviceWorkerApi) {
    navigator.serviceWorker = {
      controller,
      // An unresponsive browser/worker must never delay this online-only app.
      register: (url) => {
        calls.registrations.push(String(url));
        return new Promise(() => {});
      },
      getRegistration: async () => existingWorker ? registration : undefined,
      getRegistrations: async () => existingWorker ? [registration] : [],
      ready: new Promise(() => {}),
    };
  }
  const document = {
    baseURI: new URL(baseHref, location).href,
    querySelector: (selector) => selector === 'base'
      ? { getAttribute: (name) => name === 'href' ? baseHref : null } : null,
    createElement: (tag) => {
      assert.equal(tag, 'script', 'The Flutter HTML loader should only create its script');
      let src;
      return {
        get src() { return src; },
        set src(value) { src = new URL(String(value), document.baseURI).href; },
        addEventListener() {},
      };
    },
    head: {
      append: (element) => calls.scripts.push(element.src),
      appendChild: (element) => { calls.scripts.push(element.src); return element; },
    },
  };
  const globals = {
    navigator, document, location, URL, crossOriginIsolated: false, isSecureContext: true,
    localStorage: storage('localStorage'), sessionStorage: storage('sessionStorage'),
    caches: {
      keys: async () => ['unrelated-cache'],
      delete: async (key) => { calls.storageMutations.push(['caches', 'delete', key]); return true; },
    },
    console: {
      debug() {}, log() {}, info() {},
      warn: (...args) => calls.warnings.push(args),
      error: (...args) => calls.errors.push(args),
    },
    setTimeout: (callback, delay) => {
      calls.timers.push({ callback, delay });
      return calls.timers.length;
    },
    clearTimeout() {},
    fetch: () => { throw new Error('The HTML bootstrap must not request a separate renderer'); },
  };
  globals.window = globals;
  globals.self = globals;
  const context = vm.createContext(globals);
  return { calls, context, navigator, controller, storedValues };
}

async function drainMicrotasks() {
  for (let turn = 0; turn < 8; turn += 1) await Promise.resolve();
}

for (const scenario of [
  { name: 'a pending first worker registration cannot delay startup', baseHref: '/', existingWorker: false, serviceWorkerApi: true, mainJs: 'https://console.example.test/main.dart.js' },
  { name: 'an existing worker is preserved and cannot delay startup', baseHref: '/', existingWorker: true, serviceWorkerApi: true, mainJs: 'https://console.example.test/main.dart.js' },
  { name: 'startup works without the service worker API', baseHref: '/', existingWorker: false, serviceWorkerApi: false, mainJs: 'https://console.example.test/main.dart.js' },
  { name: 'subpath deployment keeps its base href through startup', baseHref: '/guardian/console/', existingWorker: true, serviceWorkerApi: true, mainJs: 'https://console.example.test/guardian/console/main.dart.js' },
]) {
  test(scenario.name, async (t) => {
    t.diagnostic(`Bootstrap input: ${bootstrap.filename}; SHA-256: ${bootstrapSha256}`);
    const browser = createBrowser(scenario);
    const { calls, context } = browser;
    const result = new vm.Script(bootstrap.source, { filename: bootstrap.filename })
      .runInContext(context, { timeout: 1000 });
    Promise.resolve(result).catch((error) => calls.errors.push(error));
    await drainMicrotasks();

    assert.deepEqual(calls.scripts, [scenario.mainJs],
      'main.dart.js must be injected once without resolving any service worker operation');
    assert.deepEqual(calls.registrations, [], 'The online-only bootstrap must not register a worker');
    assert.equal(calls.timers.some(({ delay }) => delay === 4000), false,
      'Startup must not schedule the Flutter service worker timeout gate');
    assert.equal(typeof context._flutter?.loader?.didCreateEngineInitializer, 'function',
      'The real Flutter loader must receive the application engine initializer');
    context._flutter.loader.didCreateEngineInitializer({
      initializeEngine: async () => {
        calls.engineInitializations += 1;
        return { runApp: async () => { calls.appRuns += 1; } };
      },
    });
    await drainMicrotasks();

    assert.equal(calls.engineInitializations, 1, 'The standard loader chain must initialize the engine once');
    assert.equal(calls.appRuns, 1, 'The standard loader chain must run the application once');
    assert.deepEqual(calls.scripts, [scenario.mainJs], 'Engine initialization must not duplicate the entrypoint');
    assert.equal(calls.unregisters, 0, 'Bootstrap must not unregister existing workers');
    assert.deepEqual(calls.storageMutations, [], 'Bootstrap must preserve browser storage and caches');
    assert.deepEqual([...browser.storedValues], [['unrelated-preference', 'keep']]);
    assert.equal(browser.navigator.serviceWorker?.controller ?? null, browser.controller);
    assert.deepEqual(calls.warnings, [], 'Bootstrap must not emit a service worker startup warning');
    assert.deepEqual(calls.errors, [], 'Bootstrap must complete without loader errors');
  });
}
