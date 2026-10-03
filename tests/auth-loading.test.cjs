const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const assert = require('node:assert/strict');

const html = fs.readFileSync(path.join(__dirname, '../public/index.html'), 'utf8');
const startupCode = html.slice(html.indexOf('function showAuthLoading('), html.indexOf('async function loadCloud(){'));
assert.ok(startupCode.includes('async function initializeAuth()'));

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

function harness(sessionPromise, cafePromise = Promise.resolve(true)) {
  const classes = new Set(['auth-initializing']);
  const body = { classList: {
    add: (...names) => names.forEach(name => classes.add(name)),
    remove: (...names) => names.forEach(name => classes.delete(name)),
    contains: name => classes.has(name),
  }};
  const elements = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { textContent: '', classList: { add() {}, remove() {} } });
    return elements.get(id);
  };
  const context = {
    document: { body },
    $: selector => element(selector.slice(1)),
    supabaseClient: { auth: { getSession: () => sessionPromise } },
    authEventRevision: 0,
    signedInUser: null,
    loadCloud: async () => {
      context.loadingCafe = true;
      await cafePromise;
      context.cloudDisplayed = true;
      body.classList.remove('auth-initializing', 'login-mode');
      body.classList.add('authenticated');
    },
    setRoleAccess() {}, render() {}, syncEntryForm() {},
    get classes() { return classes; }, elements,
  };
  vm.runInNewContext(startupCode + '\nglobalThis.initializeAuth=initializeAuth;', context);
  return context;
}

test('authenticated refresh keeps login controls hidden until session and cafe load complete', async () => {
  const session = deferred(), cafe = deferred();
  const app = harness(session.promise, cafe.promise);
  const startup = app.initializeAuth();
  assert.equal(app.classes.has('auth-initializing'), true);
  assert.equal(app.classes.has('login-mode'), false);
  session.resolve({ data: { session: { user: { id: 'u1', email: 'user@example.com' } } }, error: null });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(app.loadingCafe, true);
  assert.equal(app.classes.has('auth-initializing'), true);
  assert.equal(app.classes.has('login-mode'), false);
  cafe.resolve();
  await startup;
  assert.equal(app.classes.has('authenticated'), true);
  assert.equal(app.classes.has('login-mode'), false);
});

test('logged-out refresh renders login only after Supabase confirms there is no session', async () => {
  const session = deferred();
  const app = harness(session.promise);
  const startup = app.initializeAuth();
  assert.equal(app.classes.has('auth-initializing'), true);
  assert.equal(app.classes.has('login-mode'), false);
  session.resolve({ data: { session: null }, error: null });
  await startup;
  assert.equal(app.classes.has('auth-initializing'), false);
  assert.equal(app.classes.has('login-mode'), true);
});

test('session restoration failure stays on loading/retry state instead of exposing login controls', async () => {
  const app = harness(Promise.reject(new Error('network slow')));
  await app.initializeAuth();
  assert.equal(app.classes.has('auth-initializing'), true);
  assert.equal(app.classes.has('login-mode'), false);
  assert.match(app.elements.get('authMessage').textContent, /Could not restore your sign-in/);
});

test('all application routes are gated by the initial auth state and sign-out invalidates pending cafe loads', () => {
  assert.match(html, /<body class="auth-initializing">/);
  assert.match(html, /body\.auth-initializing \.content>:not\(#authPanel\)\{visibility:hidden\}/);
  assert.match(html, /const loadingUser=signedInUser;const sessionStillActive=\(\)=>signedInUser===loadingUser;/);
  assert.match(html, /catch\(error\)\{\s*if\(!sessionStillActive\(\)\)return false;/);
  assert.match(html, /event==='SIGNED_OUT'[\s\S]*?signedInUser=null[\s\S]*?showLoginScreen/);
});


