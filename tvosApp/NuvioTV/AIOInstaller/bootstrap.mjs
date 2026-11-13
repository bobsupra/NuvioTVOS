// Nuvio's entry point for AIOStreams in the embedded Node.js.
//
//   node bootstrap.mjs
//
// with (from Nuvio):
//   NUVIO_AIO_HOME        where the AIOStreams versions live (versions.json)
//   NUVIO_AIO_SOURCE      AIOStreams' official image (default) or a package
//   NUVIO_STATE_FILE      the state Nuvio reads (installing, running, …)
//   NUVIO_AIO_USE_PREVIOUS=1       go back to the previous version
//   NUVIO_AIO_LAST_START_FAILED=1  the last start never got ready
//
// Before AIOStreams starts: a version installed by Update becomes the current
// one; the previous version comes back when asked to, or when the current
// one never got ready since it was installed; with no version yet, the
// newest one is installed from the source (image-install.mjs). Then
// nuvio-main.mjs (next to this file) starts it. A failure here is reported,
// not fatal: an uncaught error would make Node.js close the whole app.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Times of the start, in seconds after Nuvio started Node.js (nuvio-main.mjs
// adds the rest and reports them).
const t0 = Number(process.env.NUVIO_T0_MS) || Date.now();
globalThis.nuvioStartup = { t0, marks: { node: Number(((Date.now() - t0) / 1000).toFixed(2)) } };

const here = path.dirname(fileURLToPath(import.meta.url));
const home = process.env.NUVIO_AIO_HOME;
const source = process.env.NUVIO_AIO_SOURCE || '';
const stateFile = process.env.NUVIO_STATE_FILE;

function log(message) {
  console.log(`[nuvio] ${message}`);
}

function writeState(update) {
  if (!stateFile) return;
  let state = {};
  try {
    state = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
  } catch {}
  Object.assign(state, update, { updatedAt: new Date().toISOString() });
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(`${stateFile}.tmp`, JSON.stringify(state, null, 2));
  fs.renameSync(`${stateFile}.tmp`, stateFile);
}

function reportFailure(error) {
  console.log(`[nuvio] AIOStreams could not be started: ${error && error.stack ? error.stack : error}`);
  try {
    writeState({ status: 'failed', error: String((error && error.message) || error).slice(0, 300) });
  } catch {}
  process.exitCode = 1;
}

const mb = (bytes) => `${(bytes / 1048576).toFixed(1)}`;

try {
  if (!home) throw new Error('NUVIO_AIO_HOME is not set');
  const installer = await import(pathToFileURL(path.join(here, 'image-install.mjs')).href);
  const versions = installer.readVersions(home);
  const installed = (name) => installer.isInstalled(home, name);
  const label = (name) => (versions.labels[name] && versions.labels[name].tag) || name;

  if (versions.pending && installed(versions.pending)) {
    log(`AIOStreams ${label(versions.pending)} (installed by Update) replaces ${label(versions.current)}`);
    versions.previous = versions.current;
    versions.current = versions.pending;
  }
  delete versions.pending;

  const swap = () => {
    [versions.current, versions.previous] = [versions.previous, versions.current];
  };
  if (process.env.NUVIO_AIO_USE_PREVIOUS === '1' && installed(versions.previous)) {
    log(`back to the previous version, ${label(versions.previous)}, as asked`);
    swap();
  } else if (process.env.NUVIO_AIO_LAST_START_FAILED === '1' && versions.current && versions.current !== versions.lastReady
             && installed(versions.previous)) {
    log(`${label(versions.current)} did not start last time: back to ${label(versions.previous)}`);
    swap();
  }

  if (!installed(versions.current)) {
    writeState({ status: 'installing', installing: 'Looking for the newest AIOStreams…' });
    const { tag } = await installer.latestVersion(source);
    log(`installing AIOStreams ${tag || ''} from ${source || installer.DEFAULT_SOURCE}…`);
    const result = await installer.install({
      source,
      tag,
      home,
      shimsDir: path.join(here, 'shims'),
      log,
      onProgress: ({ phase, done, total }) => {
        writeState({
          status: 'installing',
          installing: phase === 'download'
            ? `Downloading AIOStreams ${tag || ''} — ${mb(done)}${total ? ` / ${mb(total)}` : ''} MB`
            : `Preparing AIOStreams ${tag || ''}…`,
        });
      },
    });
    if (installed(versions.current)) versions.previous = versions.current;
    versions.current = result.name;
    versions.labels[result.name] = { tag: result.tag, source: source || installer.DEFAULT_SOURCE, installedAt: new Date().toISOString() };
  }
  installer.cleanUp(home, versions);
  installer.saveVersions(home, versions);

  process.env.AIO_ROOT = path.join(home, versions.current);
  process.env.NUVIO_AIO_CURRENT = versions.current;
  process.env.NUVIO_AIO_VERSION = label(versions.current);
  await import(pathToFileURL(path.join(here, 'nuvio-main.mjs')).href);
} catch (error) {
  reportFailure(error);
}
