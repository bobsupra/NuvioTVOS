import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import http from 'node:http';
import { once } from 'node:events';
import test from 'node:test';
import {
  AIOSetupGate,
  createAIOConfigurationProxy,
  isSameDeviceSocket,
  setupCookie,
  setupRoute,
  stripSetupCookie,
} from '../../tvosApp/NuvioTV/AIOInstaller/aio-setup-gate.mjs';

const baseURL = 'http://192.168.1.50:8767';

function fakeSocket(remoteAddress = '192.168.1.51', localAddress = '192.168.1.50') {
  const socket = new EventEmitter();
  socket.remoteAddress = remoteAddress;
  socket.localAddress = localAddress;
  socket.localPort = 8767;
  socket.destroyed = false;
  socket.destroy = () => { socket.destroyed = true; socket.emit('close'); };
  return socket;
}

function fakeRequest({ cookie, origin, site, remoteAddress, localAddress, method = 'GET' } = {}) {
  return {
    method,
    headers: {
      ...(cookie ? { cookie } : {}),
      ...(origin ? { origin } : {}),
      ...(site ? { 'sec-fetch-site': site } : {}),
    },
    socket: fakeSocket(remoteAddress, localAddress),
  };
}

test('same-device access requires exact observed socket addresses and an allowed literal IP', () => {
  assert.equal(isSameDeviceSocket(fakeSocket('127.0.0.1', '127.0.0.1'), '192.168.1.50'), true);
  assert.equal(isSameDeviceSocket(fakeSocket('192.168.1.50', '192.168.1.50'), '192.168.1.50'), true);
  assert.equal(isSameDeviceSocket(fakeSocket('192.168.1.51', '192.168.1.50'), '192.168.1.50'), false);
  assert.equal(isSameDeviceSocket(fakeSocket('198.18.0.1', '198.18.0.1'), '192.168.1.50'), false);
});

test('foreign peers are denied by default; setup cookie allows same-origin and rejects spoofing or cross-site requests', () => {
  let serial = 0;
  const gate = new AIOSetupGate({ baseURL, ttlMs: 60_000, makeToken: () => `token-${++serial}` });
  const foreign = fakeRequest({ remoteAddress: '192.168.1.51', localAddress: '192.168.1.50' });
  assert.equal(gate.authorize(foreign).allowed, false);
  const spoofed = fakeRequest({ remoteAddress: '192.168.1.51', localAddress: '192.168.1.50' });
  spoofed.headers.host = '192.168.1.50:8767';
  spoofed.headers['x-forwarded-for'] = '192.168.1.50';
  assert.equal(gate.authorize(spoofed).allowed, false, 'Host and X-Forwarded-For do not establish local access');

  const { token } = gate.begin();
  const exchange = gate.exchange(fakeRequest({ origin: baseURL, site: 'none' }), token, '/stremio/configure');
  assert.ok(exchange);
  const cookie = `${setupCookie}=${exchange.cookie}`;
  assert.equal(gate.authorize(fakeRequest({ cookie, origin: baseURL, site: 'same-origin' })).allowed, true);
  assert.equal(gate.authorize(fakeRequest({ cookie, origin: 'http://attacker.example', site: 'same-origin' })).allowed, false);
  assert.equal(gate.authorize(fakeRequest({ cookie, origin: baseURL, site: 'cross-site' })).allowed, false);
  assert.equal(gate.authorize(fakeRequest({ cookie: 'x-nuvio-token=token-1', origin: baseURL })).allowed, false);
  assert.equal(gate.authorize(fakeRequest({ cookie, origin: baseURL, site: 'same-origin', remoteAddress: '192.168.1.50', localAddress: '192.168.1.51' })).allowed, false);
});

test('authenticated Origin follows the OS-observed destination after a DHCP address change', () => {
  const gate = new AIOSetupGate({ baseURL, ttlMs: 60_000, makeToken: () => 'fixed-token' });
  const { token } = gate.begin();
  const changedAddress = fakeRequest({ remoteAddress: '192.168.1.80', localAddress: '192.168.1.71', origin: 'http://192.168.1.71:8767', site: 'same-origin' });
  const exchange = gate.exchange(changedAddress, token, '/stremio/configure');
  assert.ok(exchange, 'the phone reaches the current socket destination, not the stale startup BASE_URL');
  assert.equal(gate.authorize(fakeRequest({
    cookie: `${setupCookie}=${exchange.cookie}`,
    remoteAddress: '192.168.1.80',
    localAddress: '192.168.1.71',
    origin: 'http://192.168.1.71:8767',
    site: 'same-origin',
  })).allowed, true);
});

