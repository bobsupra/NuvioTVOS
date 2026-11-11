// Starts the original AIOStreams inside Nuvio on Apple TV.
//
// Nuvio runs this file in its embedded Node.js with these variables:
//   AIO_ROOT          the unpacked AIOStreams package (packages/server/dist/server.js …)
//   PORT              AIOStreams' own port; bound to 127.0.0.1 only
//   NUVIO_LAN_PORT    the port the configuration page is reachable on from the network
//   NUVIO_STATE_FILE  where the addon address of a saved configuration is written
//   NUVIO_BACKUP_FILE where a copy of the configuration (with its password) is
//                     written; Nuvio moves it to the Keychain at once
//   NUVIO_CONTROL_PORT / NUVIO_CONTROL_TOKEN
//                     Nuvio's own port (127.0.0.1 only) for versions: check
//                     for an update, install it for the next start
//   NUVIO_AIO_HOME, NUVIO_AIO_SOURCE, NUVIO_AIO_CURRENT, NUVIO_AIO_VERSION
//                     the versions (set by bootstrap.mjs)
//   NUVIO_WAKE_FILE   a file Nuvio writes to whenever it comes back from the
//                     Home screen: the ports are checked at once and the data
//                     refreshes wait a minute (watchForWakeUps)
//   NUVIO_FFPROBE_URL Nuvio's endpoint for probing files, once Nuvio has
//                     one: AIOStreams' ffprobe then goes there
//                     (ffprobe-bridge.mjs, FFPROBE.md)
//   NUVIO_PLUGINS_URL Nuvio's plugins as Stremio add-ons on this Apple TV
//                     (`plugins.json`, `p/<key>/manifest.json` …): the
//                     "Nuvio plugins" card on the configuration page adds them
// plus AIOStreams' usual environment (DATABASE_URI, SECRET_KEY, BASE_URL …).
//
// The network port is a small proxy in front of AIOStreams. It forwards every
// request unchanged and watches the configuration page's user API: creating a
// configuration (POST /api/v1/user), loading one with its uuid and password
// (session + GET) and saving changes (PUT). From those Nuvio gets the addon
// address (NUVIO_STATE_FILE) — nothing to copy by hand — and a backup of the
// configuration: tvOS keeps AIOStreams' database in Caches, which it may clear.
//
// A sooner start: AIOStreams refreshes its data (anime databases, datasets,
// templates) from the internet before it answers. Those refreshes wait here
// until it answers and nobody is searching, and then run as AIOStreams would
// have run them; until then it works with the data it has on disk. Nuvio
// learns that AIOStreams answers the moment it starts listening, and the
// times of the start (NUVIO_T0_MS: when Nuvio started Node.js) go to the
// state file and the log.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { installFfprobeBridge } from './ffprobe-bridge.mjs';

const aioRoot = process.env.AIO_ROOT;
const aioPort = Number(process.env.PORT || 8770);
const lanPort = Number(process.env.NUVIO_LAN_PORT || 0);
const stateFile = process.env.NUVIO_STATE_FILE;
const backupFile = process.env.NUVIO_BACKUP_FILE;
const controlPort = Number(process.env.NUVIO_CONTROL_PORT || 0);
const controlToken = process.env.NUVIO_CONTROL_TOKEN || '';
const aioHome = process.env.NUVIO_AIO_HOME;
const aioSource = process.env.NUVIO_AIO_SOURCE || '';
const currentVersion = process.env.NUVIO_AIO_VERSION || '';
const wakeFile = process.env.NUVIO_WAKE_FILE || '';
const here = path.dirname(fileURLToPath(import.meta.url));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function log(message) {
  console.log(`[nuvio] ${message}`);
}

// MARK: times of the start (seconds after Nuvio started Node.js)

const startup = globalThis.nuvioStartup || { t0: Number(process.env.NUVIO_T0_MS) || Date.now(), marks: {} };
globalThis.nuvioStartup = startup;
const sinceStart = () => Number(((Date.now() - startup.t0) / 1000).toFixed(2));
function mark(name) {
  if (startup.marks[name] === undefined) startup.marks[name] = sinceStart();
}
mark('main');

