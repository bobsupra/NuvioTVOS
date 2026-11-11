import Foundation

/// Browser-style globals for plugin JavaScript, evaluated into every plugin
/// context before the plugin's own code: console, timers, fetch (Headers,
/// Request, Response, AbortController), URL / URLSearchParams, TextEncoder /
/// TextDecoder, atob / btoa, crypto (getRandomValues, randomUUID, subtle
/// digest, HMAC, AES and PBKDF2), localStorage, and what the Nuvio Android apps
/// add: cheerio, CryptoJS and require(). Natives come from `__nuvioNative`,
/// which `PluginInstance` installs first. Tested as plain JavaScript as well
/// (scripts/test-plugin-polyfills.js), so keep it free of Swift interpolation.
enum PluginPolyfills {
    static let source = #"""
(function (G) {
  'use strict';
  var N = G.__nuvioNative;

  G.globalThis = G;
  G.window = G;
  G.self = G;
  G.global = G;
  G.NUVIO_PLATFORM = 'tvos';

  function describe(value) {
    if (typeof value === 'string') return value;
    if (value instanceof Error) return value.stack ? value.message + '\n' + value.stack : String(value);
    if (value === undefined) return 'undefined';
    try {
      var json = JSON.stringify(value);
      return json === undefined ? String(value) : json;
    } catch (e) {
      return String(value);
    }
  }

  function errorText(error) {
    if (error == null) return 'Unknown error';
    if (typeof error === 'string') return error;
    var message = error.message ? String(error.message) : String(error);
    return error.stack ? message + '\n' + error.stack : message;
  }
  G.__nuvioErrorText = errorText;

  function logger(level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) parts.push(describe(arguments[i]));
      N.log(level, parts.join(' '));
    };
  }
  G.console = {
    log: logger('log'), info: logger('info'), debug: logger('debug'),
    warn: logger('warn'), error: logger('error'), trace: logger('debug')
  };

  // ---- timers -------------------------------------------------------------
  var timers = {};
  var timerSeq = 0;
  function schedule(fn, ms, args, repeat) {
    var id = ++timerSeq;
    var delay = Math.max(0, Number(ms) || 0);
    timers[id] = { fn: fn, args: args, repeat: repeat, ms: delay };
    N.setTimer(id, delay);
    return id;
  }
  G.setTimeout = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
  G.setInterval = function (fn, ms) { return schedule(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
  G.clearTimeout = G.clearInterval = function (id) {
    if (timers[id]) {
      delete timers[id];
      N.clearTimer(id);
    }
  };
  G.__nuvioTimerFired = function (id) {
    var timer = timers[id];
    if (!timer) return;
    if (timer.repeat) N.setTimer(id, timer.ms); else delete timers[id];
    try {
      if (typeof timer.fn === 'function') timer.fn.apply(G, timer.args);
    } catch (e) {
      N.log('error', 'Timer callback failed: ' + errorText(e));
    }
  };
  G.queueMicrotask = function (fn) { Promise.resolve().then(fn); };

  // ---- base64 / UTF-8 -----------------------------------------------------
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function bytesToBase64(bytes) {
    var out = '';
    var i = 0;
    for (; i + 2 < bytes.length; i += 3) {
      var n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (i < bytes.length) {
      var rest = bytes.length - i;
      var m = (bytes[i] << 16) | (rest > 1 ? bytes[i + 1] << 8 : 0);
      out += B64[(m >> 18) & 63] + B64[(m >> 12) & 63] + (rest > 1 ? B64[(m >> 6) & 63] : '=') + '=';
    }
    return out;
  }
  function base64ToBytes(text) {
    var clean = String(text).replace(/[\s=]/g, '').replace(/-/g, '+').replace(/_/g, '/');
    if (/[^A-Za-z0-9+/]/.test(clean)) throw new Error('Invalid base64');
    var out = new Uint8Array(Math.floor(clean.length * 3 / 4));
    var buffer = 0, bits = 0, index = 0;
    for (var i = 0; i < clean.length; i++) {
      buffer = (buffer << 6) | B64.indexOf(clean[i]);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[index++] = (buffer >> bits) & 255;
      }
    }
    return out.subarray(0, index);
  }
  function utf8Encode(text) {
    var str = String(text);
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < str.length) {
        var next = str.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        } else {
          code = 0xfffd;
        }
      } else if (code >= 0xd800 && code <= 0xdfff) {
        code = 0xfffd;
      }
      if (code < 0x80) out.push(code);
      else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
    return new Uint8Array(out);
  }
  function utf8Decode(bytes) {
    var out = '';
    var i = 0;
    while (i < bytes.length) {
      var b = bytes[i++];
      var code;
      if (b < 0x80) code = b;
      else if (b >= 0xc2 && b < 0xe0 && i < bytes.length && (bytes[i] & 0xc0) === 0x80) {
        code = ((b & 31) << 6) | (bytes[i++] & 63);
      } else if (b >= 0xe0 && b < 0xf0 && i + 1 < bytes.length && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80) {
        code = ((b & 15) << 12) | ((bytes[i] & 63) << 6) | (bytes[i + 1] & 63);
        i += 2;
      } else if (b >= 0xf0 && b < 0xf5 && i + 2 < bytes.length && (bytes[i] & 0xc0) === 0x80 && (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
        code = ((b & 7) << 18) | ((bytes[i] & 63) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
        i += 3;
      } else {
        code = 0xfffd;
      }
      if (code > 0xffff) {
        code -= 0x10000;
        out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 1023));
      } else {
        out += String.fromCharCode(code);
      }
    }
    return out;
  }
  function toBytes(data) {
    if (data == null) return new Uint8Array(0);
    if (typeof data === 'string') return utf8Encode(data);
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return utf8Encode(String(data));
  }
  function bufferFrom(bytes) {
    var copy = new Uint8Array(bytes.length);
    copy.set(bytes);
    return copy.buffer;
  }

