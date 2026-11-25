import http from 'node:http';
import net from 'node:net';
import { randomBytes, timingSafeEqual } from 'node:crypto';

export const setupRoute = '/__nuvio/aio/setup';
export const setupCookie = 'nuvio_aio_setup';
export const setupTTLMS = 15 * 60 * 1000;

function ipv4Literal(value) {
  return typeof value === 'string' && net.isIPv4(value);
}

export function baseURLInfo(baseURL) {
  try {
    const url = new URL(baseURL);
    const hostname = url.hostname;
    return { hostname: ipv4Literal(hostname) ? hostname : '', origin: url.origin };
  } catch {
    return { hostname: '', origin: '' };
  }
}

/** The socket addresses are supplied by Node from the accepted OS socket. */
export function isSameDeviceSocket(socket, configuredIPv4) {
  const remote = socket?.remoteAddress;
  const local = socket?.localAddress;
  return typeof remote === 'string' && remote.length > 0 && remote === local
    && (remote === '127.0.0.1' || (ipv4Literal(configuredIPv4) && remote === configuredIPv4));
}

export function validatedConfigurePath(value) {
  if (typeof value !== 'string' || !value.startsWith('/') || value.includes('?') || value.includes('#') || value.includes('\\')) return null;
  const segments = value.split('/');
  if ((segments.length !== 3 && segments.length !== 5)
      || segments[0] !== '' || segments[1] !== 'stremio' || segments.at(-1) !== 'configure'
      || segments.slice(2, -1).some((segment) => !segment)) return null;
  for (const segment of segments.slice(2, -1)) {
    let decoded;
    try { decoded = decodeURIComponent(segment); } catch { return null; }
    if (decoded === '.' || decoded === '..' || /[\\\u0000-\u001f\u007f]/.test(decoded)) return null;
  }
  return value;
}

function header(request, name) {
  const value = request?.headers?.[name];
  return Array.isArray(value) ? value[0] : value;
}

function browserRequestAllowed(request, expectedOrigin) {
  const site = header(request, 'sec-fetch-site');
  if (typeof site === 'string' && site.toLowerCase() === 'cross-site') return false;
  const origin = header(request, 'origin');
  return typeof origin !== 'string' || !origin || (expectedOrigin && origin === expectedOrigin);
}

function socketOrigin(request) {
  const address = request?.socket?.localAddress;
  const port = request?.socket?.localPort;
  return ipv4Literal(address) && Number.isInteger(port) && port > 0 ? `http://${address}:${port}` : '';
}

function cookieValue(cookieHeader) {
  if (typeof cookieHeader !== 'string') return null;
  for (const part of cookieHeader.split(';')) {
    const equals = part.indexOf('=');
    if (equals > 0 && part.slice(0, equals).trim() === setupCookie) return part.slice(equals + 1).trim();
  }
  return null;
}

export function stripSetupCookie(cookieHeader) {
  if (typeof cookieHeader !== 'string') return undefined;
  const kept = cookieHeader.split(';').map((part) => part.trim()).filter((part) => {
    const equals = part.indexOf('=');
    return equals <= 0 || part.slice(0, equals).trim() !== setupCookie;
  });
  return kept.length ? kept.join('; ') : undefined;
}

export class AIOSetupGate {
  constructor({ baseURL, ttlMs = setupTTLMS, now = Date.now, makeToken = () => randomBytes(32).toString('base64url'), onRevoke = () => {} } = {}) {
    const info = baseURLInfo(baseURL);
    this.configuredIPv4 = info.hostname;
    this.expectedOrigin = info.origin;
    this.ttlMs = ttlMs;
    this.now = now;
    this.makeToken = makeToken;
    this.onRevoke = onRevoke;
    this.setup = null;
    this.sessions = new Map();
    this.peerSockets = new Map();
    this.expiryTimer = null;
    this.highestRevision = 0;
    this.closedRevision = 0;
  }

  begin(revision = this.highestRevision + 1) {
    if (!Number.isSafeInteger(revision) || revision <= this.closedRevision || revision < this.highestRevision) return null;
    if (revision === this.highestRevision && this.setup?.revision === revision) {
      return { token: this.setup.token, expiresIn: Math.max(1, this.setup.expiresAt - this.now()) };
    }
    this.revoke();
    this.highestRevision = revision;
    const token = this.makeToken();
    const cookie = this.makeToken();
    const expiresAt = this.now() + this.ttlMs;
    this.setup = { token, cookie, expiresAt, issuedAt: this.now(), revision };
    this.sessions.set(cookie, { expiresAt });
    this.expiryTimer = setTimeout(() => this.revoke(), this.ttlMs);
    this.expiryTimer.unref?.();
    return { token, expiresIn: this.ttlMs };
  }

  exchange(request, token, path) {
    this.expireIfNeeded();
    const configurePath = validatedConfigurePath(path);
    if (!configurePath || request?.method !== 'GET' || !browserRequestAllowed(request, socketOrigin(request))
        || !this.setup || this.setup.expiresAt <= this.now() || !this.sameSecret(token, this.setup.token)) return null;
    return { cookie: this.setup.cookie, path: configurePath, maxAge: Math.max(1, Math.ceil((this.setup.expiresAt - this.now()) / 1000)) };
  }

  authorize(request) {
    if (isSameDeviceSocket(request?.socket, this.configuredIPv4)) return { allowed: true, local: true };
    this.expireIfNeeded();
    if (!browserRequestAllowed(request, socketOrigin(request))) return { allowed: false, local: false };
    const cookie = cookieValue(header(request, 'cookie'));
    const session = cookie && this.sessions.get(cookie);
    if (!session || session.expiresAt <= this.now()) {
      if (session) this.expireSession(cookie);
      return { allowed: false, local: false };
    }
    this.trackPeer(cookie, request.socket);
    return { allowed: true, local: false };
  }