function startupLine() {
  const m = startup.marks;
  const parts = [];
  for (const [key, label] of [['node', 'Node.js'], ['main', 'installer done'], ['core', 'AIOStreams core loaded'], ['loaded', 'AIOStreams loaded'], ['listening', 'listening'], ['ready', 'answering']]) {
    if (m[key] !== undefined) parts.push(`${label} ${m[key]}`);
  }
  if (m.firstAsked !== undefined) {
    parts.push(`first streams asked ${m.firstAsked}${m.firstAnswered !== undefined ? `, answered ${m.firstAnswered} (HTTP ${startup.firstStatus})` : ''}`);
  }
  if (held.length) {
    parts.push(startup.heldSeconds !== undefined
      ? `${held.length} data refreshes after the start (${startup.heldSeconds} s, done ${m.refreshed})`
      : `${held.length} data refreshes held until after the start`);
  }
  return parts.join(' · ');
}

function reportStartup(what) {
  log(`start (${what}), seconds after Nuvio started Node.js: ${startupLine()}`);
  try {
    writeState({ startup: { ...startup.marks, firstStatus: startup.firstStatus, held: held.length, heldSeconds: startup.heldSeconds } });
  } catch {}
}

// MARK: AIOStreams' own server

// What AIOStreams answers: stream searches (Nuvio's warm-up, marked with
// x-nuvio-warmup, apart) and how many requests are open, for the warm-up
// and the held refreshes.
const activity = { streamRequests: 0, lastStreamAt: 0, open: 0, lastEnd: 0 };

function watchRequest(request, response) {
  const stream = /\/stream\//.test(request.url || '');
  const warmUp = request.headers['x-nuvio-warmup'] === '1';
  const first = stream && !warmUp && activity.streamRequests === 0;
  if (stream && !warmUp) {
    activity.streamRequests++;
    activity.lastStreamAt = Date.now();
  }
  if (first) mark('firstAsked');
  activity.open++;
  let done = false;
  const end = () => {
    if (done) return;
    done = true;
    activity.open--;
    activity.lastEnd = Date.now();
    if (first) {
      mark('firstAnswered');
      startup.firstStatus = response.statusCode;
      reportStartup('first streams');
    }
  };
  response.on('finish', end);
  response.on('close', end);
}

// The three servers, to listen again after tvOS put Nuvio to sleep.
let aioServer = null;
let proxyServer = null;
let controlServer = null;

let listening = false;
let resolveListening;
const listeningNow = new Promise((resolve) => { resolveListening = resolve; });

// AIOStreams calls app.listen(PORT), which listens on every interface. Here
// only the proxy below is reachable from the network.
const originalListen = net.Server.prototype.listen;
net.Server.prototype.listen = function (...args) {
  if (args[0] === aioPort || args[0] === String(aioPort)) {
    const callback = args.find((value) => typeof value === 'function');
    aioServer = this;
    this.on('error', (error) => log(`AIOStreams' port ${aioPort}: ${error && error.message ? error.message : error}`));
    this.once('listening', () => {
      listening = true;
      refreshesHeld = false;
      mark('listening');
      resolveListening();
    });
    if (this instanceof http.Server) this.on('request', watchRequest);
    return originalListen.call(this, aioPort, '127.0.0.1', callback);
  }
  return originalListen.apply(this, args);
};

// MARK: Nuvio's plugins as add-ons

// The "Nuvio plugins" card on the configuration page: every plugin set
// "Through AIOStreams" in Nuvio becomes an add-on of its own, with its name,
// on Nuvio's plugin server (NUVIO_PLUGINS_URL, 127.0.0.1 only). Which plugins
// that are is decided in Nuvio; the card only has the usual add-on options
// (timeout, resources, …), the same for each of them. Without plugins (off
// in Nuvio, or none set so) the card gives no add-ons.
const pluginsUrl = process.env.NUVIO_PLUGINS_URL || '';
const NUVIO_PLUGINS_PRESET = 'nuvio-plugins';
const pluginList = { at: 0, plugins: [], pending: null, problem: '' };

function fetchPluginList() {
  return new Promise((resolve, reject) => {
    const request = http.get(`${pluginsUrl}plugins.json`, { agent: false, timeout: 3000 }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        if (response.statusCode !== 200) return reject(new Error(`HTTP ${response.statusCode}`));
        try {
          const plugins = JSON.parse(Buffer.concat(chunks).toString('utf8')).plugins;
          resolve(Array.isArray(plugins) ? plugins.filter((plugin) => plugin && typeof plugin.key === 'string' && plugin.key) : []);
        } catch (error) {
          reject(error);
        }
      });
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(new Error('no answer in 3 s')));
    request.on('error', reject);
  });
}

