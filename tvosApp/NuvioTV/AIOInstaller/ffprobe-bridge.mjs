// ffprobe through Nuvio — AIOStreams' only outside program, which Apple TV
// can't run (no processes). Prepared ahead of Nuvio's side; see FFPROBE.md.
//
// AIOStreams runs ffprobe (media-info/ffprobe.ts) with execFile: once with
// -version to see whether it exists, and for a file that is played: format,
// streams and chapters, then a few frames of the video for HDR10+. With
// NUVIO_FFPROBE_URL set (Nuvio's endpoint), AIOStreams' ffprobe is
// "nuvio-ffprobe": each of those calls goes to Nuvio as a small JSON request
// and Nuvio answers what ffprobe would print (-print_format json), from its
// own player's probe. Without it nothing changes: AIOStreams finds no ffprobe
// and leaves the tracks out, as before.
import { createRequire, syncBuiltinESMExports } from 'node:module';
import { EventEmitter } from 'node:events';
import http from 'node:http';
import util from 'node:util';

export const FFPROBE_NAME = 'nuvio-ffprobe';

/** What AIOStreams asked ffprobe for, as Nuvio's request (FFPROBE.md). */
export function probeRequest(args) {
  if (args.includes('-version')) return { version: true };
  const request = { input: null, show: [] };
  const extra = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '-v' || arg === '-loglevel' || arg === '-print_format' || arg === '-of') {
      i++;
    } else if (arg === '-show_format' || arg === '-show_streams' || arg === '-show_chapters' || arg === '-show_frames') {
      request.show.push(arg.slice('-show_'.length));
    } else if (arg === '-select_streams') {
      request.selectStreams = args[++i];
    } else if (arg === '-read_intervals') {
      request.readIntervals = args[++i];
    } else if (arg === '-i') {
      request.input = args[++i];
    } else if (arg.startsWith('-')) {
      // Unknown to this bridge: passed on; Nuvio may ignore it.
      extra.push(arg);
      if (i + 1 < args.length - 1 && !args[i + 1].startsWith('-')) extra.push(args[++i]);
    } else {
      request.input = arg;
    }
  }
  if (extra.length) request.extra = extra;
  return request;
}

function failure(message, code, extra = {}) {
  return Object.assign(new Error(message), { code }, extra);
}

function ask(endpoint, body, { timeout, signal }) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body));
    const request = http.request(endpoint, {
      method: 'POST',
      // A connection of its own each time (probes are rare): one kept from
      // an earlier probe could be gone by now.
      agent: false,
      headers: { 'content-type': 'application/json', 'content-length': data.length },
      timeout: timeout || 30000,
      signal,
    }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        if ((response.statusCode || 0) === 404 || (response.statusCode || 0) === 501) {
          reject(failure(`${FFPROBE_NAME}: Nuvio does not probe files (HTTP ${response.statusCode})`, 'ENOENT'));
        } else if ((response.statusCode || 0) >= 300) {
          let message = text.slice(0, 300);
          try { message = JSON.parse(text).error || message; } catch {}
          reject(failure(`${FFPROBE_NAME}: ${message}`, 1, { stderr: message }));
        } else {
          resolve(text);
        }
      });
      response.on('error', reject);
    });
    request.on('timeout', () => request.destroy(failure(`${FFPROBE_NAME}: timed out`, 'ETIMEDOUT', { killed: true, signal: 'SIGTERM' })));
    request.on('error', (error) => {
      // Nobody listening: Nuvio has no probe, as if ffprobe were not installed.
      reject(error && error.code === 'ECONNREFUSED' ? failure(`${FFPROBE_NAME}: Nuvio does not probe files`, 'ENOENT') : error);
    });
    request.end(data);
  });
}

/** One ffprobe run through Nuvio: stdout as ffprobe would print it. */
export async function runProbe(endpoint, args, options = {}) {
  const request = probeRequest(args);
  const text = await ask(endpoint, request, options);
  if (request.version) {
    let version = 'nuvio';
    try { version = JSON.parse(text).version || version; } catch {}
    return `ffprobe version ${String(version).replace(/\s+/g, '-')} (Nuvio)\n`;
  }
  return text;
}

/**
 * From now on execFile('nuvio-ffprobe', …) asks Nuvio at `endpoint`, and
 * AIOStreams uses it (FFPROBE_PATH). Call before AIOStreams is imported.
 */
export function installFfprobeBridge(endpoint, log = () => {}) {
  if (!endpoint) return false;
  const childProcess = createRequire(import.meta.url)('node:child_process');
  const original = childProcess.execFile;
  if (original.nuvioBridge) return true;

  const bridged = function execFile(file, ...rest) {
    if (file !== FFPROBE_NAME) return original.call(this, file, ...rest);
    let args = [];
    let options = {};
    let callback = () => {};
    for (const value of rest) {
      if (Array.isArray(value)) args = value;
      else if (typeof value === 'function') callback = value;
      else if (value && typeof value === 'object') options = value;
    }
    // What execFile returns, enough for whoever keeps it.
    const child = new EventEmitter();
    const abort = new AbortController();
    child.kill = () => { abort.abort(); return true; };
    child.pid = undefined;
    const signal = options.signal ? AbortSignal.any([options.signal, abort.signal]) : abort.signal;
    runProbe(endpoint, args, { timeout: options.timeout, signal }).then(
      (stdout) => {
        callback(null, stdout, '');
        child.emit('exit', 0, null);
        child.emit('close', 0, null);
      },
      (error) => {
        callback(error, '', error.stderr || '');
        child.emit('exit', typeof error.code === 'number' ? error.code : 1, null);
        child.emit('close', typeof error.code === 'number' ? error.code : 1, null);
      },
    );
    return child;
  };
  // util.promisify(execFile) gives { stdout, stderr }, the bridge too.
  const promisified = original[util.promisify.custom];
  if (promisified) {
    bridged[util.promisify.custom] = (file, args, options) => {
      if (file !== FFPROBE_NAME) return promisified(file, args, options);
      return runProbe(endpoint, Array.isArray(args) ? args : [], (Array.isArray(args) ? options : args) || {})
        .then((stdout) => ({ stdout, stderr: '' }));
    };
  }
  bridged.nuvioBridge = true;
  childProcess.execFile = bridged;
  syncBuiltinESMExports();
  process.env.FFPROBE_PATH = FFPROBE_NAME;
  log(`ffprobe goes through Nuvio (${endpoint})`);
  return true;
}
