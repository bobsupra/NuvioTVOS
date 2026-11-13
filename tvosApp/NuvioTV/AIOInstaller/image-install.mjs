// Installs the original AIOStreams for Nuvio on Apple TV, inside Nuvio's own
// Node.js: from AIOStreams' official Docker image (the default) or from a
// ready package (aio.tar.gz). Only Node's own modules — nothing to install
// first. Used by bootstrap.mjs (first start) and nuvio-main.mjs (Update).
//
// From an image:
// 1. Asks the registry for the image (anonymous token, arm64 variant) and
//    finds the layer with the application: AIOStreams' Dockerfile copies the
//    whole /app in one step (COPY --from=runtime /runtime /app).
// 2. Downloads that layer and unpacks app/ from it. Apple TV does not let apps
//    create symlinks, so they are only noted, never created.
// 3. Lays out node_modules without symlinks, the way npm does (as flatten.py
//    does for the CI build): each package once, other versions nested where
//    Node.js finds them, forwarding packages for AIOStreams' own packages;
//    only what the server needs, nothing of the web frontend's.
// 4. Swaps native addons for the shims.
//
// Each version gets its own folder in the home folder; versions.json there
// says which one is current, the previous one and one waiting for the next
// start (an update).
//
// CLI (tests): node image-install.mjs --source <image or package> --home <dir> --shims <dir> [--tag <tag>]
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { Readable } from 'node:stream';
import { Writable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

export const DEFAULT_SOURCE = 'ghcr.io/viren070/aiostreams';
const COMPLETE = '.nuvio-complete';
const seconds = (since) => `${((Date.now() - since) / 1000).toFixed(1)} s`;
const mb = (bytes) => `${(bytes / 1048576).toFixed(1)} MB`;

// MARK: sources

/** An image (registry/repository[:tag]) or a package (https://…/aio.tar.gz or a file). */
export function parseSource(source) {
  const text = String(source || DEFAULT_SOURCE).trim() || DEFAULT_SOURCE;
  if (/^https?:\/\//i.test(text) && /\.(tar\.gz|tgz)(\?.*)?$/i.test(text)) return { kind: 'package', url: text };
  if (text.startsWith('/') || text.startsWith('file://')) return { kind: 'package', file: text.replace(/^file:\/\//, '') };
  const reference = text.replace(/^(https?|docker):\/\//i, '').replace(/\/+$/, '');
  const slash = reference.indexOf('/');
  const colon = reference.lastIndexOf(':');
  const tag = colon > slash ? reference.slice(colon + 1) : null;
  const name = colon > slash ? reference.slice(0, colon) : reference;
  const first = name.slice(0, name.indexOf('/'));
  const hasRegistry = first.includes('.') || first.includes(':') || first === 'localhost';
  const registry = hasRegistry ? first : 'registry-1.docker.io';
  let repository = hasRegistry ? name.slice(first.length + 1) : name;
  if (!hasRegistry && !repository.includes('/')) repository = `library/${repository}`;
  return { kind: 'image', registry, repository, tag };
}

// MARK: registry

const MANIFESTS = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

function registryClient(image) {
  let token = null;
  async function request(pathname, accept) {
    const url = pathname.startsWith('http') ? pathname : `https://${image.registry}/v2/${image.repository}/${pathname}`;
    for (let attempt = 0; attempt < 2; attempt++) {
      const headers = { 'user-agent': 'Nuvio-AIOStreams' };
      if (accept) headers.accept = accept;
      if (token) headers.authorization = `Bearer ${token}`;
      const response = await fetch(url, { headers, redirect: 'follow' });
      if (response.status === 401 && !token) {
        // Bearer realm="…",service="…",scope="…" — an anonymous pull token.
        const challenge = response.headers.get('www-authenticate') || '';
        const fields = Object.fromEntries([...challenge.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
        if (!fields.realm) throw new Error(`the registry wants a login: ${challenge}`);
        const tokenURL = new URL(fields.realm);
        if (fields.service) tokenURL.searchParams.set('service', fields.service);
        tokenURL.searchParams.set('scope', fields.scope || `repository:${image.repository}:pull`);
        const answer = await fetch(tokenURL);
        if (!answer.ok) throw new Error(`registry token: HTTP ${answer.status}`);
        const body = await answer.json();
        token = body.token || body.access_token;
        continue;
      }
      if (!response.ok) throw new Error(`${image.registry}/${image.repository}: ${pathname.split('?')[0]}: HTTP ${response.status}`);
      return response;
    }
    throw new Error(`${image.registry}/${image.repository}: no access`);
  }
  return { request };
}

const semver = (tag) => {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(tag);
  return match ? match.slice(1).map(Number) : null;
};
const newer = (a, b) => { for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] > b[i]; return false; };

/** The newest release tag of an image (vX.Y.Z, no betas or nightlies). */
async function newestTag(image) {
  const client = registryClient(image);
  let best = null;
  let next = 'tags/list?n=1000';
  for (let page = 0; next && page < 20; page++) {
    const response = await client.request(next);
    const body = await response.json();
    for (const tag of body.tags || []) {
      const version = semver(tag);
      if (version && (!best || newer(version, best.version))) best = { tag, version };
    }
    const link = response.headers.get('link');
    const match = link && /<([^>]+)>;\s*rel="next"/.exec(link);
    next = match ? (match[1].startsWith('http') ? match[1] : new URL(match[1], `https://${image.registry}`).href) : null;
  }
  if (!best) throw new Error(`no release tags in ${image.registry}/${image.repository}`);
  return best.tag;
}

/** The version the source offers now: { tag } (null tag: a package that does not say). */
export async function latestVersion(source) {
  const parsed = parseSource(source);
  if (parsed.kind === 'image') return { tag: parsed.tag || await newestTag(parsed) };
  // A package may have its nuvio-package.json next to it.
  try {
    if (parsed.url) {
      const info = await fetch(parsed.url.replace(/[^/?]+(\?.*)?$/, 'nuvio-package.json'));
      if (info.ok) return { tag: (await info.json()).aiostreams || null };
    } else {
      const info = path.join(path.dirname(parsed.file), 'nuvio-package.json');
      if (fs.existsSync(info)) return { tag: JSON.parse(fs.readFileSync(info, 'utf8')).aiostreams || null };
    }
  } catch {}
  return { tag: null };
}

async function findAppLayer(image, tag, log) {
  const client = registryClient(image);
  let manifest = await (await client.request(`manifests/${tag}`, MANIFESTS)).json();
  if (manifest.manifests) {
    const platforms = manifest.manifests.filter((entry) => entry.platform && entry.platform.os === 'linux');
    const chosen = platforms.find((entry) => entry.platform.architecture === 'arm64')
      || platforms.find((entry) => entry.platform.architecture === 'amd64');
    if (!chosen) throw new Error('no linux variant in the image');
    manifest = await (await client.request(`manifests/${chosen.digest}`, MANIFESTS)).json();
  }
  const config = await (await client.request(`blobs/${manifest.config.digest}`)).json();
  const history = (config.history || []).filter((entry) => !entry.empty_layer);
  const layers = manifest.layers.map((layer, index) => ({ ...layer, index, createdBy: history[index] ? history[index].created_by || '' : '' }));
  // The application: the last layer that copies into /app.
  const app = [...layers].reverse().find((layer) => /COPY\b.*\s\/app\/?(\s|$)/.test(layer.createdBy));
  if (!app) throw new Error('no /app layer in the image history');
  log(`${image.repository}:${tag}: application layer ${mb(app.size)} (of ${layers.length})`);
  return { client, app, digest: manifest.config.digest };
}

// MARK: tar (app/ only; symlinks noted, never created)

class LayerExtractor extends Writable {
  constructor(root, prefix) {
    super();
    this.root = root;
    this.prefix = prefix;
    this.buffer = Buffer.alloc(0);
    this.entry = null;
    this.pax = {};
    this.longName = null;
    this.longLink = null;
    this.links = new Map(); // relative path → link text
    this.files = 0;
    this.bytes = 0;
  }

  static text(block, start, length) {
    const end = block.indexOf(0, start);
    return block.toString('utf8', start, end === -1 || end > start + length ? start + length : end);
  }

  static octal(block, start, length) {
    const text = LayerExtractor.text(block, start, length).trim();
    return text ? parseInt(text, 8) : 0;
  }

  relative(name) {
    let clean = name.replace(/^\.?\//, '');
    if (!clean.startsWith(this.prefix)) return null;
    clean = clean.slice(this.prefix.length).replace(/\/$/, '');
    if (!clean || clean.split('/').includes('..')) return clean ? null : '';
    return clean;
  }

  header(block) {
    if (block.every((byte) => byte === 0)) return;
    let name = LayerExtractor.text(block, 0, 100);
    const size = LayerExtractor.octal(block, 124, 12);
    const mode = LayerExtractor.octal(block, 100, 8) || 0o644;
    const type = String.fromCharCode(block[156] || 48);
    let link = LayerExtractor.text(block, 157, 100);
    const prefix = block.toString('utf8', 257, 263).startsWith('ustar') ? LayerExtractor.text(block, 345, 155) : '';
    if (prefix) name = `${prefix}/${name}`;
    if (this.pax.path) name = this.pax.path;
    if (this.pax.linkpath) link = this.pax.linkpath;
    if (this.longName) name = this.longName;
    if (this.longLink) link = this.longLink;
    const padding = (512 - (size % 512)) % 512;
    if (type === 'x' || type === 'g' || type === 'L' || type === 'K') {
      this.entry = { remaining: size, padding, collect: [], kind: type };
      return;
    }
    this.pax = {};
    this.longName = null;
    this.longLink = null;
    const relative = this.relative(name);
    const base = path.posix.basename(name);
    if (relative === null || base.startsWith('.wh.')) {
      if (size > 0) this.entry = { remaining: size, padding, skip: true };
      return;
    }
    const target = path.join(this.root, relative);
    if (type === '5') {
      fs.mkdirSync(target, { recursive: true });
    } else if (type === '2') {
      this.links.set(relative, link);
    } else if (type === '1') {
      const from = this.relative(link);
      fs.mkdirSync(path.dirname(target), { recursive: true });
      if (from !== null && fs.existsSync(path.join(this.root, from))) fs.copyFileSync(path.join(this.root, from), target);
      this.files++;
    } else if (type === '0' || type === '\0' || type === '7') {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const fd = fs.openSync(target, 'w', mode & 0o777);
      this.files++;
      this.bytes += size;
      if (size === 0) fs.closeSync(fd);
      else {
        this.entry = { remaining: size, padding, fd };
        return;
      }
    }
    if (size > 0) this.entry = { remaining: size, padding, skip: true };
  }

  finishEntry() {
    const entry = this.entry;
    this.entry = null;
    if (entry.fd !== undefined) fs.closeSync(entry.fd);
    if (!entry.collect) return;
    const data = Buffer.concat(entry.collect);
    if (entry.kind === 'L') this.longName = LayerExtractor.text(data, 0, data.length);
    else if (entry.kind === 'K') this.longLink = LayerExtractor.text(data, 0, data.length);
    else if (entry.kind === 'x') {
      let offset = 0;
      while (offset < data.length) {
        const space = data.indexOf(32, offset);
        if (space === -1) break;
        const length = parseInt(data.toString('utf8', offset, space), 10);
        if (!length) break;
        const record = data.toString('utf8', space + 1, offset + length - 1);
        const equals = record.indexOf('=');
        if (equals > 0) this.pax[record.slice(0, equals)] = record.slice(equals + 1);
        offset += length;
      }
    }
  }

  _write(chunk, encoding, callback) {
    try {
      this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : chunk;
      let offset = 0;
      for (;;) {
        if (this.entry) {
          if (this.entry.remaining > 0) {
            const take = Math.min(this.entry.remaining, this.buffer.length - offset);
            if (take === 0) break;
            const piece = this.buffer.subarray(offset, offset + take);
            if (this.entry.fd !== undefined) fs.writeSync(this.entry.fd, piece);
            else if (this.entry.collect) this.entry.collect.push(Buffer.from(piece));
            this.entry.remaining -= take;
            offset += take;
            if (this.entry.remaining > 0) break;
          }
          if (this.buffer.length - offset < this.entry.padding) break;
          offset += this.entry.padding;
          this.finishEntry();
          continue;
        }
        if (this.buffer.length - offset < 512) break;
        this.header(this.buffer.subarray(offset, offset + 512));
        offset += 512;
      }
      this.buffer = Buffer.from(this.buffer.subarray(offset));
      callback();
    } catch (error) {
      callback(error);
    }
  }
}

// MARK: the unpacked tree, with its symlinks as a table

class Tree {
  constructor(root, links) {
    this.root = root;
    this.links = links; // relative path → link text
    this.byFolder = new Map(); // folder → names of links in it
    for (const link of links.keys()) {
      const folder = path.posix.dirname(link);
      if (!this.byFolder.has(folder)) this.byFolder.set(folder, new Set());
      this.byFolder.get(folder).add(path.posix.basename(link));
    }
  }

  // Where a path really is, through the noted symlinks ('' = the root).
  real(relative) {
    let current = relative.split('/').filter(Boolean);
    for (let guard = 0; guard < 64; guard++) {
      let changed = false;
      for (let i = 1; i <= current.length; i++) {
        const prefix = current.slice(0, i).join('/');
        const link = this.links.get(prefix);
        if (link === undefined) continue;
        const base = link.startsWith('/')
          ? link.replace(/^\/app\/?/, '')
          : path.posix.join(path.posix.dirname(prefix), link);
        const resolved = path.posix.normalize(base).split('/').filter((part) => part && part !== '.');
        if (resolved.includes('..')) return null; // outside the application
        current = [...resolved, ...current.slice(i)];
        changed = true;
        break;
      }
      if (!changed) return current.join('/');
    }
    return null;
  }

  exists(relative) {
    const real = this.real(relative);
    return real !== null && fs.existsSync(path.join(this.root, real));
  }

  isDirectory(relative) {
    const real = this.real(relative);
    return real !== null && fs.existsSync(path.join(this.root, real)) && fs.statSync(path.join(this.root, real)).isDirectory();
  }

  names(folder) {
    const names = new Set(this.byFolder.get(folder) || []);
    const real = this.real(folder);
    if (real !== null && fs.existsSync(path.join(this.root, real))) {
      for (const entry of fs.readdirSync(path.join(this.root, real))) names.add(entry);
    }
    return [...names].sort();
  }

  // (name, real path) for each package entry of a node_modules folder.
  entries(folder) {
    const found = [];
    for (const name of this.names(folder)) {
      if (name.startsWith('.')) continue;
      const child = `${folder}/${name}`;
      if (name.startsWith('@') && !this.links.has(child)) {
        for (const inner of this.names(child)) found.push([`${name}/${inner}`, this.real(`${child}/${inner}`)]);
      } else {
        found.push([name, this.real(child)]);
      }
    }
    return found.filter(([, real]) => real !== null && fs.existsSync(path.join(this.root, real)));
  }
}

// MARK: flatten (as flatten.py)

// workspace: real path of each AIOStreams package in the tree → its place in the package.
function flatten(tree, stage, workspace, log) {
  const store = 'node_modules/.pnpm';

  const dependencies = (real) => {
    if (workspace.has(real) || real === '') return tree.entries(real ? `${real}/node_modules` : 'node_modules');
    let container = path.posix.dirname(real);
    if (path.posix.basename(container).startsWith('@')) container = path.posix.dirname(container);
    const own = path.posix.relative(container, real);
    return tree.entries(container).filter(([name]) => name !== own);
  };

  const placements = new Map(); // stage path → real path | { forward: real }
  const queue = [];
  const same = (a, b) => (typeof a === 'string' || typeof b === 'string') ? a === b : a.forward === b.forward;

  const lookup = (location, name) => {
    let folder = location;
    for (;;) {
      if (path.basename(folder) !== 'node_modules') {
        const candidate = path.join(folder, 'node_modules', name);
        if (placements.has(candidate)) return placements.get(candidate);
      }
      if (folder === stage) return null;
      folder = path.dirname(folder);
    }
  };

  const place = (location, real) => {
    for (const [name, target] of dependencies(real)) {
      const wanted = workspace.has(target) ? { forward: target } : target;
      const found = lookup(location, name);
      if (found !== null && same(found, wanted)) continue;
      const spot = found === null ? path.join(stage, 'node_modules', name) : path.join(location, 'node_modules', name);
      if (placements.has(spot)) continue; // the workspace root's own: the server's version stays
      placements.set(spot, wanted);
      if (typeof wanted === 'string') queue.push([spot, wanted]);
    }
  };
  const run = () => { while (queue.length) place(...queue.shift()); };

  // The server first (its versions win the root), then the other packages,
  // then the workspace root, then pnpm's hidden hoisting for undeclared ones.
  const order = [...workspace.keys()].sort((a, b) => (a.endsWith('/server') ? -1 : b.endsWith('/server') ? 1 : a.localeCompare(b)));
  for (const real of order) queue.push([workspace.get(real), real]);
  run();
  queue.push([stage, '']);
  run();
  // Only for packages the server needs: the image's store also holds the web
  // frontend's (an install of the whole project), which must stay out.
  const needed = new Set([...placements.values()].filter((what) => typeof what === 'string'));
  for (const [name, target] of tree.entries(`${store}/node_modules`)) {
    const root = path.join(stage, 'node_modules', name);
    if (!placements.has(root) && !workspace.has(target) && needed.has(target)) {
      placements.set(root, target);
      queue.push([root, target]);
    }
  }
  run();

  // The first place of a package gets it moved there, others a copy.
  let moved = 0;
  let copied = 0;
  let forwards = 0;
  const first = new Map(); // real path → stage path it went to
  const depth = (spot) => spot.split(path.sep).length;
  for (const spot of [...placements.keys()].sort((a, b) => depth(a) - depth(b) || a.localeCompare(b))) {
    const what = placements.get(spot);
    if (typeof what !== 'string') {
      const manifest = JSON.parse(fs.readFileSync(path.join(tree.root, what.forward, 'package.json'), 'utf8'));
      const staged = workspace.get(what.forward);
      let main = manifest.main || 'index.js';
      if (fs.existsSync(path.join(tree.root, what.forward, main)) && fs.statSync(path.join(tree.root, what.forward, main)).isDirectory()) main = path.join(main, 'index.js');
      fs.mkdirSync(spot, { recursive: true });
      let entry = path.relative(spot, path.join(staged, main)).split(path.sep).join('/');
      if (!entry.startsWith('.')) entry = `./${entry}`;
      const module = manifest.type === 'module';
      fs.writeFileSync(path.join(spot, 'package.json'), JSON.stringify({ name: manifest.name, version: manifest.version || '0.0.0', main: 'index.js', ...(module ? { type: 'module' } : {}) }, null, 2));
      fs.writeFileSync(path.join(spot, 'index.js'), module ? `export * from ${JSON.stringify(entry)};\n` : `module.exports = require(${JSON.stringify(entry)});\n`);
      forwards++;
      continue;
    }
    fs.mkdirSync(path.dirname(spot), { recursive: true });
    const placed = first.get(what);
    if (!placed) {
      fs.renameSync(path.join(tree.root, what), spot);
      first.set(what, spot);
      moved++;
    } else {
      const skip = path.join(placed, 'node_modules');
      fs.cpSync(placed, spot, { recursive: true, filter: (source) => source !== skip && !source.startsWith(skip + path.sep) });
      copied++;
    }
  }
  log(`flatten: ${moved} packages, ${copied} extra copies for other versions, ${forwards} forwarding packages`);
}

// Moves a folder into another, merging with what is there already.
function moveInto(source, target) {
  if (!fs.existsSync(target)) {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.renameSync(source, target);
    return;
  }
  if (fs.statSync(source).isDirectory() && fs.statSync(target).isDirectory()) {
    for (const name of fs.readdirSync(source)) moveInto(path.join(source, name), path.join(target, name));
    return;
  }
  fs.rmSync(target, { recursive: true, force: true });
  fs.renameSync(source, target);
}

// MARK: shims and clean-up

// FUSE's package was renamed after v2.37.0 (@viren070 → @aiostreams).
const SHIMS = { 'better-sqlite3': 'better-sqlite3', bcrypt: 'bcrypt', yencode: 'yencode', '@viren070/fsmux-fuse': 'fsmux-fuse', '@aiostreams/fsmux-fuse': 'fsmux-fuse' };

function walk(folder, visit) {
  for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
    const full = path.join(folder, entry.name);
    if (visit(full, entry) !== false && entry.isDirectory()) walk(full, visit);
  }
}

function applyShims(stage, shimsDir, log) {
  walk(stage, (full, entry) => {
    if (!entry.isDirectory()) return true;
    const relative = path.relative(stage, full).split(path.sep).join('/');
    for (const [name, shim] of Object.entries(SHIMS)) {
      if (relative === `node_modules/${name}` || relative.endsWith(`/node_modules/${name}`)) {
        fs.rmSync(full, { recursive: true, force: true });
        fs.cpSync(path.join(shimsDir, shim), full, { recursive: true });
        log(`shim: ${name}`);
        return false;
      }
    }
    return true;
  });
  const native = [];
  walk(stage, (full, entry) => {
    if (entry.isFile() && (entry.name.endsWith('.node') || entry.name.endsWith('.d.ts') || entry.name.endsWith('.map'))) {
      if (entry.name.endsWith('.node')) native.push(path.relative(stage, full));
      fs.rmSync(full);
    }
    return true;
  });
  if (native.length) log(`native addons removed (they cannot load on Apple TV): ${native.length}`);
}

// MARK: versions

export function readVersions(home) {
  try {
    return { labels: {}, ...JSON.parse(fs.readFileSync(path.join(home, 'versions.json'), 'utf8')) };
  } catch {
    return { labels: {} };
  }
}

export function saveVersions(home, versions) {
  fs.mkdirSync(home, { recursive: true });
  fs.writeFileSync(path.join(home, 'versions.json.tmp'), JSON.stringify(versions, null, 2));
  fs.renameSync(path.join(home, 'versions.json.tmp'), path.join(home, 'versions.json'));
}

export function isInstalled(home, name) {
  return Boolean(name) && fs.existsSync(path.join(home, name, COMPLETE));
}

// MARK: install

async function download(body, total, extractor, decompress, onProgress) {
  let done = 0;
  let reported = 0;
  const hash = crypto.createHash('sha256');
  await pipeline(
    body,
    async function* (source) {
      for await (const chunk of source) {
        done += chunk.length;
        hash.update(chunk);
        if (onProgress && Date.now() - reported > 1000) {
          reported = Date.now();
          onProgress({ phase: 'download', done, total });
        }
        yield chunk;
      }
    },
    decompress,
    extractor
  );
  if (onProgress) onProgress({ phase: 'download', done, total: total || done });
  return { bytes: done, sha256: hash.digest('hex') };
}

/**
 * Installs one version from the source into its own folder of `home`
 * (nothing is switched: the caller decides). Returns { name, tag }.
 */
export async function install({ source, tag, home, shimsDir, log = () => {}, onProgress }) {
  const started = Date.now();
  const parsed = parseSource(source);
  fs.mkdirSync(home, { recursive: true });
  const work = path.join(home, `.install-${process.pid}-${Date.now()}`);
  fs.rmSync(work, { recursive: true, force: true });
  const stage = path.join(work, 'package');
  try {
    let name;
    let info;
    if (parsed.kind === 'image') {
      if (!tag) throw new Error('no version to install');
      const { client, app, digest } = await findAppLayer(parsed, tag, log);
      name = `${tag}-${digest.replace(/^sha256:/, '').slice(0, 8)}`.replace(/[^\w.-]/g, '_');
      if (isInstalled(home, name)) {
        log(`${tag} is installed already`);
        return { name, tag };
      }
      const unpacked = path.join(work, 'app');
      fs.mkdirSync(unpacked, { recursive: true });
      const response = await client.request(`blobs/${app.digest}`);
      const extractor = new LayerExtractor(unpacked, 'app/');
      const decompress = /zstd/.test(app.mediaType || '') ? zlib.createZstdDecompress() : zlib.createGunzip();
      const fetched = await download(Readable.fromWeb(response.body), app.size, extractor, decompress, onProgress);
      log(`downloaded ${mb(fetched.bytes)}, ${extractor.files} files, ${extractor.links.size} symlinks noted, in ${seconds(started)}`);
      if (onProgress) onProgress({ phase: 'prepare' });
      const prepared = Date.now();
      const tree = new Tree(unpacked, extractor.links);
      fs.mkdirSync(stage, { recursive: true });
      const workspace = new Map();
      for (const entry of tree.names('packages')) {
        if (fs.existsSync(path.join(unpacked, 'packages', entry, 'package.json'))) workspace.set(`packages/${entry}`, path.join(stage, 'packages', entry));
      }
      flatten(tree, stage, workspace, log);
      fs.rmSync(path.join(unpacked, 'node_modules'), { recursive: true, force: true });
      for (const entry of fs.readdirSync(path.join(unpacked, 'packages'))) {
        fs.rmSync(path.join(unpacked, 'packages', entry, 'node_modules'), { recursive: true, force: true });
      }
      for (const entry of fs.readdirSync(unpacked)) moveInto(path.join(unpacked, entry), path.join(stage, entry));
      applyShims(stage, shimsDir, log);
      info = { aiostreams: tag, source: `${parsed.registry}/${parsed.repository}:${tag}`, image: digest };
      log(`prepared in ${seconds(prepared)}`);
    } else {
      // A ready package (no symlinks, shims in): only unpacked.
      fs.mkdirSync(stage, { recursive: true });
      const extractor = new LayerExtractor(stage, '');
      let body;
      let total = 0;
      if (parsed.url) {
        const response = await fetch(parsed.url, { headers: { 'user-agent': 'Nuvio-AIOStreams' } });
        if (!response.ok) throw new Error(`${parsed.url}: HTTP ${response.status}`);
        total = Number(response.headers.get('content-length') || 0);
        body = Readable.fromWeb(response.body);
      } else {
        total = fs.statSync(parsed.file).size;
        body = fs.createReadStream(parsed.file);
      }
      const fetched = await download(body, total, extractor, zlib.createGunzip(), onProgress);
      if (extractor.links.size) log(`${extractor.links.size} symlinks in the package were left out`);
      let own = {};
      try { own = JSON.parse(fs.readFileSync(path.join(stage, 'nuvio-package.json'), 'utf8')); } catch {}
      tag = own.aiostreams || tag || 'package';
      name = `${tag}-${fetched.sha256.slice(0, 8)}`.replace(/[^\w.-]/g, '_');
      info = { ...own, aiostreams: tag, source: parsed.url || parsed.file, sha256: fetched.sha256 };
      if (isInstalled(home, name)) {
        log(`${tag} is installed already`);
        return { name, tag };
      }
    }
    fs.writeFileSync(path.join(stage, 'nuvio-package.json'), JSON.stringify({ ...info, installed: new Date().toISOString() }));
    fs.writeFileSync(path.join(stage, COMPLETE), new Date().toISOString());
    fs.rmSync(path.join(home, name), { recursive: true, force: true });
    fs.renameSync(stage, path.join(home, name));
    log(`AIOStreams ${tag} installed in ${seconds(started)}`);
    return { name, tag };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

/** Removes version folders that versions.json no longer names, and unfinished installs. */
export function cleanUp(home, versions) {
  const keep = new Set([versions.current, versions.previous, versions.pending].filter(Boolean));
  for (const entry of fs.readdirSync(home)) {
    if (entry === 'versions.json' || keep.has(entry)) continue;
    if (entry.startsWith('.install-') || fs.statSync(path.join(home, entry)).isDirectory()) {
      fs.rmSync(path.join(home, entry), { recursive: true, force: true });
    }
  }
  for (const name of Object.keys(versions.labels || {})) if (!keep.has(name)) delete versions.labels[name];
}

// MARK: CLI (tests)

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const options = {};
  for (let i = 2; i < process.argv.length; i += 2) options[process.argv[i].replace(/^--/, '')] = process.argv[i + 1];
  const log = (text) => console.log(`[install] ${text}`);
  const tag = options.tag || (await latestVersion(options.source)).tag;
  const result = await install({ source: options.source, tag, home: options.home, shimsDir: options.shims, log });
  console.log(JSON.stringify(result));
}
