// Runs the Apple TV plugin polyfills (PluginPolyfills.swift) in a bare V8 context
// — no URL, fetch, timers or TextEncoder — with Node-backed natives that mirror
// what PluginRuntime.swift installs. Usage: node scripts/test-plugin-polyfills.js
'use strict';
const vm = require('node:vm');
const fs = require('node:fs');
const http = require('node:http');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');

// The JavaScript lives in PluginPolyfills.swift as a raw string literal.
const swiftPath = process.argv[2] || require('node:path').join(__dirname, '../tvosApp/NuvioTV/Sources/Core/Plugins/PluginPolyfills.swift');
const swift = fs.readFileSync(swiftPath, 'utf8');
const source = swift.slice(swift.indexOf('#"""\n') + 5, swift.lastIndexOf('\n"""#'));
const librariesPath = require('node:path').join(require('node:path').dirname(swiftPath), 'PluginLibraries.swift');
const libraries = fs.readFileSync(librariesPath, 'utf8');
const cryptoJsSource = libraries.slice(libraries.indexOf('#"""\n') + 5, libraries.lastIndexOf('\n"""#'));

function makeContext(store = {}, storageLimit = 2 * 1024 * 1024) {
  const logs = [];
  const done = [];
  const fetchControllers = new Map();
  const timers = new Map();
  const ctx = vm.createContext({});
  const N = {
    log: (level, msg) => logs.push(`${level}: ${msg}`),
    setTimer: (id, ms) => timers.set(id, setTimeout(() => { timers.delete(id); ctx.__nuvioTimerFired(id); }, ms)),
    clearTimer: (id) => { clearTimeout(timers.get(id)); timers.delete(id); },
    fetch: (id, url, json) => {
      const opts = JSON.parse(json);
      const controller = new AbortController();
      fetchControllers.set(id, controller);
      const body = opts.bodyBase64 ? Buffer.from(opts.bodyBase64, 'base64') : opts.body;
      fetch(url, { method: opts.method, headers: opts.headers, body, signal: controller.signal })
        .then(async (res) => {
          const buf = Buffer.from(await res.arrayBuffer());
          const headers = {};
          res.headers.forEach((v, k) => { headers[k] = v; });
          const text = buf.toString('utf8');
          const valid = Buffer.from(text, 'utf8').equals(buf);
          ctx.__nuvioFetchDone(id, JSON.stringify({ status: res.status, statusText: res.statusText, headers, url: res.url,
            redirected: res.redirected, text: valid ? text : null, base64: valid ? null : buf.toString('base64') }));
        })
        .catch((e) => ctx.__nuvioFetchDone(id, JSON.stringify({ error: String(e.message || e) })));
    },
    abortFetch: (id) => fetchControllers.get(id)?.abort(),
    digest: (alg, b64) => {
      const map = { 'SHA-1': 'sha1', 'SHA-256': 'sha256', 'SHA-384': 'sha384', 'SHA-512': 'sha512', MD5: 'md5' };
      return crypto.createHash(map[alg]).update(Buffer.from(b64, 'base64')).digest('base64');
    },
    hmac: (alg, keyB64, b64) => {
      const map = { 'SHA-1': 'sha1', 'SHA-256': 'sha256', 'SHA-384': 'sha384', 'SHA-512': 'sha512', MD5: 'md5' };
      return crypto.createHmac(map[alg], Buffer.from(keyB64, 'base64')).update(Buffer.from(b64, 'base64')).digest('base64');
    },
    randomBytes: (n) => crypto.randomBytes(n).toString('base64'),
    done: (json, error) => done.push({ json, error }),
    storageGet: (key) => (Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null),
    storageSet: (key, value) => {
      const size = Object.entries({ ...store, [key]: value }).reduce((n, [k, v]) => n + k.length + v.length, 0);
      if (size > storageLimit) return false;
      store[key] = value;
      return true;
    },
    storageRemove: (key) => { delete store[key]; },
    storageClear: () => { for (const k of Object.keys(store)) delete store[k]; },
    storageKeys: () => Object.keys(store).sort(),
    moduleSource: (name) => (name === 'crypto-js' ? cryptoJsSource : "throw new Error('Unknown module');"),
    aes: (encrypt, mode, keyB64, ivB64, dataB64) => {
      try {
        const key = Buffer.from(keyB64, 'base64');
        const iv = Buffer.from(ivB64, 'base64');
        const data = Buffer.from(dataB64, 'base64');
        const bits = key.length * 8;
        if (mode === 'AES-GCM') {
          if (encrypt) {
            const c = crypto.createCipheriv(`aes-${bits}-gcm`, key, iv);
            return Buffer.concat([c.update(data), c.final(), c.getAuthTag()]).toString('base64');
          }
          const d = crypto.createDecipheriv(`aes-${bits}-gcm`, key, iv);
          d.setAuthTag(data.subarray(data.length - 16));
          return Buffer.concat([d.update(data.subarray(0, data.length - 16)), d.final()]).toString('base64');
        }
        const algo = mode === 'AES-ECB' ? `aes-${bits}-ecb` : `aes-${bits}-cbc`;
        const c = encrypt ? crypto.createCipheriv(algo, key, mode === 'AES-ECB' ? null : iv) : crypto.createDecipheriv(algo, key, mode === 'AES-ECB' ? null : iv);
        return Buffer.concat([c.update(data), c.final()]).toString('base64');
      } catch (e) {
        return '!' + e.message;
      }
    },
    pbkdf2: (passB64, saltB64, iterations, bits, hash) =>
      crypto.pbkdf2Sync(Buffer.from(passB64, 'base64'), Buffer.from(saltB64, 'base64'), iterations, bits / 8, hash.replace('-', '').toLowerCase()).toString('base64'),
  };
  ctx.__nuvioNative = N;
  vm.runInContext(source, ctx, { filename: 'polyfills.js' });
  return { ctx, logs, done, run: (code) => vm.runInContext(code, ctx) };
}