/** The plugins Nuvio gives AIOStreams; asked again after five seconds. */
async function nuvioPlugins() {
  if (!pluginsUrl) return [];
  if (Date.now() - pluginList.at < 5000) return pluginList.plugins;
  if (!pluginList.pending) {
    pluginList.pending = fetchPluginList()
      .then((plugins) => {
        if (pluginList.problem) log('Nuvio plugins answer again');
        pluginList.problem = '';
        return plugins;
      })
      .catch((error) => {
        const problem = error && error.message ? error.message : String(error);
        if (problem !== pluginList.problem) log(`Nuvio plugins: none (${problem})`);
        pluginList.problem = problem;
        return [];
      })
      .then((plugins) => {
        pluginList.plugins = plugins;
        pluginList.at = Date.now();
        pluginList.pending = null;
        return plugins;
      });
  }
  return pluginList.pending;
}

function addNuvioPluginsPreset(core) {
  const presets = core.PresetManager;
  if (!presets || typeof presets.fromId !== 'function' || typeof presets.getPresetList !== 'function') {
    log('no "Nuvio plugins" card: no PresetManager in this AIOStreams');
    return;
  }
  let Custom;
  try {
    Custom = presets.fromId('custom');
  } catch (error) {
    log(`no "Nuvio plugins" card: ${error && error.message ? error.message : error}`);
    return;
  }
  const kept = new Set(['timeout', 'resources', 'mediaTypes', 'pinPosition', 'libraryAddon', 'formatPassthrough', 'resultPassthrough']);
  const clamp = (value, constraints) => Math.min(Math.max(value, constraints?.min ?? value), constraints?.max ?? value);

  class NuvioPluginsPreset extends Custom {
    static get METADATA() {
      const base = super.METADATA;
      const timeoutOption = base.OPTIONS.find((option) => option.id === 'timeout');
      const timeout = clamp(20000, timeoutOption?.constraints);
      return {
        ...base,
        ID: NUVIO_PLUGINS_PRESET,
        NAME: 'Nuvio plugins',
        DESCRIPTION: 'The plugins set "Through AIOStreams" in Nuvio on this Apple TV, each as an add-on of its own: their streams, subtitles, catalogs and details. Which plugins come is set in Nuvio (Settings, Plugins, a plugin, Through AIOStreams). A plugin\'s streams come when it has finished.',
        URL: [],
        TIMEOUT: timeout,
        OPTIONS: base.OPTIONS
          .filter((option) => kept.has(option.id))
          .map((option) => (option.id === 'timeout' ? { ...option, default: timeout } : option)),
        SUPPORTED_SERVICES: [],
        SUPPORTED_STREAM_TYPES: ['http'],
        SUPPORTED_RESOURCES: ['stream', 'subtitles', 'catalog', 'meta'],
      };
    }

    // What AIOStreams took from a plugin, in the log: each search makes a parser
    // per add-on, and AIOStreams hands it every stream the plugin answered with.
    static getParser() {
      const Base = super.getParser();
      return class NuvioPluginParser extends Base {
        parse(stream) {
          const parsed = super.parse(stream);
          if (!this.nuvioCount) {
            const count = { all: 0, skipped: 0, types: {} };
            this.nuvioCount = count;
            setImmediate(() => {
              const types = Object.entries(count.types).map(([type, n]) => `${n} ${type}`).join(', ');
              const name = (this.addon && this.addon.name) || 'a Nuvio plugin';
              log(`AIOStreams took ${count.all - count.skipped} of ${count.all} streams from ${name}${types ? ` (${types})` : ''}`);
            });
          }
          this.nuvioCount.all++;
          if (!parsed || parsed.skip) this.nuvioCount.skipped++;
          else this.nuvioCount.types[parsed.type || '?'] = (this.nuvioCount.types[parsed.type || '?'] || 0) + 1;
          return parsed;
        }
      };
    }

    static async generateAddons(userData, options) {
      const metadata = this.METADATA;
      const plugins = await nuvioPlugins();
      return plugins.map((plugin) => ({
        name: typeof plugin.name === 'string' && plugin.name ? plugin.name : plugin.key,
        identifier: plugin.key,
        manifestUrl: `${pluginsUrl}p/${encodeURIComponent(plugin.key)}/manifest.json`,
        enabled: true,
        library: options.libraryAddon ?? false,
        resources: options.resources || undefined,
        mediaTypes: options.mediaTypes || [],
        timeout: options.timeout || metadata.TIMEOUT,
        preset: { id: '', type: NUVIO_PLUGINS_PRESET, options },
        formatPassthrough: options.formatPassthrough ?? false,
        resultPassthrough: options.resultPassthrough ?? false,
        pinPosition: options.pinPosition || undefined,
        headers: { 'User-Agent': metadata.USER_AGENT },
      }));
    }
  }

  const fromId = presets.fromId;
  presets.fromId = function (id, ...rest) {
    return id === NUVIO_PLUGINS_PRESET ? NuvioPluginsPreset : fromId.call(this, id, ...rest);
  };
  const getPresetList = presets.getPresetList;
  presets.getPresetList = function (...args) {
    const list = getPresetList.apply(this, args);
    if (!Array.isArray(list) || list.some((preset) => preset && preset.ID === NUVIO_PLUGINS_PRESET)) return list;
    const metadata = NuvioPluginsPreset.METADATA;
    const card = {};
    for (const key of ['ID', 'NAME', 'LOGO', 'DESCRIPTION', 'SUPPORTED_RESOURCES', 'SUPPORTED_STREAM_TYPES', 'SUPPORTED_SERVICES', 'OPTIONS', 'BUILTIN', 'DISABLED', 'CATEGORY']) {
      card[key] = metadata[key];
    }
    const custom = list.findIndex((preset) => preset && preset.ID === 'custom');
    list.splice(custom + 1, 0, card);
    return list;
  };
  log(`"Nuvio plugins" card ready${pluginsUrl ? '' : ' (no plugin server given: it adds nothing)'}`);
}