  revoke(revision) {
    if (Number.isSafeInteger(revision)) {
      this.closedRevision = Math.max(this.closedRevision, revision);
      if (!this.setup || this.setup.revision > revision) return false;
    } else {
      this.closedRevision = Math.max(this.closedRevision, this.setup?.revision || this.highestRevision);
    }
    clearTimeout(this.expiryTimer);
    this.expiryTimer = null;
    this.setup = null;
    this.sessions.clear();
    const peers = [...this.peerSockets.values()].flatMap((sockets) => [...sockets]);
    this.peerSockets.clear();
    for (const socket of peers) {
      if (!socket.destroyed) socket.destroy();
    }
    this.onRevoke();
    return true;
  }

  revokeBefore(timestamp) {
    if (!this.setup || !Number.isFinite(timestamp) || this.setup.issuedAt > timestamp) return false;
    return this.revoke(this.setup.revision);
  }

  expireIfNeeded() {
    if (this.setup && this.setup.expiresAt <= this.now()) this.revoke();
  }

  sameSecret(candidate, expected) {
    if (typeof candidate !== 'string' || typeof expected !== 'string') return false;
    const a = Buffer.from(candidate);
    const b = Buffer.from(expected);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  trackPeer(cookie, socket) {
    if (!socket || socket.destroyed) return;
    let sockets = this.peerSockets.get(cookie);
    if (!sockets) this.peerSockets.set(cookie, sockets = new Set());
    if (sockets.has(socket)) return;
    sockets.add(socket);
    socket.once('close', () => {
      const current = this.peerSockets.get(cookie);
      current?.delete(socket);
      if (!current?.size) this.peerSockets.delete(cookie);
    });
  }

  expireSession(cookie) {
    this.sessions.delete(cookie);
    const peers = this.peerSockets.get(cookie);
    this.peerSockets.delete(cookie);
    for (const socket of peers || []) {
      if (!socket.destroyed) socket.destroy();
    }
  }
}

function deny(response) {
  response.writeHead(403, { 'cache-control': 'no-store', 'content-type': 'text/plain; charset=utf-8' });
  response.end('Configuration setup is not active. Open the AIOStreams sheet on Nuvio and scan its QR code.');
}

function cookieForPath(request) {
  return stripSetupCookie(request.headers.cookie);
}

export function createAIOConfigurationProxy({ aioPort, baseURL, isObservedRequest = () => null, observe = () => {}, log = () => {}, onRevoke = () => {} }) {
  const gate = new AIOSetupGate({ baseURL, onRevoke });
  const proxy = http.createServer((request, response) => {
    let requestURL;
    try { requestURL = new URL(request.url || '/', baseURL); } catch { return deny(response); }
    if (requestURL.pathname === setupRoute) {
      if (request.method !== 'GET') return deny(response);
      const exchanged = gate.exchange(request, requestURL.searchParams.get('token'), requestURL.searchParams.get('path'));
      if (!exchanged) return deny(response);
      response.writeHead(303, {
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        'set-cookie': `${setupCookie}=${exchanged.cookie}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${exchanged.maxAge}`,
        location: exchanged.path,
        'content-length': '0',
      });
      return response.end();
    }

    if (!gate.authorize(request).allowed) return deny(response);
    const watch = isObservedRequest(request);
    const requestChunks = [];
    if (watch) request.on('data', (chunk) => requestChunks.push(chunk));
    const headers = { ...request.headers };
    const cleanCookie = cookieForPath(request);
    if (cleanCookie) headers.cookie = cleanCookie;
    else delete headers.cookie;
    const upstream = http.request(
      { host: '127.0.0.1', port: aioPort, method: request.method, path: request.url, headers },
      (answer) => {
        response.writeHead(answer.statusCode || 502, answer.headers);
        if (!watch || (answer.statusCode || 0) >= 300) {
          answer.pipe(response);
          return;
        }
        const chunks = [];
        answer.on('data', (chunk) => {
          chunks.push(chunk);
          response.write(chunk);
        });
        answer.on('end', () => {
          response.end();
          try {
            observe(watch, request, Buffer.concat(requestChunks), { headers: answer.headers, body: Buffer.concat(chunks) });
          } catch (error) {
            log(`could not read the configuration page's request: ${error.message}`);
          }
        });
      }
    );
    upstream.on('error', (error) => {
      if (!response.headersSent) response.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
      response.end(`AIOStreams is not answering yet: ${error.message}`);
    });
    request.pipe(upstream);
    response.on('close', () => {
      if (!response.writableEnded) upstream.destroy();
    });
  });

  proxy.on('upgrade', (request, socket, head) => {
    let requestURL;
    try { requestURL = new URL(request.url || '/', baseURL); } catch { requestURL = null; }
    if (!requestURL || requestURL.pathname === setupRoute || !gate.authorize(request).allowed) {
      socket.end('HTTP/1.1 403 Forbidden\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    const upstream = net.connect(aioPort, '127.0.0.1', () => {
      const lines = [`${request.method} ${request.url} HTTP/${request.httpVersion}`];
      for (let i = 0; i < request.rawHeaders.length; i += 2) {
        const name = request.rawHeaders[i];
        const value = request.rawHeaders[i + 1];
        if (name.toLowerCase() === 'cookie') {
          const cookie = stripSetupCookie(value);
          if (cookie) lines.push(`${name}: ${cookie}`);
        } else {
          lines.push(`${name}: ${value}`);
        }
      }
      upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
      if (head?.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
    upstream.on('close', () => socket.destroy());
  });
  proxy.on('error', (error) => log(`configuration page port: ${error.message}`));
  return { server: proxy, gate };
}