test('setup exchange accepts only GET and validated stremio configure paths', () => {
  const gate = new AIOSetupGate({ baseURL, ttlMs: 60_000, makeToken: () => 'fresh-token' });
  gate.begin();
  const request = fakeRequest({ origin: baseURL, site: 'none' });
  assert.equal(gate.exchange({ ...request, method: 'POST' }, 'fresh-token', '/stremio/configure'), null);
  assert.equal(gate.exchange(request, 'fresh-token', 'https://attacker.example/'), null);
  assert.equal(gate.exchange(request, 'fresh-token', '/stremio/../api/v1/user/configure'), null);
  assert.equal(gate.exchange(request, 'fresh-token', '/stremio/a/b/manifest.json'), null);
  assert.ok(gate.exchange(request, 'fresh-token', '/stremio/123/enc%2Fpass/configure'));
  assert.equal(gate.exchange({ ...request, headers: { origin: 'http://attacker.example', 'sec-fetch-site': 'cross-site' } }, 'fresh-token', '/stremio/configure'), null);
});

test('revoke, a new setup sheet, and expiry close previously authorized peer sockets', () => {
  let now = 100;
  let serial = 0;
  const ttl = 60 * 60 * 1000;
  const gate = new AIOSetupGate({ baseURL, ttlMs: ttl, now: () => now, makeToken: () => `token-${++serial}` });
  const { token } = gate.begin();
  const exchange = gate.exchange(fakeRequest({ origin: baseURL }), token, '/stremio/configure');
  const cookie = `${setupCookie}=${exchange.cookie}`;
  const peer = fakeRequest({ cookie, origin: baseURL });
  assert.equal(gate.authorize(peer).allowed, true);
  const nextSetup = gate.begin();
  assert.equal(peer.socket.destroyed, true, 'opening a fresh sheet revokes older peer connections');

  const next = gate.exchange(fakeRequest({ origin: baseURL }), nextSetup.token, '/stremio/configure');
  const nextPeer = fakeRequest({ cookie: `${setupCookie}=${next.cookie}`, origin: baseURL });
  assert.equal(gate.authorize(nextPeer).allowed, true);
  now += ttl;
  assert.equal(gate.authorize(nextPeer).allowed, false);
  assert.equal(nextPeer.socket.destroyed, true, 'expiry drops authenticated peer connections');
});

test('generation numbers make a late start or close harmless after a sheet closes and reopens', () => {
  const gate = new AIOSetupGate({ baseURL, ttlMs: 60_000, makeToken: (() => { let n = 0; return () => `generation-${++n}`; })() });
  const staleStart = gate.begin(1);
  assert.ok(staleStart);
  assert.equal(gate.revoke(2), true, 'the close retires any pending generation through 2');
  assert.equal(gate.begin(1), null, 'a late response/start from a closed generation cannot reactivate it');
  const current = gate.begin(3);
  assert.ok(current);
  assert.equal(gate.revoke(2), false, 'a delayed close from the previous sheet leaves generation 3 active');
  const paired = gate.exchange(fakeRequest({ origin: baseURL }), current.token, '/stremio/configure');
  assert.ok(paired);
  assert.equal(gate.authorize(fakeRequest({ cookie: `${setupCookie}=${paired.cookie}`, origin: baseURL })).allowed, true);
});