function invoke(env, name, args) {
  return new Promise((resolve) => {
    const before = env.done.length;
    env.run(`__nuvioInvoke(${JSON.stringify(name)}, ${JSON.stringify(args)})`);
    const check = () => (env.done.length > before ? resolve(env.done[before]) : setTimeout(check, 5));
    check();
  });
}

const results = [];
async function test(name, fn) {
  try { await fn(); results.push(['ok', name]); }
  catch (e) { results.push(['FAIL', name, e.stack || String(e)]); }
}

(async () => {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      if (req.url.startsWith('/json')) {
        res.setHeader('content-type', 'application/json');
        res.setHeader('x-test', 'a');
        res.end(JSON.stringify({ method: req.method, url: req.url, body, ua: req.headers['user-agent'] || null, h: req.headers['x-custom'] || null }));
      } else if (req.url === '/binary') {
        res.end(Buffer.from([0, 255, 128, 1]));
      } else if (req.url === '/slow') {
        setTimeout(() => res.end('late'), 500);
      } else if (req.url === '/redirect') {
        res.statusCode = 302; res.setHeader('location', '/json?r=1'); res.end();
      } else if (req.url === '/xml') {
        res.setHeader('content-type', 'application/xml'); res.end('<rss><channel><item><title>Žluťoučký kůň</title></item></channel></rss>');
      } else {
        res.statusCode = 404; res.end('nope');
      }
    });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;

  await test('URL parsing matches Node', () => {
    const env = makeContext();
    const cases = [
      ['https://api.nzbgeek.info/api?t=movie&imdbid=0816692&apikey=X', undefined],
      ['https://User:Pa@Example.COM:443/a/./b/../c?x=1#frag', undefined],
      ['http://example.com:8080', undefined],
      ['/api?t=caps', 'https://api.althub.co.za/x/y'],
      ['../up/file.js', 'https://raw.githubusercontent.com/u/r/main/dir/manifest.json'],
      ['file.js', 'https://raw.githubusercontent.com/u/r/main/manifest.json'],
      ['?q=2', 'https://h.com/p/q?q=1#x'],
      ['//cdn.example.org/lib.js', 'https://h.com/'],
      ['https://h.com/a b?c d=é', undefined],
      ['https://h.com', undefined],
    ];
    for (const [input, b] of cases) {
      const ours = JSON.parse(env.run(`(function(){ var u = new URL(${JSON.stringify(input)}${b ? ', ' + JSON.stringify(b) : ''});
        return JSON.stringify({href:u.href, protocol:u.protocol, host:u.host, hostname:u.hostname, port:u.port, pathname:u.pathname, search:u.search, hash:u.hash, origin:u.origin, username:u.username}); })()`));
      const node = new URL(input, b);
      for (const key of Object.keys(ours)) assert.equal(ours[key], node[key], `${input} ${key}`);
    }
    assert.throws(() => env.run('new URL("not a url")'));
    assert.equal(env.run('URL.canParse("nope")'), false);
  });

  await test('URL searchParams stay in sync with href', () => {
    const env = makeContext();
    const href = env.run(`(function(){ var u = new URL('https://api.x/api?t=caps'); u.searchParams.set('apikey','k y'); u.searchParams.append('o','json'); return u.href; })()`);
    assert.equal(href, 'https://api.x/api?t=caps&apikey=k+y&o=json');
    const s = env.run(`(function(){ var p = new URLSearchParams({a:'1', b:'x&y'}); p.append('a','2'); return p.toString() + '|' + p.getAll('a').join(',') + '|' + p.get('b') + '|' + p.has('z') + '|' + Array.from(p.keys()).join(','); })()`);
    assert.equal(s, 'a=1&b=x%26y&a=2|1,2|x&y|false|a,b,a');
  });

  await test('TextEncoder/TextDecoder and base64 round trip', () => {
    const env = makeContext();
    const out = env.run(`(function(){ var t = 'Příliš žluťoučký 🐴 kůň'; var b = new TextEncoder().encode(t); return JSON.stringify({ len: b.length, back: new TextDecoder().decode(b), b64: btoa('hello'), raw: atob('aGVsbG8='), arr: Array.from(new TextEncoder().encode('é')) }); })()`);
    const parsed = JSON.parse(out);
    assert.equal(parsed.len, Buffer.byteLength('Příliš žluťoučký 🐴 kůň'));
    assert.equal(parsed.back, 'Příliš žluťoučký 🐴 kůň');
    assert.equal(parsed.b64, 'aGVsbG8=');
    assert.equal(parsed.raw, 'hello');
    assert.deepEqual(parsed.arr, [195, 169]);
  });

  await test('timers fire in order and clearTimeout works', async () => {
    const env = makeContext();
    env.run(`globalThis.order = []; setTimeout(function(){ order.push('b'); }, 30); setTimeout(function(){ order.push('a'); }, 5);
      var x = setTimeout(function(){ order.push('never'); }, 10); clearTimeout(x);
      var n = 0; var iv = setInterval(function(){ n++; order.push('i' + n); if (n === 2) clearInterval(iv); }, 8);`);
    await new Promise((r) => setTimeout(r, 80));
    assert.deepEqual(JSON.parse(env.run('JSON.stringify(order)')), ['a', 'i1', 'i2', 'b']);
  });

  await test('fetch json, headers, POST body and redirect', async () => {
    const env = makeContext();
    env.run(`var module = { exports: {} }; module.exports.go = async function(base) {
      var r1 = await fetch(base + '/json?x=1', { headers: { 'X-Custom': 'yes' } });
      var j1 = await r1.json();
      var r2 = await fetch(new URL('/json', base), { method: 'post', body: new URLSearchParams({ q: 'a b' }) });
      var j2 = await r2.json();
      var r3 = await fetch(base + '/redirect');
      var j3 = await r3.json();
      var r4 = await fetch(base + '/missing');
      return { j1: j1, xt: r1.headers.get('X-Test'), ok1: r1.ok, j2: j2, j3: j3, red: r3.redirected, s4: r4.status, ok4: r4.ok, t4: await r4.text() };
    };`);
    const res = await invoke(env, 'go', [base]);
    assert.equal(res.error, null, res.error);
    const v = JSON.parse(res.json);
    assert.equal(v.j1.h, 'yes');
    assert.equal(v.xt, 'a');
    assert.equal(v.ok1, true);
    assert.equal(v.j2.method, 'POST');
    assert.equal(v.j2.body, 'q=a+b');
    assert.equal(v.j3.url, '/json?r=1');
    assert.equal(v.red, true);
    assert.equal(v.s4, 404);
    assert.equal(v.ok4, false);
    assert.equal(v.t4, 'nope');
  });

  await test('fetch binary body via arrayBuffer and UTF-8 XML text', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: async function(base) {
      var bytes = new Uint8Array(await (await fetch(base + '/binary')).arrayBuffer());
      var xml = await (await fetch(base + '/xml')).text();
      return { bytes: Array.from(bytes), xml: xml };
    } } };`);
    const res = await invoke(env, 'go', [base]);
    const v = JSON.parse(res.json);
    assert.deepEqual(v.bytes, [0, 255, 128, 1]);
    assert.match(v.xml, /Žluťoučký kůň/);
  });

  await test('AbortController cancels a slow fetch', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: async function(base) {
      var c = new AbortController();
      setTimeout(function(){ c.abort(); }, 20);
      try { await fetch(base + '/slow', { signal: c.signal }); return 'finished'; }
      catch (e) { return e.name; }
    } } };`);
    const res = await invoke(env, 'go', [base]);
    assert.equal(JSON.parse(res.json), 'AbortError');
  });

  await test('crypto digest, HMAC, random values', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: async function() {
      function hex(buf) { return Array.from(new Uint8Array(buf)).map(function(b){ return (b < 16 ? '0' : '') + b.toString(16); }).join(''); }
      var d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode('abc'));
      var key = await crypto.subtle.importKey('raw', new TextEncoder().encode('key'), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
      var s = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('The quick brown fox jumps over the lazy dog'));
      var r = crypto.getRandomValues(new Uint8Array(8));
      return { d: hex(d), s: hex(s), r: r.length, u: crypto.randomUUID() };
    } } };`);
    const res = await invoke(env, 'go', []);
    assert.equal(res.error, null, res.error);
    const v = JSON.parse(res.json);
    assert.equal(v.d, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    assert.equal(v.s, 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
    assert.equal(v.r, 8);
    assert.match(v.u, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  await test('invoke: missing export, thrown error, sync value, globalThis fallback, console', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { boom: function(){ throw new Error('kaput'); }, sync: function(a, b){ console.log('args', a, b); return [a, b]; } } };
      globalThis.onSettings = function(){ return [{ type: 'text', key: 'apikey', label: 'Key', isPassword: true }]; };`);
    const missing = await invoke(env, 'getStreams', []);
    assert.equal(missing.error, '__missing__');
    const boom = await invoke(env, 'boom', []);
    assert.match(boom.error, /kaput/);
    const sync = await invoke(env, 'sync', ['tt0816692', { imdbId: 'tt0816692' }]);
    assert.deepEqual(JSON.parse(sync.json), ['tt0816692', { imdbId: 'tt0816692' }]);
    const settings = await invoke(env, 'onSettings', []);
    assert.equal(JSON.parse(settings.json)[0].key, 'apikey');
    assert.ok(env.logs.some((l) => l.startsWith('log: args tt0816692 {"imdbId":"tt0816692"}')));
  });

  await test('localStorage keeps values per provider and enforces the limit', () => {
    const shared = {};
    const env = makeContext(shared, 64);
    env.run(`localStorage.setItem('caps:geek', JSON.stringify({tv:['tvdbid']})); localStorage.setItem('n', 1);`);
    const again = makeContext(shared, 64);
    const out = JSON.parse(again.run(`JSON.stringify({ caps: JSON.parse(localStorage.getItem('caps:geek')), n: localStorage.getItem('n'), missing: localStorage.getItem('nope'), len: localStorage.length, k0: localStorage.key(0) })`));
    assert.deepEqual(out, { caps: { tv: ['tvdbid'] }, n: '1', missing: null, len: 2, k0: 'caps:geek' });
    const quota = again.run(`(function(){ try { localStorage.setItem('big', new Array(100).join('x')); return 'stored'; } catch (e) { return e.name; } })()`);
    assert.equal(quota, 'QuotaExceededError');
    again.run(`localStorage.removeItem('n'); localStorage.clear();`);
    assert.deepEqual(shared, {});
  });

  await test('Android compatibility: fetch errors resolve, json() null, URLSearchParams arrays', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: async function(base) {
      var down = await fetch('http://127.0.0.1:1/nothing');
      var notJson = await (await fetch(base + '/xml')).json();
      var p = new URLSearchParams('a=1&b=2');
      return { ok: down.ok, status: down.status, reason: down.statusText.length > 0, notJson: notJson,
               keys: p.keys(), isArray: Array.isArray(p.entries()), iter: Array.from(p).length };
    } } };`);
    const res = await invoke(env, 'go', [base]);
    assert.equal(res.error, null, res.error);
    const v = JSON.parse(res.json);
    assert.equal(v.ok, false);
    assert.equal(v.status, 0);
    assert.equal(v.reason, true);
    assert.equal(v.notJson, null);
    assert.deepEqual(v.keys, ['a', 'b']);
    assert.equal(v.isArray, true);
    assert.equal(v.iter, 2);
  });

  await test('CryptoJS (global and require) is the real crypto-js', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: function() {
      var C = require('crypto-js');
      var enc = CryptoJS.AES.encrypt('Příliš žluťoučký kůň', 'secret').toString();
      return {
        same: C === CryptoJS,
        md5: CryptoJS.MD5('abc').toString(),
        sha256: C.SHA256('abc').toString(),
        hmac: C.HmacSHA256('The quick brown fox jumps over the lazy dog', 'key').toString(),
        b64: C.enc.Base64.stringify(C.enc.Utf8.parse('hello')),
        roundtrip: CryptoJS.AES.decrypt(enc, 'secret').toString(CryptoJS.enc.Utf8),
        cheerio: typeof require('cheerio-without-node-native').load
      };
    } } };`);
    const res = await invoke(env, 'go', []);
    assert.equal(res.error, null, res.error);
    const v = JSON.parse(res.json);
    assert.equal(v.same, true);
    assert.equal(v.md5, '900150983cd24fb0d6963f7d28e17f72');
    assert.equal(v.sha256, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    assert.equal(v.hmac, 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
    assert.equal(v.b64, 'aGVsbG8=');
    assert.equal(v.roundtrip, 'Příliš žluťoučký kůň');
    assert.equal(v.cheerio, 'function');
    assert.throws(() => env.run(`require('axios')`), /not available/);
  });

  await test('crypto.subtle AES-GCM, AES-CBC and PBKDF2', async () => {
    const env = makeContext();
    env.run(`var module = { exports: { go: async function() {
      function hex(buf) { return Array.from(new Uint8Array(buf)).map(function(b){ return (b < 16 ? '0' : '') + b.toString(16); }).join(''); }
      var raw = new Uint8Array(32); for (var i = 0; i < 32; i++) raw[i] = i;
      var iv12 = new Uint8Array(12), iv16 = new Uint8Array(16);
      var gcm = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
      var sealed = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv12 }, gcm, new TextEncoder().encode('hello'));
      var opened = new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv12 }, gcm, sealed));
      var cbc = await crypto.subtle.importKey('raw', raw, 'AES-CBC', false, ['encrypt', 'decrypt']);
      var c = await crypto.subtle.encrypt({ name: 'AES-CBC', iv: iv16 }, cbc, new TextEncoder().encode('hello world'));
      var d = new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-CBC', iv: iv16 }, cbc, c));
      var bad; try { await crypto.subtle.decrypt({ name: 'AES-GCM', iv: iv12 }, gcm, new Uint8Array(20)); bad = 'opened'; } catch (e) { bad = e.name; }
      var pw = await crypto.subtle.importKey('raw', new TextEncoder().encode('password'), 'PBKDF2', false, ['deriveBits']);
      var bits = await crypto.subtle.deriveBits({ name: 'PBKDF2', salt: new TextEncoder().encode('salt'), iterations: 1, hash: 'SHA-1' }, pw, 160);
      return { gcmLen: sealed.byteLength, opened: opened, cbcLen: c.byteLength, cbc: d, bad: bad, pbkdf2: hex(bits) };
    } } };`);
    const res = await invoke(env, 'go', []);
    assert.equal(res.error, null, res.error);
    const v = JSON.parse(res.json);
    assert.equal(v.gcmLen, 5 + 16);
    assert.equal(v.opened, 'hello');
    assert.equal(v.cbcLen, 16);
    assert.equal(v.cbc, 'hello world');
    assert.equal(v.bad, 'OperationError');
    assert.equal(v.pbkdf2, '0c60c80f961f0e71f3a9b524af6012062fe037a6');
  });

  server.close();
  let failed = 0;
  for (const r of results) {
    console.log(r[0], r[1]);
    if (r[0] !== 'ok') { failed++; console.log(r[2]); }
  }
  console.log(`${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})();