  G.btoa = function (text) {
    var str = String(text);
    var bytes = new Uint8Array(str.length);
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code > 255) throw new Error("btoa: the string contains characters outside of the Latin1 range");
      bytes[i] = code;
    }
    return bytesToBase64(bytes);
  };
  G.atob = function (text) {
    var bytes = base64ToBytes(text);
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  };

  function TextEncoder() {}
  TextEncoder.prototype.encoding = 'utf-8';
  TextEncoder.prototype.encode = function (text) { return utf8Encode(text === undefined ? '' : text); };
  G.TextEncoder = TextEncoder;
  function TextDecoder(label) {
    var name = String(label || 'utf-8').toLowerCase();
    if (name !== 'utf-8' && name !== 'utf8') throw new RangeError('TextDecoder supports only UTF-8');
  }
  TextDecoder.prototype.encoding = 'utf-8';
  TextDecoder.prototype.decode = function (data) { return utf8Decode(toBytes(data === undefined ? new Uint8Array(0) : data)); };
  G.TextDecoder = TextDecoder;

  // ---- URLSearchParams ----------------------------------------------------
  function decodeComponent(text) {
    try { return decodeURIComponent(text.replace(/\+/g, ' ')); } catch (e) { return text; }
  }
  function encodeComponent(text) {
    return encodeURIComponent(text).replace(/%20/g, '+').replace(/[!'()~]/g, function (c) {
      return '%' + c.charCodeAt(0).toString(16).toUpperCase();
    });
  }
  function URLSearchParams(init) {
    this._list = [];
    this._url = null;
    if (init == null || init === '') return;
    if (init instanceof URLSearchParams) {
      this._list = init._list.map(function (pair) { return [pair[0], pair[1]]; });
    } else if (typeof init === 'string') {
      this._parse(init);
    } else if (Array.isArray(init)) {
      for (var i = 0; i < init.length; i++) this._list.push([String(init[i][0]), String(init[i][1])]);
    } else if (typeof init === 'object') {
      for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this._list.push([key, String(init[key])]);
    }
  }
  URLSearchParams.prototype._parse = function (text) {
    var query = String(text);
    if (query.charAt(0) === '?') query = query.slice(1);
    this._list = [];
    if (!query) return;
    var parts = query.split('&');
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i]) continue;
      var eq = parts[i].indexOf('=');
      var name = eq >= 0 ? parts[i].slice(0, eq) : parts[i];
      var value = eq >= 0 ? parts[i].slice(eq + 1) : '';
      this._list.push([decodeComponent(name), decodeComponent(value)]);
    }
  };
  URLSearchParams.prototype._update = function () {
    if (this._url) {
      var text = this.toString();
      this._url._search = text ? '?' + text : '';
    }
  };
  URLSearchParams.prototype.append = function (name, value) { this._list.push([String(name), String(value)]); this._update(); };
  URLSearchParams.prototype.delete = function (name) {
    name = String(name);
    this._list = this._list.filter(function (pair) { return pair[0] !== name; });
    this._update();
  };
  URLSearchParams.prototype.get = function (name) {
    name = String(name);
    for (var i = 0; i < this._list.length; i++) if (this._list[i][0] === name) return this._list[i][1];
    return null;
  };
  URLSearchParams.prototype.getAll = function (name) {
    name = String(name);
    return this._list.filter(function (pair) { return pair[0] === name; }).map(function (pair) { return pair[1]; });
  };
  URLSearchParams.prototype.has = function (name) { return this.get(name) !== null; };
  URLSearchParams.prototype.set = function (name, value) {
    name = String(name);
    var found = false;
    var next = [];
    for (var i = 0; i < this._list.length; i++) {
      if (this._list[i][0] === name) {
        if (!found) next.push([name, String(value)]);
        found = true;
      } else {
        next.push(this._list[i]);
      }
    }
    if (!found) next.push([name, String(value)]);
    this._list = next;
    this._update();
  };
  URLSearchParams.prototype.sort = function () {
    this._list.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
    this._update();
  };
  URLSearchParams.prototype.forEach = function (callback, thisArg) {
    for (var i = 0; i < this._list.length; i++) callback.call(thisArg, this._list[i][1], this._list[i][0], this);
  };
  URLSearchParams.prototype.toString = function () {
    return this._list.map(function (pair) { return encodeComponent(pair[0]) + '=' + encodeComponent(pair[1]); }).join('&');
  };
  // Arrays rather than iterators: the Android runtime returns arrays, and arrays iterate too.
  URLSearchParams.prototype.entries = function () { return this._list.map(function (p) { return [p[0], p[1]]; }); };
  URLSearchParams.prototype.keys = function () { return this._list.map(function (p) { return p[0]; }); };
  URLSearchParams.prototype.values = function () { return this._list.map(function (p) { return p[1]; }); };
  URLSearchParams.prototype[Symbol.iterator] = function () { return this.entries()[Symbol.iterator](); };
  Object.defineProperty(URLSearchParams.prototype, 'size', { get: function () { return this._list.length; } });
  G.URLSearchParams = URLSearchParams;

  // ---- URL (hierarchical schemes; enough for API clients) ------------------
  var DEFAULT_PORTS = { 'http:': '80', 'https:': '443', 'ws:': '80', 'wss:': '443', 'ftp:': '21' };
  var URL_RE = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/([^/?#]*))?([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/;

  function removeDotSegments(path) {
    var input = path.split('/');
    var output = [];
    for (var i = 0; i < input.length; i++) {
      var seg = input[i];
      if (seg === '..') {
        if (output.length > 1) output.pop();
        if (i === input.length - 1) output.push('');
      } else if (seg === '.') {
        if (i === input.length - 1) output.push('');
      } else {
        output.push(seg);
      }
    }
    var joined = output.join('/');
    if (path.charAt(0) === '/' && joined.charAt(0) !== '/') joined = '/' + joined;
    return joined;
  }

  function encodePathLike(text) {
    return text.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/%]/g, function (c) { return encodeURIComponent(c); })
      .replace(/%(?![0-9A-Fa-f]{2})/g, '%25');
  }
  function encodeQueryLike(text) {
    return text.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/?%]/g, function (c) { return encodeURIComponent(c); })
      .replace(/%(?![0-9A-Fa-f]{2})/g, '%25');
  }

  function parseAuthority(authority) {
    var result = { username: '', password: '', hostname: '', port: '' };
    var at = authority.lastIndexOf('@');
    if (at >= 0) {
      var userinfo = authority.slice(0, at);
      authority = authority.slice(at + 1);
      var colon = userinfo.indexOf(':');
      result.username = colon >= 0 ? userinfo.slice(0, colon) : userinfo;
      result.password = colon >= 0 ? userinfo.slice(colon + 1) : '';
    }
    var portMatch = /^(\[[^\]]*\]|[^:]*)(?::(\d*))?$/.exec(authority);
    if (!portMatch) throw new TypeError('Invalid URL');
    result.hostname = portMatch[1].toLowerCase();
    result.port = portMatch[2] || '';
    return result;
  }

  function URL(input, base) {
    if (!(this instanceof URL)) throw new TypeError("Constructor URL requires 'new'");
    var text = String(input).replace(/^[\u0000- ]+|[\u0000- ]+$/g, '').replace(/[\t\n\r]/g, '');
    var match = URL_RE.exec(text);
    if (!match) throw new TypeError('Invalid URL: ' + text);
    var scheme = match[1];
    if (!scheme) {
      if (base === undefined) throw new TypeError('Invalid URL: ' + text);
      var baseURL = base instanceof URL ? base : new URL(base);
      this._protocol = baseURL._protocol;
      if (match[2] !== undefined) {
        this._setAuthority(match[3]);
        this._pathname = removeDotSegments(match[4] || '/') || '/';
        this._search = match[5] || '';
      } else {
        this._username = baseURL._username;
        this._password = baseURL._password;
        this._hostname = baseURL._hostname;
        this._port = baseURL._port;
        var path = match[4];
        if (path === '') {
          this._pathname = baseURL._pathname;
          this._search = match[5] !== undefined ? match[5] : baseURL._search;
        } else {
          if (path.charAt(0) !== '/') {
            var dir = baseURL._pathname.slice(0, baseURL._pathname.lastIndexOf('/') + 1) || '/';
            path = dir + path;
          }
          this._pathname = removeDotSegments(path);
          this._search = match[5] || '';
        }
      }
    } else {
      this._protocol = scheme.toLowerCase();
      if (match[2] === undefined && this._special()) {
        throw new TypeError('Invalid URL: ' + text);
      }
      if (match[2] !== undefined) {
        this._setAuthority(match[3]);
        this._pathname = removeDotSegments(match[4] || '') || (this._special() ? '/' : '');
      } else {
        this._username = this._password = this._hostname = this._port = '';
        this._pathname = match[4] || '';
        this._opaque = true;
      }
      this._search = match[5] || '';
    }
    this._hash = match[6] || '';
    if (this._search === '?') this._search = '';
    if (this._hash === '#') this._hash = '';
    this._pathname = this._opaque ? this._pathname : encodePathLike(this._pathname);
    this._search = encodeQueryLike(this._search);
    if (DEFAULT_PORTS[this._protocol] === this._port) this._port = '';
    var params = new URLSearchParams(this._search);
    params._url = this;
    this._params = params;
  }
  URL.prototype._special = function () { return Object.prototype.hasOwnProperty.call(DEFAULT_PORTS, this._protocol) || this._protocol === 'file:'; };
  URL.prototype._setAuthority = function (authority) {
    var parsed = parseAuthority(authority || '');
    this._username = parsed.username;
    this._password = parsed.password;
    this._hostname = parsed.hostname;
    this._port = parsed.port;
    if (!this._hostname && this._special() && this._protocol !== 'file:') throw new TypeError('Invalid URL');
  };
  function accessor(name, get, set) {
    Object.defineProperty(URL.prototype, name, { get: get, set: set, enumerable: true, configurable: true });
  }
  accessor('protocol', function () { return this._protocol; }, function (v) {
    var p = String(v).toLowerCase();
    this._protocol = p.charAt(p.length - 1) === ':' ? p : p + ':';
  });
  accessor('username', function () { return this._username; }, function (v) { this._username = String(v); });
  accessor('password', function () { return this._password; }, function (v) { this._password = String(v); });
  accessor('hostname', function () { return this._hostname; }, function (v) { this._hostname = String(v).toLowerCase(); });
  accessor('port', function () { return this._port; }, function (v) {
    var p = String(v);
    this._port = DEFAULT_PORTS[this._protocol] === p ? '' : p;
  });
  accessor('host', function () { return this._hostname + (this._port ? ':' + this._port : ''); }, function (v) {
    var parsed = parseAuthority(String(v));
    this._hostname = parsed.hostname;
    this._port = DEFAULT_PORTS[this._protocol] === parsed.port ? '' : parsed.port;
  });
  accessor('origin', function () {
    if (this._opaque || !this._special() || this._protocol === 'file:') return 'null';
    return this._protocol + '//' + this.host;
  });
  accessor('pathname', function () { return this._pathname; }, function (v) {
    var p = String(v);
    if (!this._opaque && p.charAt(0) !== '/') p = '/' + p;
    this._pathname = this._opaque ? p : encodePathLike(p);
  });
  accessor('search', function () { return this._search; }, function (v) {
    var s = String(v);
    if (s && s.charAt(0) !== '?') s = '?' + s;
    this._search = s === '?' ? '' : encodeQueryLike(s);
    this._params._parse(this._search);
  });
  accessor('searchParams', function () { return this._params; });
  accessor('hash', function () { return this._hash; }, function (v) {
    var h = String(v);
    if (h && h.charAt(0) !== '#') h = '#' + h;
    this._hash = h === '#' ? '' : h;
  });
  accessor('href', function () {
    if (this._opaque) return this._protocol + this._pathname + this._search + this._hash;
    var auth = this._username ? this._username + (this._password ? ':' + this._password : '') + '@' : '';
    return this._protocol + '//' + auth + this.host + this._pathname + this._search + this._hash;
  }, function (v) {
    var next = new URL(String(v));
    for (var key in next) if (Object.prototype.hasOwnProperty.call(next, key)) this[key] = next[key];
    this._params._url = this;
  });
  URL.prototype.toString = function () { return this.href; };
  URL.prototype.toJSON = function () { return this.href; };
  URL.canParse = function (input, base) {
    try { new URL(input, base); return true; } catch (e) { return false; }
  };
  G.URL = URL;

  // ---- events / abort -----------------------------------------------------
  function SimpleEventTarget() { this._listeners = {}; }
  SimpleEventTarget.prototype.addEventListener = function (type, listener) {
    if (typeof listener !== 'function') return;
    (this._listeners[type] = this._listeners[type] || []).push(listener);
  };
  SimpleEventTarget.prototype.removeEventListener = function (type, listener) {
    var list = this._listeners[type];
    if (list) this._listeners[type] = list.filter(function (l) { return l !== listener; });
  };
  SimpleEventTarget.prototype.dispatchEvent = function (event) {
    var list = (this._listeners[event.type] || []).slice();
    var handler = this['on' + event.type];
    if (typeof handler === 'function') list.unshift(handler);
    for (var i = 0; i < list.length; i++) {
      try { list[i].call(this, event); } catch (e) { N.log('error', 'Event listener failed: ' + errorText(e)); }
    }
    return true;
  };
  G.EventTarget = SimpleEventTarget;

  function makeAbortError(reason) {
    if (reason !== undefined) return reason;
    var error = new Error('The operation was aborted.');
    error.name = 'AbortError';
    return error;
  }
  function AbortSignal() {
    SimpleEventTarget.call(this);
    this.aborted = false;
    this.reason = undefined;
    this.onabort = null;
  }
  AbortSignal.prototype = Object.create(SimpleEventTarget.prototype);
  AbortSignal.prototype.constructor = AbortSignal;
  AbortSignal.prototype.throwIfAborted = function () { if (this.aborted) throw this.reason; };
  AbortSignal.prototype._abort = function (reason) {
    if (this.aborted) return;
    this.aborted = true;
    this.reason = makeAbortError(reason);
    this.dispatchEvent({ type: 'abort', target: this });
  };
  AbortSignal.abort = function (reason) { var s = new AbortSignal(); s._abort(reason); return s; };
  AbortSignal.timeout = function (ms) {
    var s = new AbortSignal();
    G.setTimeout(function () {
      var error = new Error('The operation timed out.');
      error.name = 'TimeoutError';
      s._abort(error);
    }, ms);
    return s;
  };
  AbortSignal.any = function (signals) {
    var s = new AbortSignal();
    for (var i = 0; i < signals.length; i++) {
      (function (source) {
        if (source.aborted) s._abort(source.reason);
        else source.addEventListener('abort', function () { s._abort(source.reason); });
      })(signals[i]);
    }
    return s;
  };
  function AbortController() { this.signal = new AbortSignal(); }
  AbortController.prototype.abort = function (reason) { this.signal._abort(reason); };
  G.AbortSignal = AbortSignal;
  G.AbortController = AbortController;

  // ---- Headers / Response / fetch -----------------------------------------
  function Headers(init) {
    this._map = {};
    if (init == null) return;
    if (init instanceof Headers) {
      for (var k in init._map) this._map[k] = init._map[k].slice();
    } else if (Array.isArray(init)) {
      for (var i = 0; i < init.length; i++) this.append(init[i][0], init[i][1]);
    } else if (typeof init === 'object') {
      for (var key in init) if (Object.prototype.hasOwnProperty.call(init, key)) this.append(key, init[key]);
    }
  }
  Headers.prototype.append = function (name, value) {
    var key = String(name).toLowerCase();
    (this._map[key] = this._map[key] || []).push(String(value));
  };
  Headers.prototype.set = function (name, value) { this._map[String(name).toLowerCase()] = [String(value)]; };
  Headers.prototype.get = function (name) {
    var list = this._map[String(name).toLowerCase()];
    return list ? list.join(', ') : null;
  };
  Headers.prototype.has = function (name) { return Object.prototype.hasOwnProperty.call(this._map, String(name).toLowerCase()); };
  Headers.prototype.delete = function (name) { delete this._map[String(name).toLowerCase()]; };
  Headers.prototype.forEach = function (callback, thisArg) {
    var keys = Object.keys(this._map).sort();
    for (var i = 0; i < keys.length; i++) callback.call(thisArg, this.get(keys[i]), keys[i], this);
  };
  Headers.prototype.entries = function () {
    var self = this;
    return Object.keys(this._map).sort().map(function (k) { return [k, self.get(k)]; })[Symbol.iterator]();
  };
  Headers.prototype.keys = function () { return Object.keys(this._map).sort()[Symbol.iterator](); };
  Headers.prototype.values = function () {
    var self = this;
    return Object.keys(this._map).sort().map(function (k) { return self.get(k); })[Symbol.iterator]();
  };
  Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
  Headers.prototype.getSetCookie = function () { return (this._map['set-cookie'] || []).slice(); };
  G.Headers = Headers;

  function Response(body, init) {
    init = init || {};
    this.status = init.status === undefined ? 200 : init.status;
    this.statusText = init.statusText || '';
    this.ok = this.status >= 200 && this.status < 300;
    this.headers = init.headers instanceof Headers ? init.headers : new Headers(init.headers);
    this.url = init.url || '';
    this.redirected = !!init.redirected;
    this.type = 'basic';
    this.bodyUsed = false;
    this._base64 = init._base64 || null;
    if (body == null) this._text = this._base64 != null ? null : '';
    else if (typeof body === 'string') this._text = body;
    else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
      this._base64 = bytesToBase64(toBytes(body));
      this._text = null;
    } else this._text = String(body);
  }
  Response.prototype._consume = function () {
    if (this.bodyUsed) return Promise.reject(new TypeError('Body has already been consumed.'));
    this.bodyUsed = true;
    return Promise.resolve();
  };
  Response.prototype._bytes = function () {
    if (this._base64 != null) return base64ToBytes(this._base64);
    return utf8Encode(this._text || '');
  };
  Response.prototype.text = function () {
    var self = this;
    return this._consume().then(function () {
      return self._text != null ? self._text : utf8Decode(self._bytes());
    });
  };
  // Like the Android runtime: an empty or invalid body gives null instead of a rejection.
  Response.prototype.json = function () {
    var self = this;
    return this._consume().then(function () {
      var text = self._text != null ? self._text : utf8Decode(self._bytes());
      if (text == null || text === '') return null;
      try {
        return JSON.parse(text);
      } catch (e) {
        N.log('error', 'fetch.json parse error: ' + (e && e.message ? e.message : e));
        return null;
      }
    });
  };
  Response.prototype.arrayBuffer = function () {
    var self = this;
    return this._consume().then(function () { return bufferFrom(self._bytes()); });
  };
  Response.prototype.bytes = function () {
    var self = this;
    return this._consume().then(function () { return new Uint8Array(bufferFrom(self._bytes())); });
  };
  Response.prototype.clone = function () {
    if (this.bodyUsed) throw new TypeError('Response body is already used');
    return new Response(this._text, {
      status: this.status, statusText: this.statusText, headers: new Headers(this.headers),
      url: this.url, redirected: this.redirected, _base64: this._base64
    });
  };
  Response.json = function (data, init) {
    init = init || {};
    var headers = new Headers(init.headers);
    if (!headers.has('content-type')) headers.set('content-type', 'application/json');
    return new Response(JSON.stringify(data), { status: init.status, statusText: init.statusText, headers: headers });
  };
  G.Response = Response;

  function Request(input, init) {
    init = init || {};
    var source = input instanceof Request ? input : null;
    this.url = source ? source.url : String(input instanceof URL ? input.href : input);
    this.method = String(init.method || (source && source.method) || 'GET').toUpperCase();
    this.headers = new Headers(init.headers || (source && source.headers));
    this.body = init.body !== undefined ? init.body : (source ? source.body : null);
    this.signal = init.signal || (source && source.signal) || null;
    this.redirect = init.redirect || (source && source.redirect) || 'follow';
  }
  G.Request = Request;

  var pending = {};
  var fetchSeq = 0;
  G.fetch = function (input, init) {
    return new Promise(function (resolve, reject) {
      var request;
      try { request = new Request(input, init); } catch (e) { reject(e); return; }
      var url;
      try { url = new URL(request.url).href; } catch (e) { reject(new TypeError('Invalid URL: ' + request.url)); return; }
      var headers = {};
      request.headers.forEach(function (value, key) { headers[key] = value; });
      var body = request.body;
      var payload = { method: request.method, headers: headers, redirect: request.redirect };
      if (body != null) {
        if (body instanceof URLSearchParams) {
          payload.body = body.toString();
          if (!request.headers.has('content-type')) payload.headers['content-type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
        } else if (typeof body === 'string') {
          payload.body = body;
        } else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) {
          payload.bodyBase64 = bytesToBase64(toBytes(body));
        } else {
          payload.body = String(body);
        }
      }
      var signal = request.signal;
      if (signal && signal.aborted) { reject(signal.reason || makeAbortError()); return; }
      var id = ++fetchSeq;
      pending[id] = { resolve: resolve, reject: reject };
      if (signal) {
        signal.addEventListener('abort', function () {
          if (!pending[id]) return;
          delete pending[id];
          N.abortFetch(id);
          reject(signal.reason || makeAbortError());
        });
      }
      N.fetch(id, url, JSON.stringify(payload));
    });
  };
  G.__nuvioFetchDone = function (id, json) {
    var entry = pending[id];
    if (!entry) return;
    delete pending[id];
    var result;
    try { result = JSON.parse(json); } catch (e) { entry.reject(new TypeError('Network response could not be read')); return; }
    // Like the Android runtime, a network failure resolves with ok: false and
    // status 0 (the reason in statusText) instead of rejecting.
    if (result.error) {
      entry.resolve(new Response('', { status: 0, statusText: String(result.error), url: result.url || '' }));
      return;
    }
    var headers = new Headers();
    var raw = result.headers || {};
    for (var key in raw) if (Object.prototype.hasOwnProperty.call(raw, key)) headers.append(key, raw[key]);
    entry.resolve(new Response(result.text != null ? result.text : null, {
      status: result.status,
      statusText: result.statusText || '',
      headers: headers,
      url: result.url || '',
      redirected: !!result.redirected,
      _base64: result.base64 || null
    }));
  };

  // ---- crypto -------------------------------------------------------------
  var HASHES = { 'SHA-1': 'SHA-1', 'SHA1': 'SHA-1', 'SHA-256': 'SHA-256', 'SHA256': 'SHA-256',
    'SHA-384': 'SHA-384', 'SHA384': 'SHA-384', 'SHA-512': 'SHA-512', 'SHA512': 'SHA-512', 'MD5': 'MD5' };
  function hashName(algorithm) {
    var name = typeof algorithm === 'string' ? algorithm : (algorithm && (algorithm.name || (algorithm.hash && (algorithm.hash.name || algorithm.hash))));
    var normalized = HASHES[String(name || '').toUpperCase()];
    if (!normalized) throw new Error('Unsupported algorithm: ' + name);
    return normalized;
  }
  function algorithmName(algorithm) {
    var name = String((algorithm && algorithm.name) || algorithm || '').toUpperCase();
    if (name.indexOf('AES-GCM') >= 0) return 'AES-GCM';
    if (name.indexOf('AES-CBC') >= 0) return 'AES-CBC';
    if (name.indexOf('AES-ECB') >= 0) return 'AES-ECB';
    if (name.indexOf('PBKDF2') >= 0) return 'PBKDF2';
    if (name.indexOf('HMAC') >= 0) return 'HMAC';
    return name;
  }
  function makeKey(type, algorithm, extractable, usages, bytes) {
    return { type: type, algorithm: algorithm, extractable: !!extractable, usages: usages || [], _raw: bytesToBase64(bytes) };
  }
  function nativeResult(text) {
    if (typeof text === 'string' && text.charAt(0) === '!') {
      var error = new Error(text.slice(1) || 'The operation failed.');
      error.name = 'OperationError';
      throw error;
    }
    return bufferFrom(base64ToBytes(text));
  }
  function aes(encrypt, algorithm, key, data) {
    var mode = algorithmName(algorithm);
    if (mode !== 'AES-CBC' && mode !== 'AES-GCM' && mode !== 'AES-ECB') throw new Error('Unsupported algorithm: ' + mode);
    if (mode === 'AES-GCM' && algorithm.tagLength && algorithm.tagLength !== 128) throw new Error('Only 128-bit AES-GCM tags are supported');
    if (mode === 'AES-GCM' && algorithm.additionalData) throw new Error('AES-GCM additionalData is not supported');
    var iv = algorithm && algorithm.iv ? bytesToBase64(toBytes(algorithm.iv)) : '';
    return nativeResult(N.aes(encrypt, mode, key._raw, iv, bytesToBase64(toBytes(data))));
  }
  var subtle = {
    digest: function (algorithm, data) {
      try {
        var out = N.digest(hashName(algorithm), bytesToBase64(toBytes(data)));
        return Promise.resolve(bufferFrom(base64ToBytes(out)));
      } catch (e) { return Promise.reject(e); }
    },
    importKey: function (format, keyData, algorithm, extractable, usages) {
      try {
        if (String(format).toLowerCase() !== 'raw') throw new Error('Only raw keys are supported');
        var name = algorithmName(algorithm);
        var normalized = { name: name };
        if (name === 'HMAC') normalized.hash = { name: hashName(algorithm.hash || 'SHA-256') };
        var bytes = toBytes(keyData);
        if (name === 'AES-CBC' || name === 'AES-GCM' || name === 'AES-ECB') normalized.length = bytes.length * 8;
        if (['HMAC', 'AES-CBC', 'AES-GCM', 'AES-ECB', 'PBKDF2'].indexOf(name) === -1) throw new Error('Unsupported algorithm: ' + name);
        return Promise.resolve(makeKey('secret', normalized, extractable, usages, bytes));
      } catch (e) { return Promise.reject(e); }
    },
    exportKey: function (format, key) {
      if (String(format).toLowerCase() !== 'raw') return Promise.reject(new Error('Only raw keys are supported'));
      return Promise.resolve(bufferFrom(base64ToBytes(key._raw)));
    },
    generateKey: function (algorithm, extractable, usages) {
      try {
        var name = algorithmName(algorithm);
        if (name !== 'AES-CBC' && name !== 'AES-GCM' && name !== 'HMAC') throw new Error('Unsupported algorithm: ' + name);
        var bits = algorithm.length || 256;
        var bytes = base64ToBytes(N.randomBytes(bits / 8));
        var normalized = { name: name, length: bits };
        if (name === 'HMAC') normalized.hash = { name: hashName(algorithm.hash || 'SHA-256') };
        return Promise.resolve(makeKey('secret', normalized, extractable, usages, bytes));
      } catch (e) { return Promise.reject(e); }
    },
    sign: function (algorithm, key, data) {
      try {
        var out = N.hmac(key.algorithm.hash.name, key._raw, bytesToBase64(toBytes(data)));
        return Promise.resolve(bufferFrom(base64ToBytes(out)));
      } catch (e) { return Promise.reject(e); }
    },
    verify: function (algorithm, key, signature, data) {
      return subtle.sign(algorithm, key, data).then(function (expected) {
        var a = new Uint8Array(expected);
        var b = toBytes(signature);
        if (a.length !== b.length) return false;
        var diff = 0;
        for (var i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
        return diff === 0;
      });
    },
    encrypt: function (algorithm, key, data) {
      try { return Promise.resolve(aes(true, algorithm, key, data)); } catch (e) { return Promise.reject(e); }
    },
    decrypt: function (algorithm, key, data) {
      try { return Promise.resolve(aes(false, algorithm, key, data)); } catch (e) { return Promise.reject(e); }
    },
    deriveBits: function (algorithm, key, length) {
      try {
        if (algorithmName(algorithm) !== 'PBKDF2') throw new Error('Only PBKDF2 is supported');
        var out = N.pbkdf2(key._raw, bytesToBase64(toBytes(algorithm.salt)), algorithm.iterations || 1000,
          length || 256, hashName(algorithm.hash || 'SHA-256'));
        return Promise.resolve(nativeResult(out));
      } catch (e) { return Promise.reject(e); }
    },
    deriveKey: function (algorithm, key, derivedAlgorithm, extractable, usages) {
      var bits = (derivedAlgorithm && derivedAlgorithm.length) || 256;
      return subtle.deriveBits(algorithm, key, bits).then(function (raw) {
        var name = algorithmName(derivedAlgorithm);
        var normalized = { name: name, length: bits };
        if (name === 'HMAC') normalized.hash = { name: hashName(derivedAlgorithm.hash || 'SHA-256') };
        return makeKey('secret', normalized, extractable, usages, new Uint8Array(raw));
      });
    }
  };
  G.crypto = {
    subtle: subtle,
    getRandomValues: function (array) {
      if (!ArrayBuffer.isView(array)) throw new TypeError('Expected a typed array');
      var bytes = base64ToBytes(N.randomBytes(array.byteLength));
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(bytes);
      return array;
    },
    randomUUID: function () {
      var b = base64ToBytes(N.randomBytes(16));
      b[6] = (b[6] & 0x0f) | 0x40;
      b[8] = (b[8] & 0x3f) | 0x80;
      var hex = '';
      for (var i = 0; i < 16; i++) hex += (b[i] < 16 ? '0' : '') + b[i].toString(16);
      return hex.slice(0, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16) + '-' + hex.slice(16, 20) + '-' + hex.slice(20);
    }
  };

  G.structuredClone = function (value) { return value === undefined ? undefined : JSON.parse(JSON.stringify(value)); };

  // ---- localStorage (Apple TV: per provider and profile, kept on the device) --
  var storage = {
    getItem: function (key) {
      var value = N.storageGet(String(key));
      return value === undefined ? null : value;
    },
    setItem: function (key, value) {
      if (!N.storageSet(String(key), String(value))) {
        var error = new Error('The plugin storage is full.');
        error.name = 'QuotaExceededError';
        throw error;
      }
    },
    removeItem: function (key) { N.storageRemove(String(key)); },
    clear: function () { N.storageClear(); },
    key: function (index) {
      var keys = N.storageKeys();
      return index >= 0 && index < keys.length ? keys[index] : null;
    }
  };
  Object.defineProperty(storage, 'length', { get: function () { return N.storageKeys().length; } });
  G.localStorage = storage;

  // ---- Android runtime compatibility --------------------------------------
  // What the Nuvio Android apps give plugins beyond browser globals: cheerio
  // (jsoup there, SwiftSoup here), crypto-js 4.2.0, require() for both, and a
  // WebAssembly placeholder.

  var CONTAINS_QUOTED = /:contains\(["']([^"']+)["']\)/g;
  function domSelector(selector) { return String(selector == null ? '' : selector).replace(CONTAINS_QUOTED, ':contains($1)'); }
  function domIds(json) { try { return JSON.parse(json) || []; } catch (e) { return []; } }
  function one(id) { return id && id !== '__NONE__' ? [id] : []; }
  function unique(ids) {
    var seen = {};
    return ids.filter(function (id) { if (seen[id]) return false; seen[id] = true; return true; });
  }

  function cheerioWrap(docId, ids) {
    var wrapper = {
      _docId: docId,
      _elementIds: ids,
      length: ids.length,
      cheerio: '[cheerio object]',
      each: function (callback) {
        for (var i = 0; i < ids.length; i++) {
          var el = cheerioWrap(docId, [ids[i]]);
          if (callback.call(el, i, el) === false) break;
        }
        return wrapper;
      },
      find: function (selector) {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(domIds(N.domFind(ids[i], domSelector(selector))));
        return cheerioWrap(docId, all);
      },
      children: function (selector) {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(domIds(N.domChildren(ids[i], selector ? domSelector(selector) : '')));
        return cheerioWrap(docId, all);
      },
      parent: function () {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(one(N.domParent(ids[i])));
        return cheerioWrap(docId, unique(all));
      },
      parents: function (selector) {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(domIds(N.domParents(ids[i], selector ? domSelector(selector) : '')));
        return cheerioWrap(docId, unique(all));
      },
      closest: function (selector) {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(one(N.domClosest(ids[i], domSelector(selector))));
        return cheerioWrap(docId, unique(all));
      },
      siblings: function (selector) {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(domIds(N.domSiblings(ids[i], selector ? domSelector(selector) : '')));
        return cheerioWrap(docId, unique(all));
      },
      next: function () {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(one(N.domNext(ids[i])));
        return cheerioWrap(docId, all);
      },
      prev: function () {
        var all = [];
        for (var i = 0; i < ids.length; i++) all = all.concat(one(N.domPrev(ids[i])));
        return cheerioWrap(docId, all);
      },
      text: function () { return ids.length ? N.domText(ids.join(',')) : ''; },
      html: function () { return ids.length ? N.domHtml(ids[0]) : null; },
      attr: function (name) {
        if (!ids.length) return undefined;
        if (name && typeof name === 'object') return wrapper;
        var value = N.domAttr(ids[0], String(name));
        return value === '__UNDEFINED__' ? undefined : value;
      },
      data: function (name) {
        if (!ids.length) return undefined;
        var value = N.domAttr(ids[0], 'data-' + String(name));
        if (value === '__UNDEFINED__') return undefined;
        try { return JSON.parse(value); } catch (e) { return value; }
      },
      val: function () { return wrapper.attr('value'); },
      hasClass: function (name) {
        for (var i = 0; i < ids.length; i++) {
          var cls = N.domAttr(ids[i], 'class');
          if (cls !== '__UNDEFINED__' && (' ' + cls + ' ').replace(/\s+/g, ' ').indexOf(' ' + name + ' ') >= 0) return true;
        }
        return false;
      },
      is: function (selector) {
        if (typeof selector === 'function') {
          for (var i = 0; i < ids.length; i++) {
            var el = cheerioWrap(docId, [ids[i]]);
            if (selector.call(el, i, el)) return true;
          }
          return false;
        }
        for (var j = 0; j < ids.length; j++) if (N.domIs(ids[j], domSelector(selector))) return true;
        return false;
      },
      filter: function (selector) {
        var kept = [];
        for (var i = 0; i < ids.length; i++) {
          var el = cheerioWrap(docId, [ids[i]]);
          var keep = typeof selector === 'function' ? selector.call(el, i, el) : N.domIs(ids[i], domSelector(selector));
          if (keep) kept.push(ids[i]);
        }
        return cheerioWrap(docId, kept);
      },
      not: function (selector) {
        var kept = [];
        for (var i = 0; i < ids.length; i++) {
          var el = cheerioWrap(docId, [ids[i]]);
          var drop = typeof selector === 'function' ? selector.call(el, i, el) : N.domIs(ids[i], domSelector(selector));
          if (!drop) kept.push(ids[i]);
        }
        return cheerioWrap(docId, kept);
      },
      first: function () { return cheerioWrap(docId, ids.length ? [ids[0]] : []); },
      last: function () { return cheerioWrap(docId, ids.length ? [ids[ids.length - 1]] : []); },
      eq: function (index) {
        var i = index < 0 ? ids.length + index : index;
        return cheerioWrap(docId, i >= 0 && i < ids.length ? [ids[i]] : []);
      },
      slice: function (start, end) { return cheerioWrap(docId, ids.slice(start, end)); },
      get: function (index) {
        if (typeof index === 'number') {
          var i = index < 0 ? ids.length + index : index;
          return i >= 0 && i < ids.length ? cheerioWrap(docId, [ids[i]]) : undefined;
        }
        return ids.map(function (id) { return cheerioWrap(docId, [id]); });
      },
      map: function (callback) {
        var results = [];
        for (var i = 0; i < ids.length; i++) {
          var el = cheerioWrap(docId, [ids[i]]);
          var result = callback.call(el, i, el);
          if (result === undefined || result === null) continue;
          if (Array.isArray(result)) results = results.concat(result); else results.push(result);
        }
        return {
          length: results.length,
          get: function (index) { return typeof index === 'number' ? results[index] : results; },
          toArray: function () { return results; },
          join: function (separator) { return results.join(separator); }
        };
      },
      toArray: function () { return ids.map(function (id) { return cheerioWrap(docId, [id]); }); }
    };
    for (var k = 0; k < ids.length; k++) {
      (function (index) {
        Object.defineProperty(wrapper, index, { get: function () { return cheerioWrap(docId, [ids[index]]); }, enumerable: false });
      })(k);
    }
    return wrapper;
  }

  var cheerio = {
    load: function (html) {
      var docId = N.domLoad(String(html == null ? '' : html));
      var $ = function (selector, context) {
        if (selector && selector._elementIds) return selector;
        if (context && context._elementIds) return context.find(selector);
        if (typeof selector !== 'string' || !selector) return cheerioWrap(docId, []);
        return cheerioWrap(docId, domIds(N.domSelect(docId, domSelector(selector))));
      };
      $.html = function (el) {
        if (el && el._elementIds) return el._elementIds.length ? N.domOuterHtml(el._elementIds[0]) : '';
        return N.domOuterHtml(docId);
      };
      $.text = function (el) {
        if (el && el._elementIds) return el.text();
        return N.domText(docId);
      };
      $.root = function () { return cheerioWrap(docId, [docId]); };
      return $;
    }
  };
  G.cheerio = cheerio;

  var cryptoJS = null;
  function loadCryptoJS() {
    if (!cryptoJS) {
      var module = { exports: {} };
      (new Function('module', 'exports', 'define', N.moduleSource('crypto-js')))(module, module.exports, undefined);
      cryptoJS = module.exports;
    }
    return cryptoJS;
  }
  // Loaded on first use: most plugins never touch it.
  Object.defineProperty(G, 'CryptoJS', {
    configurable: true,
    enumerable: false,
    get: function () {
      var lib = loadCryptoJS();
      Object.defineProperty(G, 'CryptoJS', { value: lib, writable: true, configurable: true });
      return lib;
    },
    set: function (value) {
      Object.defineProperty(G, 'CryptoJS', { value: value, writable: true, configurable: true });
    }
  });

  G.require = function (name) {
    var id = String(name);
    if (id === 'cheerio' || id === 'cheerio-without-node-native' || id === 'react-native-cheerio') return cheerio;
    if (id === 'crypto-js') return loadCryptoJS();
    throw new Error("Module '" + id + "' is not available");
  };

  if (typeof G.WebAssembly === 'undefined') {
    G.WebAssembly = {
      instantiate: function () {
        N.log('warn', 'WebAssembly.instantiate called (placeholder; WebAssembly is not available on Apple TV)');
        return Promise.resolve({ instance: { exports: {} }, module: {} });
      }
    };
  }

  // ---- Apple TV extras: NUVIO.settings, NUVIO.files, NUVIO.server --------
  G.NUVIO = {
    platform: 'tvos',
    settings: {
      /** The provider's saved settings (a copy). */
      get: function () { return JSON.parse(JSON.stringify(G.SCRAPER_SETTINGS || {})); },
      /** Saves settings (e.g. from a configuration page); true when saved. */
      save: function (values) {
        var object = values && typeof values === 'object' ? values : {};
        var ok = N.settingsSave(JSON.stringify(object));
        if (ok) G.SCRAPER_SETTINGS = JSON.parse(JSON.stringify(object));
        return !!ok;
      }
    },
    files: {
      /** Text of a stored file, or null. */
      read: function (name) {
        var value = N.fileRead(String(name));
        return value === undefined ? null : value;
      },
      /** Stores text under a name; throws QuotaExceededError when full. */
      write: function (name, text) {
        if (!N.fileWrite(String(name), String(text))) {
          var error = new Error('The plugin file storage is full.');
          error.name = 'QuotaExceededError';
          throw error;
        }
      },
      remove: function (name) { N.fileRemove(String(name)); },
      list: function () { return N.fileList(); },
      usage: function () { return N.fileUsage(); }
    },
    server: {
      /** The address of this provider's handleRequest on this Apple TV
       *  (http://127.0.0.1:…/plugin/<provider>/<path>), for the player. */
      url: function (path) { return N.routeURL(String(path === undefined || path === null ? '' : path)); }
    }
  };

  // ---- invocation ---------------------------------------------------------
  // `callId` tells concurrent calls in one (kept-alive) context apart.
  // `emitIndex` is the argument (an object) that gets `emit(list)` for
  // progressive results — the context argument of getStreams.
  G.__nuvioInvoke = function (name, args, callId, emitIndex) {
    var exported = G.module && G.module.exports;
    var target = exported && typeof exported[name] === 'function' ? exported[name]
      : (typeof G[name] === 'function' ? G[name] : null);
    if (!target) {
      N.done(null, '__missing__', callId);
      return;
    }
    args = args || [];
    if (typeof emitIndex === 'number' && emitIndex >= 0 && args[emitIndex] && typeof args[emitIndex] === 'object') {
      args[emitIndex].emit = function (list) {
        try { N.emit(callId, JSON.stringify(list || [])); } catch (e) { N.log('warn', 'emit failed: ' + errorText(e)); }
      };
    }
    var settled = false;
    function succeed(value) {
      if (settled) return;
      settled = true;
      var json;
      try { json = JSON.stringify(value === undefined ? null : value); } catch (e) {
        N.done(null, 'The result could not be serialized: ' + errorText(e), callId);
        return;
      }
      N.done(json === undefined ? 'null' : json, null, callId);
    }
    function fail(error) {
      if (settled) return;
      settled = true;
      N.done(null, errorText(error), callId);
    }
    try {
      Promise.resolve(target.apply(exported || G, args)).then(succeed, fail);
    } catch (e) {
      fail(e);
    }
  };
})(this);
"""#
}