// MARK: data refreshes after the start

// Refreshes AIOStreams runs on its own (TaskManager.runNow) before it listens:
// anime databases, datasets, remote templates. Held, they report success at
// once; AIOStreams carries on with what it has on disk (a dataset it has
// never downloaded comes with the refresh). Only these kinds: anything else
// runs as usual, and after AIOStreams listens nothing is held.
const HELD_KINDS = new Set(['data-sync', 'templates']);
const held = [];
let refreshesHeld = true;
let runHeld = null;

async function holdStartupRefreshes() {
  try {
    const resolve = createRequire(path.join(aioRoot, 'packages/server/dist/server.js')).resolve;
    const core = await import(pathToFileURL(resolve('@aiostreams/core')).href);
    mark('core');
    try {
      addNuvioPluginsPreset(core);
    } catch (error) {
      log(`no "Nuvio plugins" card: ${error && error.message ? error.message : error}`);
    }
    const tasks = core.TaskManager;
    if (!tasks || typeof tasks.runNow !== 'function' || typeof tasks.get !== 'function') {
      log('data refreshes stay in the start: no TaskManager in this AIOStreams');
      return;
    }
    const runNow = tasks.runNow;
    tasks.runNow = function (id, ...rest) {
      const task = refreshesHeld ? tasks.get(id) : null;
      if (task && HELD_KINDS.has(task.category)) {
        if (!held.includes(id)) held.push(id);
        return Promise.resolve({ ok: true, message: 'after the start (Nuvio)' });
      }
      return runNow.call(tasks, id, ...rest);
    };
    runHeld = (id) => runNow.call(tasks, id);
    holdRefreshesAfterWakeUps(tasks);
  } catch (error) {
    log(`data refreshes stay in the start: ${error && error.message ? error.message : error}`);
  }
}

// After Nuvio was suspended (on the Home screen), refreshes that fell due
// meanwhile would run the moment it wakes up, while its network connections
// are still dead: they fail ("fetch failed"), and an anime database whose
// etag check failed is downloaded whole again. Scheduled refreshes of the same
// kinds as above (TaskManager's execute, which its timers and retries call)
// wait a minute after a wake-up, longer while a search runs, and then run as
// AIOStreams would have run them.
const WAKE_HOLD_MS = 60000;
let refreshesHeldUntil = 0;
let lastTick = 0; // watchForWakeUps' timer: a long gap means Node.js was frozen
const heldAfterWake = new Map();
let wakeRunner = null;

function holdRefreshesAfterWake() {
  refreshesHeldUntil = Date.now() + WAKE_HOLD_MS;
}

function holdRefreshesAfterWakeUps(tasks) {
  const execute = tasks.execute;
  if (typeof execute !== 'function') {
    log('data refreshes are not held after a wake-up: no TaskManager.execute in this AIOStreams');
    return;
  }
  const runLater = async () => {
    while (Date.now() < refreshesHeldUntil) await sleep(Math.max(500, refreshesHeldUntil - Date.now()));
    const latest = Date.now() + 30000;
    while (Date.now() < latest && (activity.open > 0 || Date.now() - activity.lastEnd < 3000)) await sleep(500);
    const entries = [...heldAfterWake.values()];
    heldAfterWake.clear();
    log(`${entries.length} data refresh${entries.length === 1 ? '' : 'es'} held after the wake-up: running now`);
    for (const entry of entries) {
      try {
        await execute.call(tasks, entry, false);
      } catch (error) {
        log(`refresh ${entry.def.id}: ${error && error.message ? error.message : error}`);
      }
    }
  };
  tasks.execute = function (entry, manual, ...rest) {
    const def = entry && entry.def;
    // Its timer may fire before watchForWakeUps' own after a sleep.
    if (lastTick && Date.now() - lastTick > 2500) holdRefreshesAfterWake();
    if (!manual && def && HELD_KINDS.has(def.category) && Date.now() < refreshesHeldUntil) {
      if (!heldAfterWake.has(def.id)) heldAfterWake.set(def.id, entry);
      if (!wakeRunner) wakeRunner = runLater().finally(() => { wakeRunner = null; });
      return Promise.resolve({ ok: true, message: 'after the wake-up (Nuvio)' });
    }
    return execute.call(this, entry, manual, ...rest);
  };
}