test('local proxy forwards page assets and API requests, exchanges QR token, strips its cookie, and forwards WebSocket upgrades', async (t) => {
  let observedCookie;
  let observedUpgradeCookie;
  let observedAPI = false;
  const upstream = http.createServer((request, response) => {
    observedCookie = request.headers.cookie;
    if (request.url === '/asset.js') {
      response.writeHead(200, { 'content-type': 'application/javascript' });
      response.end('window.aio = true;');
    } else if (request.url === '/api/v1/user') {
      observedAPI = true;
      request.resume();
      response.writeHead(201, { 'content-type': 'application/json' });
      response.end('{"data":{"ok":true}}');
    } else {
      response.writeHead(200);
      response.end('page');
    }
  });
  upstream.on('upgrade', (request, socket) => {
    observedUpgradeCookie = request.headers.cookie;
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\nseen');
  });
  const sockets = new Set();
  const trackSockets = (server) => server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  trackSockets(upstream);
  const upstreamListening = once(upstream, 'listening');
  upstream.listen(0, '127.0.0.1');
  await upstreamListening;
  const aioPort = upstream.address().port;
  const { server: proxy, gate } = createAIOConfigurationProxy({
    aioPort,
    baseURL,
    isObservedRequest: (request) => request.url === '/api/v1/user' ? 'user' : null,
    observe: () => { observedAPI = true; },
  });
  trackSockets(proxy);
  const proxyListening = once(proxy, 'listening');
  proxy.listen(0, '127.0.0.1');
  await proxyListening;
  t.after(async () => {
    gate.revoke();
    for (const socket of sockets) socket.destroy();
    proxy.closeAllConnections();
    upstream.closeAllConnections();
    await Promise.all([new Promise((resolve) => proxy.close(resolve)), new Promise((resolve) => upstream.close(resolve))]);
  });
  const proxyURL = `http://127.0.0.1:${proxy.address().port}`;
  const request = (path, options = {}) => new Promise((resolve, reject) => {
    const outgoing = http.request(`${proxyURL}${path}`, options, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        clearTimeout(timer);
        resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks).toString() });
      });
    });
    const timer = setTimeout(() => outgoing.destroy(new Error(`Timed out requesting ${path}`)), 3000);
    outgoing.on('error', (error) => { clearTimeout(timer); reject(error); });
    outgoing.end(options.body);
  });

  const started = gate.begin();
  const path = `/stremio/12345678/pass/configure`;
  const exchange = await request(`${setupRoute}?token=${encodeURIComponent(started.token)}&path=${encodeURIComponent(path)}`, {
    headers: { 'sec-fetch-site': 'none' },
  });
  assert.equal(exchange.status, 303);
  assert.equal(exchange.headers.location, path);
  assert.equal(exchange.headers['cache-control'], 'no-store');
  assert.equal(exchange.headers['referrer-policy'], 'no-referrer');
  const setupCookieHeader = exchange.headers['set-cookie'][0];
  assert.match(setupCookieHeader, /HttpOnly/);
  assert.match(setupCookieHeader, /SameSite=Lax/);
  assert.doesNotMatch(exchange.headers.location, /token=/);
  const cookie = setupCookieHeader.split(';', 1)[0];

  const asset = await request('/asset.js', { headers: { cookie: `other=ok; ${cookie}` } });
  assert.equal(asset.status, 200);
  assert.equal(asset.body, 'window.aio = true;');
  assert.equal(observedCookie, 'other=ok');

  const api = await request('/api/v1/user', {
    method: 'POST',
    headers: { cookie, 'content-type': 'application/json', 'content-length': '2' },
    body: '{}',
  });
  assert.equal(api.status, 201);
  assert.equal(observedAPI, true);
  assert.equal(observedCookie, undefined, 'the setup cookie is not sent upstream');

  const upgrade = http.request(`${proxyURL}/socket`, {
    headers: { connection: 'Upgrade', upgrade: 'websocket', cookie: `other=ok; ${cookie}` },
  });
  const upgraded = new Promise((resolve, reject) => {
    const timer = setTimeout(() => upgrade.destroy(new Error('Timed out waiting for upgrade')), 3000);
    upgrade.once('upgrade', (...result) => { clearTimeout(timer); resolve(result); });
    upgrade.once('response', (response) => {
      response.resume();
      clearTimeout(timer);
      reject(new Error(`Upgrade returned HTTP ${response.statusCode}`));
    });
    upgrade.once('error', (error) => { clearTimeout(timer); reject(error); });
  });
  upgrade.end();
  const [response, socket] = await upgraded;
  assert.equal(response.statusCode, 101);
  assert.equal(observedUpgradeCookie, 'other=ok');
  socket.destroy();
  gate.revoke();
  const denied = await request('/asset.js');
  assert.equal(denied.status, 200, 'same-device access survives peer-session revocation');
  assert.equal(stripSetupCookie(`a=1; ${setupCookie}=secret; b=2`), 'a=1; b=2');
});