/** The held refreshes, once AIOStreams has answered for a while and is quiet. */
async function runHeldRefreshes() {
  if (!runHeld || !held.length) return;
  await sleep(10000);
  const latest = Date.now() + 60000;
  while (Date.now() < latest && (activity.open > 0 || Date.now() - activity.lastEnd < 3000)) await sleep(500);
  const begin = Date.now();
  for (const id of held) {
    try {
      const result = await runHeld(id);
      if (result && result.ok === false) log(`refresh ${id}: ${result.message || 'failed'}`);
    } catch (error) {
      log(`refresh ${id}: ${error && error.message ? error.message : error}`);
    }
  }
  startup.heldSeconds = Number(((Date.now() - begin) / 1000).toFixed(1));
  mark('refreshed');
  reportStartup('data refreshed');
}

function writeState(update) {
  if (!stateFile) return;
  let state = {};
  try {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch {
    // first write
  }
  Object.assign(state, update, { updatedAt: new Date().toISOString() });
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(`${stateFile}.tmp`, JSON.stringify(state, null, 2));
  fs.renameSync(`${stateFile}.tmp`, stateFile);
}

// The configuration page's user API: 'user' (/api/v1/user) or 'session'
// (/api/v1/user/session, logging in with uuid and password).
function userApi(request) {
  const match = /^\/api\/v\d+\/user(\/session)?\/?(\?|$)/.exec(request.url || '');
  if (!match || !['GET', 'POST', 'PUT'].includes(request.method)) return null;
  return match[1] ? 'session' : 'user';
}

function basicCredentials(request) {
  const match = /^Basic\s+(.+)$/i.exec(request.headers.authorization || '');
  if (!match) return null;
  const text = Buffer.from(match[1], 'base64').toString('utf8');
  const colon = text.indexOf(':');
  return colon > 0 ? { uuid: text.slice(0, colon), password: text.slice(colon + 1) } : null;
}

function decoded(buffer, encoding) {
  switch ((encoding || '').toLowerCase()) {
    case 'gzip': return zlib.gunzipSync(buffer);
    case 'deflate': return zlib.inflateSync(buffer);
    case 'br': return zlib.brotliDecompressSync(buffer);
    default: return buffer;
  }
}

function parsed(text) {
  try {
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

function saveAddon(uuid, encryptedPassword) {
  const manifest = `http://127.0.0.1:${aioPort}/stremio/${encodeURIComponent(uuid)}/${encodeURIComponent(encryptedPassword)}/manifest.json`;
  writeState({ manifest });
  log(`configuration ${uuid.slice(0, 8)}… in use, addon: /stremio/${uuid.slice(0, 8)}…/manifest.json`);
}

function saveBackup(uuid, password, config) {
  if (!backupFile || !config || typeof password !== 'string') return;
  fs.mkdirSync(path.dirname(backupFile), { recursive: true });
  fs.writeFileSync(`${backupFile}.tmp`, JSON.stringify({ uuid, password, config, savedAt: new Date().toISOString() }));
  fs.renameSync(`${backupFile}.tmp`, backupFile);
  log(`configuration ${uuid.slice(0, 8)}… backed up`);
}

let sessionCredentials = null; // the last login on the page

function observe(kind, request, requestBody, answer) {
  const body = parsed(requestBody.toString('utf8'));
  const data = (parsed(decoded(answer.body, answer.headers['content-encoding']).toString('utf8')).data) || {};
  const credentials = basicCredentials(request) || sessionCredentials;
  if (kind === 'session') {
    if (request.method === 'POST' && typeof body.uuid === 'string' && typeof body.password === 'string') {
      sessionCredentials = { uuid: typeof data.uuid === 'string' ? data.uuid : body.uuid, password: body.password };
    }
    return;
  }
  if (request.method === 'POST') {
    // A new configuration.
    if (typeof data.uuid === 'string' && typeof data.encryptedPassword === 'string') {
      saveAddon(data.uuid, data.encryptedPassword);
      saveBackup(data.uuid, body.password, body.config);
    }
  } else if (request.method === 'GET') {
    // An existing configuration, loaded with its uuid and password.
    const uuid = (data.userData && data.userData.uuid) || (credentials && credentials.uuid);
    if (uuid && typeof data.encryptedPassword === 'string') {
      saveAddon(uuid, data.encryptedPassword);
      if (credentials) saveBackup(uuid, credentials.password, data.userData);
    }
  } else if (request.method === 'PUT') {
    // Changes saved.
    const uuid = data.uuid || (credentials && credentials.uuid);
    if (uuid && credentials) saveBackup(uuid, credentials.password, body.config);
  }
}

function startProxy() {
  if (!lanPort) return;
  const proxy = http.createServer((request, response) => {
    const watch = userApi(request);
    const requestChunks = [];
    if (watch) request.on('data', (chunk) => requestChunks.push(chunk));
    const upstream = http.request(
      { host: '127.0.0.1', port: aioPort, method: request.method, path: request.url, headers: request.headers },
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
  });
  proxy.on('upgrade', (request, socket, head) => {
    const upstream = net.connect(aioPort, '127.0.0.1', () => {
      const lines = [`${request.method} ${request.url} HTTP/${request.httpVersion}`];
      for (let i = 0; i < request.rawHeaders.length; i += 2) lines.push(`${request.rawHeaders[i]}: ${request.rawHeaders[i + 1]}`);
      upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
      if (head && head.length) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
  });
  proxy.on('error', (error) => log(`configuration page port ${lanPort}: ${error.message}`));
  proxyServer = proxy;
  originalListen.call(proxy, lanPort, '0.0.0.0', () => log(`configuration page on port ${lanPort}`));
}

// MARK: versions (Check for updates / Update in Nuvio)

let update = { state: 'idle' };

async function installer() {
  return import(pathToFileURL(path.join(here, 'image-install.mjs')).href);
}

function versionsSummary(versions) {
  const label = (name) => (name && versions.labels && versions.labels[name] && versions.labels[name].tag) || null;
  return {
    current: label(versions.current) || currentVersion || null,
    previous: label(versions.previous),
    pending: label(versions.pending),
    source: aioSource || null,
  };
}

async function runUpdate() {
  update = { state: 'running', progress: 'Looking for the newest AIOStreams…' };
  try {
    const tools = await installer();
    const { tag } = await tools.latestVersion(aioSource);
    if (tag && tag === currentVersion) {
      update = { state: 'done', upToDate: true, version: tag };
      log(`AIOStreams ${tag} is the newest`);
      return;
    }
    const result = await tools.install({
      source: aioSource,
      tag,
      home: aioHome,
      shimsDir: path.join(here, 'shims'),
      log,
      onProgress: ({ phase, done, total }) => {
        update.progress = phase === 'download'
          ? `Downloading ${tag || ''} — ${(done / 1048576).toFixed(1)}${total ? ` / ${(total / 1048576).toFixed(1)}` : ''} MB`
          : `Preparing ${tag || ''}…`;
      },
    });
    const versions = tools.readVersions(aioHome);
    if (result.name === versions.current) {
      update = { state: 'done', upToDate: true, version: result.tag };
      return;
    }
    versions.pending = result.name;
    versions.labels[result.name] = { tag: result.tag, source: aioSource || tools.DEFAULT_SOURCE, installedAt: new Date().toISOString() };
    tools.saveVersions(aioHome, versions);
    update = { state: 'done', version: result.tag, pending: true };
    log(`AIOStreams ${result.tag} is installed; it starts with the next start of Nuvio`);
  } catch (error) {
    update = { state: 'failed', error: String(error && error.message ? error.message : error) };
    log(`update failed: ${update.error}`);
  }
}

function startControl() {
  if (!controlPort || !controlToken || !aioHome) return;
  const server = http.createServer(async (request, response) => {
    const send = (status, body) => {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(body));
    };
    if (request.headers['x-nuvio-token'] !== controlToken) return send(403, { error: 'forbidden' });
    try {
      if (request.method === 'GET' && request.url === '/versions') {
        return send(200, versionsSummary((await installer()).readVersions(aioHome)));
      }
      if (request.method === 'POST' && request.url === '/check') {
        const { tag } = await (await installer()).latestVersion(aioSource);
        return send(200, { latest: tag, current: currentVersion || null });
      }
      if (request.url === '/update') {
        if (request.method === 'POST' && update.state !== 'running') void runUpdate();
        return send(request.method === 'POST' ? 202 : 200, update);
      }
      if (request.method === 'GET' && request.url === '/activity') {
        return send(200, { streamRequests: activity.streamRequests, lastStreamAt: activity.lastStreamAt, open: activity.open, startup: startup.marks, wakeUps });
      }
      send(404, { error: 'not found' });
    } catch (error) {
      send(500, { error: String(error && error.message ? error.message : error) });
    }
  });
  server.on('error', (error) => log(`control port ${controlPort}: ${error.message}`));
  controlServer = server;
  originalListen.call(server, controlPort, '127.0.0.1');
}

function markReady() {
  if (!aioHome || !process.env.NUVIO_AIO_CURRENT) return;
  installer().then((tools) => {
    const versions = tools.readVersions(aioHome);
    if (versions.lastReady === process.env.NUVIO_AIO_CURRENT) return;
    versions.lastReady = process.env.NUVIO_AIO_CURRENT;
    tools.saveVersions(aioHome, versions);
  }).catch((error) => log(`versions: ${error.message}`));
}

function healthy() {
  return new Promise((resolve) => {
    const request = http.get({ host: '127.0.0.1', port: aioPort, path: '/api/v1/health', timeout: 2000 }, (answer) => {
      answer.resume();
      resolve((answer.statusCode || 0) < 500);
    });
    request.on('error', () => resolve(false));
    request.on('timeout', () => { request.destroy(); resolve(false); });
  });
}

/** Asks the moment AIOStreams listens (every 0.5 s in case that goes unseen). */
async function waitUntilReady() {
  const deadline = Date.now() + 5 * 60000;
  while (Date.now() < deadline) {
    if (!listening) await Promise.race([listeningNow, sleep(500)]);
    if (await healthy()) return true;
    if (listening) await sleep(50);
  }
  return false;
}

// MARK: after sleep

// When Nuvio goes to the Home screen, tvOS soon suspends it, and may take
// its listening ports away meanwhile: back in Nuvio, Node.js and AIOStreams
// run on, but nothing reaches them (no error either — a port just goes
// dead). Node.js' timers don't run while it is suspended, so a tick that
// comes much later than due means it slept: then all three ports listen
// again. Requests under way go on; idle kept-alive connections are closed
// (after a sleep they are dead anyway).
let wakeUps = 0;

function listenAgain(server, port, host, name, attempt = 0) {
  if (!server || !port) return;
  try { server.closeIdleConnections?.(); } catch {}
  try { server.close(); } catch {}
  setImmediate(() => {
    const retry = (error) => {
      if (attempt < 10) setTimeout(() => listenAgain(server, port, host, name, attempt + 1), 500);
      else log(`${name}: could not listen on port ${port} again: ${error && error.message ? error.message : error}`);
    };
    server.once('error', retry);
    try {
      originalListen.call(server, port, host, () => {
        server.removeListener('error', retry);
        if (attempt > 0) log(`${name}: listening on port ${port} again`);
      });
    } catch (error) {
      server.removeListener('error', retry);
      retry(error);
    }
  });
}

/** Whether a port on this Apple TV refuses connections (nobody listens). */
function refuses(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ port, host: '127.0.0.1' });
    let done = false;
    const finish = (refused) => {
      if (done) return;
      done = true;
      socket.destroy();
      resolve(refused);
    };
    socket.once('connect', () => finish(false));
    socket.once('error', (error) => finish(error && (error.code === 'ECONNREFUSED' || error.code === 'ECONNRESET')));
    // A slow answer is a busy server, not a missing one.
    socket.setTimeout(1500, () => finish(false));
  });
}

// tvOS takes the ports of a suspended app away, even after a few seconds on
// the Home screen, and the servers don't learn it: nothing answers on them
// any more, and nobody can tell Node.js through them. Two ways in, then:
// - Node.js notices it was frozen itself: its 1 s timer sees a gap;
// - whenever Nuvio comes back it writes to NUVIO_WAKE_FILE, which Node.js
//   watches (fs.watch: no polling).
// Either way Node.js checks whether AIOStreams' port still takes connections
// (a connection to itself on 127.0.0.1, closed at once); when it is refused,
// all three servers listen again — within milliseconds of Nuvio coming back.
// The data refreshes wait a minute after a wake-up (holdRefreshesAfterWakeUps).
// Only when the file can't be watched is the port checked every second.
function watchForWakeUps() {
  let busy = false;
  let quietUntil = 0;
  let watching = false;
  let lastCheck = Date.now();
  lastTick = Date.now();

  const check = (why) => {
    const now = Date.now();
    if (!listening || busy || now < quietUntil) return;
    busy = true;
    lastCheck = now;
    refuses(aioPort)
      .then((refused) => {
        if (!refused) return;
        wakeUps++;
        quietUntil = Date.now() + 3000;
        log(`${why}: the ports were gone, listening again (AIOStreams, configuration page, Nuvio's port)`);
        listenAgain(aioServer, aioPort, '127.0.0.1', 'AIOStreams');
        listenAgain(proxyServer, lanPort, '0.0.0.0', 'configuration page');
        listenAgain(controlServer, controlPort, '127.0.0.1', "Nuvio's port");
        try { writeState({ wakeUps, lastWakeUp: new Date().toISOString() }); } catch {}
      })
      .catch(() => {})
      .finally(() => { busy = false; });
  };

  const watchWakeFile = () => {
    const watcher = fs.watch(wakeFile, { persistent: false }, (event) => {
      holdRefreshesAfterWake();
      check('Nuvio is back from the Home screen');
      if (event === 'rename') {
        // Replaced instead of written: watch the new file.
        watcher.close();
        watching = false;
        setTimeout(() => { try { watchWakeFile(); } catch {} }, 200);
      }
    });
    watcher.on('error', () => { watching = false; });
    watching = true;
  };
  if (wakeFile) {
    try {
      if (!fs.existsSync(wakeFile)) fs.writeFileSync(wakeFile, '');
      watchWakeFile();
    } catch (error) {
      log(`Nuvio can't wake Node.js up (${error && error.message ? error.message : error}): the port is checked every second`);
    }
  }

  setInterval(() => {
    const now = Date.now();
    const asleep = now - lastTick;
    lastTick = now;
    if (asleep > 2500) {
      holdRefreshesAfterWake();
      check(`back after ${Math.round(asleep / 1000)} s asleep`);
    } else if (!watching && now - lastCheck >= 1000) {
      check('regular check');
    }
  }, 1000).unref();
}

// Inside Nuvio, Node runs in the app's own process: process.exit() would
// close Nuvio. AIOStreams stops instead, and Nuvio shows it.
const embedded = process.env.NUVIO_EMBEDDED === '1';
if (embedded) {
  process.exit = (code) => {
    log(`AIOStreams asked to exit (${code ?? 0}); Nuvio keeps running`);
    writeState({ status: 'stopped', exitCode: code ?? 0 });
    return undefined;
  };
}

process.on('uncaughtException', (error) => log(`uncaught: ${error && error.stack ? error.stack : error}`));
process.on('unhandledRejection', (error) => log(`unhandled rejection: ${error && error.stack ? error.stack : error}`));

if (!aioRoot) {
  log('AIO_ROOT is not set');
  throw new Error('AIO_ROOT is not set');
}
writeState({ status: 'starting', pid: process.pid, node: process.version, port: aioPort, lanPort, version: currentVersion || null });
process.chdir(aioRoot);
startProxy();
startControl();
log(`starting AIOStreams from ${aioRoot} (node ${process.version}, ${process.arch}, jitless: ${process.execArgv.includes('--jitless') || process.versions.mobile ? 'yes' : 'no'})`);
try {
  installFfprobeBridge(process.env.NUVIO_FFPROBE_URL, log);
} catch (error) {
  log(`ffprobe through Nuvio is off: ${error && error.message ? error.message : error}`);
}
await holdStartupRefreshes();
try {
  await import(pathToFileURL(path.join(aioRoot, 'packages/server/dist/server.js')).href);
  mark('loaded');
} catch (error) {
  log(`AIOStreams failed to load: ${error && error.stack ? error.stack : error}`);
  writeState({ status: 'failed', error: String(error && error.message ? error.message : error) });
  throw error;
}
const ready = await waitUntilReady();
if (ready) mark('ready');
const seconds = sinceStart().toFixed(1);
const memory = Math.round(process.memoryUsage().rss / 1048576);
writeState({ status: ready ? 'running' : 'not answering', startupSeconds: Number(seconds), rssMB: memory });
if (ready) {
  markReady();
  watchForWakeUps();
  reportStartup('answering');
  void runHeldRefreshes();
}
log(ready ? `AIOStreams is ready in ${seconds} s, ${memory} MB` : `AIOStreams did not answer within 5 minutes`);
setInterval(() => {
  writeState({ rssMB: Math.round(process.memoryUsage().rss / 1048576), heapMB: Math.round(process.memoryUsage().heapUsed / 1048576) });
}, 60000).unref();
