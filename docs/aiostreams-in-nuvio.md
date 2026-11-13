# AIOStreams inside Nuvio on Apple TV

This document explains how the original AIOStreams runs inside Nuvio on Apple TV. It covers how AIOStreams gets installed and updated, how it starts, and how Nuvio uses it. It also covers what happens when Nuvio comes back from the Home screen, the preparation for ffprobe, and the optional bridge that makes Nuvio's JS plugins visible to AIOStreams.

| | |
|---|---|
| Code | `tvosApp/NuvioTV/Sources/Core/AIO/` (Nuvio's side), `tvosApp/NuvioTV/AIOInstaller/` (what Node runs), `Vendor/NodeMobile` (Node.js for tvOS) |
| Tested on | Apple TV 4K (AppleTV14,1), tvOS 27, sideloaded as a separate test app, on tvOS Beta 3.5.0 and 3.5.1 |

---

## 1. In short

- The **original, unmodified AIOStreams** runs inside the Nuvio app, in **Node.js 24** that Nuvio carries as a framework. The framework is nodejs-mobile, built for tvOS.
- **Nuvio does not ship AIOStreams.** On the first start, Nuvio downloads AIOStreams' **official Docker image** (`ghcr.io/viren070/aiostreams`, arm64) straight from the registry on the Apple TV and installs the application from it.
  - **Updates** happen only when the user presses a button. The new version takes over at the next start of Nuvio.
  - The **previous version is kept**. Nuvio goes back to it automatically when a new version never gets ready.
- The user configures AIOStreams with **AIOStreams' own configuration page**, opened in a browser on a computer at `http://<Apple TV IP>:8767/stremio/configure`.
  - Nuvio notices when a configuration is saved and adds the AIOStreams addon by itself. Nothing needs copying.
  - The addon exists only on this Apple TV. Nuvio never syncs it to the account, because its address works only on this device.
  - With *Save to Nuvio Account* (off by default), Nuvio's settings for AIOStreams and the configuration go into the account instead. Another Apple TV then builds the same configuration in its own AIOStreams (section 7).
- AIOStreams then behaves like any other addon: **streams, catalogs, metadata and subtitles**. Everything AIOStreams can reach from the Apple TV works, including debrid, Torrentio, Comet, its built-in scrapers and Usenet. Usenet streams play through Nuvio's own NNTP player (Stremio `nzbUrl` + `servers`).
- On the Apple TV 4K, the start sheet showed these times, counted from when Nuvio started Node.js:

  > Node.js started 0.2 s · AIOStreams loaded 2.1 s · answering 2.1 s · Nuvio saw it 2.2 s · warm-up: 21 streams in 0.3 s

---

## 2. What is where

| Path | What it is |
|---|---|
| `aio-node/node-tvos/tvos_patch.py` | Turns nodejs-mobile (iOS) into a tvOS build |
| `.github/workflows/build-node-tvos.yml` | Builds `NodeMobile.xcframework` (tvOS arm64 + simulator arm64) and publishes it as a release (`node-tvos-<tag>`) |
| `Vendor/NodeMobile/Package.swift` | The `NodeMobile` package: that release's zip, by URL and checksum (as MPVKit's frameworks) |
| `tvosApp/NuvioTV/AIOInstaller/` | What the app carries, as a folder in the bundle (about 260 KB) |
| ├ `bootstrap.mjs` | Node's entry point. Picks the AIOStreams version, installs one if there is none, then starts `nuvio-main.mjs` |
| ├ `image-install.mjs` | Installs AIOStreams from the official image (or from a package) |
| ├ `nuvio-main.mjs` | Starts AIOStreams. Also runs the configuration-page proxy, Nuvio's control port, the start-up speed-ups, the wake-up handling and the plugins card |
| ├ `ffprobe-bridge.mjs` | ffprobe through Nuvio: prepared on the Node side only (section 11; `aio-node/FFPROBE.md`) |
| └ `shims/` | Stand-ins for native addons that can't load on tvOS (section 5) |
| `tvosApp/NuvioTV/Sources/Core/AIO/AIOStreamsHost.swift` | Everything on Nuvio's side: start, state, addon, backup/restore, warm-up, wake-up, log |
| `Settings → Integrations → AIOStreams` | The card under *Plugins*. It opens the AIOStreams sheet (section 14) |
| `StreamsRepository.swift`, `CatalogRepository.swift` | Where the AIOStreams addon joins stream searches and the addon list |
| `tvosApp/NuvioTVTests/AIOStreamsHostTests.swift` | Simulator test that really starts AIOStreams inside the app (only with `AIO_TESTS=1`: it downloads the official image) |

---

## 3. Layout at run time

```
┌──────────────────────────── Nuvio app (one process) ────────────────────────────┐
│                                                                                  │
│  Swift: AIOStreamsHost ──env vars──▶ thread "Node.js (AIOStreams)": node_start()  │
│     ▲   reads state file (0.25 s while starting, then 5 s)                       │
│     │                                                                            │
│     │                bootstrap.mjs ─▶ image-install.mjs (first start / Update)   │
│     │                      └─▶ nuvio-main.mjs ─▶ AIOStreams (packages/server)    │
│     │                                                                            │
│  127.0.0.1:8770  AIOStreams itself ............ Nuvio's requests (addon, health) │
│  0.0.0.0:8767    proxy → 8770 ................. configuration page for the LAN   │
│  127.0.0.1:8771  Nuvio's control port (token) . versions, update, activity       │
│  127.0.0.1:8766  Nuvio's plugin server (Swift)  plugins as add-ons for AIOStreams│
└──────────────────────────────────────────────────────────────────────────────────┘
```

| Port | Bound to | Served by | For |
|---|---|---|---|
| 8770 | 127.0.0.1 only | AIOStreams | Nuvio's addon requests. `nuvio-main.mjs` patches `net.Server.prototype.listen`, so AIOStreams' own `app.listen(PORT)` binds to loopback only. |
| 8767 | 0.0.0.0 | `nuvio-main.mjs` proxy | The configuration page from a computer. It forwards everything, including WebSocket upgrades. |
| 8771 | 127.0.0.1 only | `nuvio-main.mjs` | Nuvio's control port: `GET /versions`, `POST /check`, `POST\|GET /update`, `GET /activity`. Needs an `x-nuvio-token` header that is random per run. |
| 8766 | 127.0.0.1 only | Swift (`PluginLoopbackServer`) | `/<token>/stremio/…`: plugins for AIOStreams (section 12) |

| Data | Where | Why there |
|---|---|---|
| AIOStreams versions (`versions.json` + one folder per version) | `Caches/AIOStreams-versions` | Can be downloaded again |
| AIOStreams' database (`db.sqlite`), `nuvio-state.json`, `nuvio-wake` | `Application Support/AIOStreams` (falls back to Caches) | |
| Disk cache, Node compile cache | `Caches/AIOStreams-cache`, `Caches/AIOStreams-compile-cache` | |
| The configuration backup (uuid, password, config) | **Keychain** (service `nuvio.aio.experiment`) | tvOS may clear Caches. User defaults are used only in unsigned simulator tests. |
| Log | `Caches/AIOStreams-logs/run.log` | stdout and stderr go straight there |

Environment Nuvio passes to Node: `PORT`, `NUVIO_LAN_PORT`, `BASE_URL` (the TV's LAN address on port 8767), `DATABASE_URI` (sqlite), `DISK_CACHE_DIR`, `SECRET_KEY` (random once, kept), `LOG_LEVEL` (`warn`, or `info` with *Detailed AIOStreams log*), `ANIME_DB_LEVEL_OF_DETAIL=required`, `TMDB_API_KEY` (Nuvio's own key, for AIOStreams' title and year matching), `NODE_COMPILE_CACHE`, `UV_THREADPOOL_SIZE=4`, `NUVIO_EMBEDDED=1`, `NUVIO_T0_MS`, `NUVIO_STATE_FILE`, `NUVIO_BACKUP_FILE`, `NUVIO_WAKE_FILE`, `NUVIO_AIO_HOME`, `NUVIO_AIO_SOURCE`, `NUVIO_AIO_USE_PREVIOUS`, `NUVIO_AIO_LAST_START_FAILED`, `NUVIO_CONTROL_PORT`, `NUVIO_CONTROL_TOKEN`, and `DISABLE_RATE_LIMITS=true`. For the plugins (section 12) also `NUVIO_PLUGINS_URL`. Later (ffprobe) `NUVIO_FFPROBE_URL`.

`DISABLE_RATE_LIMITS=true` switches off all of AIOStreams' rate limits (from the next start). Everything Nuvio asks comes from 127.0.0.1, so AIOStreams counts the whole of Nuvio as one address: 15 metadata requests or 30 catalogs in 5 s, 10 stream requests in 15 s. A busy search ("Frieren") answered `rate limit exceeded` on one of its results. AIOStreams' limit on wrong passwords stays.

---

## 4. Node.js for tvOS

- **nodejs-mobile `v24.20.0-0`**, patched by `tvos_patch.py`. tvOS belongs to the iOS family, so most of nodejs-mobile's iOS patches apply as they are. The patch changes:
  - the SDKs (`appletvos` / `appletvsimulator`) and the minimum-version flags (tvOS 18.0);
  - Node's `process.execve()`, which gets a guard: tvOS forbids `fork`/`exec*` outright, and libuv already returns `ENOSYS` from `uv_spawn`;
  - the framework project (device family 3, tvOS deployment target).
- The CI workflow `build-node-tvos.yml` builds both slices with ccache, which takes hours. The IPA workflow takes `NodeMobile.xcframework` from the latest successful run of that workflow.
- Nuvio starts Node with `node_start(argc, argv)` on its own thread with a 16 MB stack. **Node can be started once per app process.** There is no "restart AIOStreams"; restarting Nuvio does it.
- **What Apple TV does not allow, and how it is handled:**
  - **No JIT.** V8 runs jitless, so JavaScript is slower, the first search after a start especially.
  - **WebAssembly is emulated in JavaScript**, which matters because undici's HTTP parser (`fetch`) is WebAssembly. It works; it is slower.
  - **No child processes**, so there is no ffprobe (section 11).
  - **No native addons**, so the shims stand in (section 5).
  - **No symlinks** in the app container. The installer lays `node_modules` out without them.
  - **`process.exit()`** would close Nuvio. With `NUVIO_EMBEDDED=1`, `nuvio-main.mjs` turns it into a "stopped" state instead.
  - An uncaught exception would end Node and Nuvio with it. Both bootstrap and main catch and log.
- *Test Node.js only* in the sheet runs a short self-test instead of AIOStreams: memory, WebAssembly, crypto, zlib, files, `node:sqlite`, HTTP server, `fetch` over HTTPS and a CPU loop.

---

## 5. Installation and updates

### Versions (`bootstrap.mjs`)

`Caches/AIOStreams-versions/versions.json` keeps track of these:

- `current`: the version to start;
- `previous`: kept for rolling back;
- `pending`: installed by *Update*, becomes `current` at the next start;
- `lastReady`: the last version that got as far as answering;
- labels: tag, source and date for each version.

At every start, before AIOStreams loads:

1. A `pending` version becomes `current`, and the old current becomes `previous`.
2. Nuvio goes back to `previous` in two cases:
   - the user chose *Use the previous version*;
   - **automatically**, when the last start never got ready (Nuvio records whether each start finished) and the current version has never been ready.
3. With no version installed, the newest one is installed from the source. The sheet shows progress as "Downloading AIOStreams vX — n / m MB" and then "Preparing…".
4. Old version folders are deleted; only current, previous and pending stay.
5. `nuvio-main.mjs` starts the chosen version.

If the last start did not finish, *Start with Nuvio* does not start AIOStreams automatically the next time. A crashing version can't crash every launch; the sheet says so and lets the user start it by hand.

### Installing from the official image (`image-install.mjs`)

It uses only Node's own modules; nothing is installed first.

1. **Registry.** Asks the registry for an anonymous pull token, reads the image index, picks the arm64 manifest, and finds the layer with the application. AIOStreams' Dockerfile copies `/app` in a single step, so that layer is the whole application.
2. **Version.** Without an explicit tag, takes the newest **release** tag (`vX.Y.Z`; no betas or nightlies). The source setting can name any tag instead, e.g. `ghcr.io/viren070/aiostreams:nightly`.
3. **Download.** Streams the layer through gunzip and a small tar reader that unpacks only `app/`. Symlinks are noted, never created.
4. **Layout.** Lays out `node_modules` the way npm does, without symlinks: each package once, other versions nested where Node finds them, forwarding packages for AIOStreams' own workspace packages. It keeps only what the server needs; the web frontend's dependencies are dropped (the frontend itself comes prebuilt).
5. **Shims.** Swaps in the shims for native addons:

| Package | On Apple TV |
|---|---|
| `better-sqlite3` | Wrapper around Node 24's built-in **`node:sqlite`**, covering everything AIOStreams' SQLite driver uses |
| `bcrypt` | **bcryptjs** (MIT, vendored in the shim) |
| `@viren070/fsmux-fuse`, `@aiostreams/fsmux-fuse` | "FUSE unavailable": AIOStreams' probe reports it and skips the mount |
| `yencode` | Throws "not available". AIOStreams' own Usenet engine is not used, because Nuvio Usenet plays Usenet streams natively |

6. **Done.** Writes a `.nuvio-complete` marker. A half-finished download never counts as installed.

**Other sources:**
- another image or tag;
- an `https://…/aio.tar.gz` package, optionally with a `nuvio-package.json` next to it that names the version;
- a local file.

*Restore the default source* goes back to the official image.

### Update

- *Check for updates* sends `POST /check` to the control port and compares the newest tag with the current one.
- *Update AIOStreams* sends `POST /update`. The new version installs into **its own folder while the current one keeps running**, and it starts with the next start of Nuvio.
- There is deliberately **no automatic update**. If a new AIOStreams version breaks something in Nuvio, users stay on the version they have until Nuvio is adapted.

### Licences

AIOStreams is AGPL-3.0. Nuvio neither ships nor modifies it: the unmodified official image is downloaded on the device. The app carries only the installer, the shims (own code plus bcryptjs, MIT) and nodejs-mobile (Node.js licence). This is worth a proper look before anything goes public; it is not legal advice.

---

## 6. The start, and making it quick

### Nuvio's side (`AIOStreamsHost.start()`)

1. Sets the environment, writes `NUVIO_T0_MS`, publishes the addon as "coming" (`pendingAddonURL`) and calls `node_start` on its thread.
2. Reads the state file every 0.25 s while AIOStreams starts, then every 5 s. The phases are starting / running / not answering / exited / unavailable.
3. **Searches during the start wait for AIOStreams.** `StreamsRepository` shows an "AIOStreams" group as loading and waits up to 20 s for the addon (`waitForAddon`) instead of leaving it out. The search goes out the moment AIOStreams answers.
4. **Configuration check** once AIOStreams runs: does AIOStreams still have the remembered configuration (`HEAD /api/v1/user?uuid=`)?
   - If it does not (tvOS cleared Caches), Nuvio **restores it from the Keychain backup**: a new configuration with the same settings and password via `POST /api/v1/user`. It then switches the addon to the new address.
   - If there is no backup, the sheet asks the user to load the configuration on the page again.
5. **Warm-up.** One stream request for The Matrix (`tt0133093`) with `x-nuvio-warmup: 1` goes through all of AIOStreams (addons, debrid, filters) and opens the connections, so the first real search is not the slow one.
   - It happens after each start, and after more than 60 s on the Home screen.
   - It is skipped when a real search came first; the control port's `/activity` tells. A warm-up next to a real search would only slow that search down.

### Node's side (`nuvio-main.mjs`)

1. Restricts `listen` to loopback for AIOStreams, then starts the configuration-page proxy and the control port.
2. **Holds AIOStreams' data refreshes until it answers.** AIOStreams normally refreshes its anime databases, datasets and remote templates *before* it listens.
   - `nuvio-main.mjs` imports `@aiostreams/core` first and wraps `TaskManager.runNow`, so tasks of the categories `data-sync` and `templates` report success at once. AIOStreams works with what it has on disk; a dataset it has never downloaded comes with the refresh.
   - Once AIOStreams has answered for 10 s and has been quiet for 3 s (60 s at most), the held refreshes run exactly as AIOStreams would have run them.
   - Together with the warm-up and searches waiting for the start, this brought the first streams after a restart from about 5 s down to about 2 s, when AIOStreams answers.
3. Imports `packages/server/dist/server.js` and waits until `/api/v1/health` answers.
4. Writes the start times to the state file and the log, e.g.:

   `[nuvio] start (answering), seconds after Nuvio started Node.js: Node.js 0.04 · installer done 0.1 · AIOStreams core loaded 1.15 · AIOStreams loaded 1.41 · listening 1.47 · answering 1.49 · 9 data refreshes held until after the start`

   The sheet shows Nuvio's view of the same start ("Nuvio saw it 2.2 s"), and the times of the first real search.

---

## 7. Configuration page, addon, catalogs

- The **proxy on 8767** forwards everything to AIOStreams. It also reads the configuration page's user API:
  - creating a configuration (`POST /api/v1/user`);
  - loading one with uuid and password (`POST /api/v1/user/session`, then `GET` with Basic auth);
  - saving changes (`PUT`).
- From those requests Nuvio gets:
  - **the addon address**, written to the state file: `http://127.0.0.1:8770/stremio/<uuid>/<encryptedPassword>/manifest.json`;
  - **a backup** (uuid, password, config), written to the backup file. Swift moves it into the Keychain at once and deletes the file.
- The addon joins the addon list **on this Apple TV only** (`CatalogRepository`: installed + plugins + `AIOStreamsHost.aioAddonURLs(besides:)`). It is never pushed to the account.
  - If the same configuration was also added by hand (its LAN address), it is listed only once.
  - *Use the AIOStreams Addon* turns it on and off.
  - When the addon appears, changes or goes away, Home loads its catalogs again (`addonChangedNotification`), because AIOStreams starts after Nuvio.
- The sheet shows the page address as text and as a QR code.

### In the Nuvio account (*Save to Nuvio Account*)

A switch in the AIOStreams sheet, off by default, that works like Usenet's servers (`AIOSettingsSync.swift`, the feature `tvos_aio_settings` in the profile's `tv` settings blob).

- **What goes in:**
  - Nuvio's settings for AIOStreams: *Start with Nuvio*, *Use the AIOStreams Addon*, *Anime searches*, *Source*, *Detailed AIOStreams log*;
  - the configuration backup: the config and its password, with the time the page saved it (`savedAt`).

  They are stored as they are, without encryption, like Usenet's passwords and debrid keys.
- **What stays on each Apple TV:** the addon address (each Apple TV runs its own AIOStreams on 127.0.0.1), the configuration's uuid, the installed version, the anime databases, `db.sqlite` and the cache.
- **Another Apple TV, or a reinstall,** pulling a profile that has the switch on:
  - gets the settings at once; with *Start with Nuvio*, AIOStreams starts right away;
  - gets the configuration as soon as its AIOStreams answers. Nuvio creates it there (`POST /api/v1/user` with the config and the password), and the addon is added.
- **Changes** saved on the configuration page reach the account. The new backup bumps a revision that the account sync watches, and the other Apple TVs pick the change up on their next pull.
  - The backup saved last wins (`savedAt`). An Apple TV that hasn't pulled yet doesn't overwrite a newer one.
  - With the same password, the changes go into the configuration that is already there (`PUT` with Basic auth), so its addon keeps its address.
  - With another password, a new configuration is created, and its addon takes the old one's place.
- **Off** writes only the choice. The copy is removed from the account for every Apple TV, and their own settings and configurations stay as they are. An Apple TV where the switch was never touched leaves the account's copy alone.
- **No loop.** Nuvio's own requests go to 8770 directly, not through the page's proxy, so loading a configuration from the account never writes a new backup.
- **Tested** with unit tests (`AIOSettingsSyncTests`): the choice, export, import, the newer backup wins, the same password.

---

## 8. Anime (with the AniList integration)

With the AniList integration, an anime title can have an `anilist:` id. AIOStreams passes such an id only to its addons that list the `anilist` prefix; it does not convert it for the others. The setting **Anime searches** chooses what AIOStreams is asked with:

| Option | Request | Who answers |
|---|---|---|
| AniList ID | `anilist:…` | Only AIOStreams' addons that take AniList ids |
| Converted ID | IMDb or Kitsu id (Nuvio converts) | Every addon except the AniList-only ones |
| **Both** (default) | Both at once, results merged (duplicates by URL, hash + file index, or file + size) | All of them |

Asking twice costs nothing the user notices: nothing is playing at that moment.

---

## 9. Coming back from the Home screen

**What happened.** After Nuvio had been on the Home screen and came back, AIOStreams still ran but no streams came, and the configuration page did not open either. Only restarting the app helped, until the next minimise. The log showed `manifest fetch failed origin=http://127.0.0.1:8770` and `NSURLErrorDomain -1004` (cannot connect).

**Why.** When tvOS suspends an app, it **takes away the app's listening sockets**, even after only a few seconds on the Home screen. Node's servers are not told: they still think they listen, but every connection is refused. Nothing in Node fails, so nothing notices. All three ports go: AIOStreams, the configuration page and the control port.

**How it was solved, step by step** (each step tested on the Apple TV):

1. **First try: detect the sleep.** A 2 s timer in Node noticed when it had been frozen for more than 6 s and then listened again on all three ports. It did not help: in the logs Nuvio had been away only 4 s, and the ports were gone already.
2. **Second try: a port check every second.** Node connected to its own port (127.0.0.1:8770, closed at once) every second; when the connection was refused, all three servers listened again. That worked, but it ran all the time.
3. **Final:**
   - **Nuvio wakes Node up.** Nuvio can't tell Node through a port, because the ports are what is gone. So on every return from the Home screen (`UIApplicationWillEnterForeground`, with AIOStreams running), Nuvio writes a few bytes to `NUVIO_WAKE_FILE`. Node watches that file with `fs.watch` (kqueue), which is an event, not polling. On the event, Node checks its port and, if the connection is refused, listens again.
   - **Node also notices on its own** that it was frozen: its 1 s timer sees a gap larger than 2.5 s, and that triggers the same check. On the Apple TV this usually fires first, and the file write is the second way in.
   - **Re-listening:** `server.closeIdleConnections()`, `server.close()`, then `listen` again with the original `listen` on the next tick, up to 10 tries 0.5 s apart on errors. The servers keep their request handlers. For 3 s afterwards no new check runs.
   - **Nuvio waits for it.** Right after coming back, requests to the AIOStreams addon wait until AIOStreams answers again, at most 8 s: the manifest, the streams and the subtitles (`AIOStreamsHost.waitWhileWaking(for:)`). A search started immediately is slightly later instead of failing.
   - **Log lines:**

     ```
     [nuvio] back after 5 s asleep: the ports were gone, listening again (AIOStreams, configuration page, Nuvio's port)
     [nuvio] back after 6 s on the Home screen: AIOStreams answers (0.0 s after coming back)
     ```

     The first wake-up source reads "Nuvio is back from the Home screen" instead of "back after N s asleep".
   - **Data refreshes after waking.** A refresh that became due while Nuvio was suspended would run at the moment of waking, when the network connections are still dead. The log showed `fetch failed`, `refresh-manami … All retries exhausted`, and `anime-database: failed to fetch remote etag → triggering download`, which is a full download of a file that hadn't changed. After a wake-up, refreshes of the kinds `data-sync` and `templates` therefore wait about a minute, and longer while a search is running, then run as AIOStreams would have run them.
   - **Fallback.** If `fs.watch` can't be used, Node says so in the log and checks the port every second, as in step 2. A separate 30 s safety check existed while testing; the logs showed it never had anything to do, and it was removed.
   - **Plugins.** Nuvio also checks its plugin server (8766) after coming back, and restarts it when it doesn't answer.
4. **Tested**:
   - on the Apple TV, several returns from the Home screen: every time the ports were gone, AIOStreams listened again and answered **0.0 s after coming back**, and streams were there;
   - in CI with the real AIOStreams, where `drop-ports.py` shuts the listening sockets down from outside, as tvOS does: AIOStreams answered again **14–19 ms** after the wake file was written.

---

## 10. Log and diagnostics

- Everything Node prints goes **straight to a file** (`dup2` of stdout and stderr), so what was written survives a crash.
- A crash leaves a note with the native stack (signal handlers plus `atexit`). The next run shows **Last run**: how the previous one ended. On an Apple TV there is no other way to see a crash without a Mac.
- `[nuvio]` lines come from `nuvio-main.mjs`, `bootstrap.mjs` and Swift: the start, its times, versions, configuration, warm-up, wake-ups, restore and update.
- *Detailed AIOStreams log* sets AIOStreams' `LOG_LEVEL=info` (every request) instead of `warn`. Every log line costs work on the TV.
- The sheet shows memory and memory warnings. In CI (Linux, jitless), AIOStreams used about 200 MB right after the start, ~290 MB after the first searches and ~400 MB while it downloaded its anime databases. The Apple TV adds its own overhead.

---

## 11. ffprobe: prepared, Nuvio's side not written

AIOStreams reads the tracks of a file the first time it is played (codecs, languages, HDR / Dolby Vision, chapters) with **ffprobe**, a program it runs. Apple TV can't run programs, so inside Nuvio AIOStreams leaves this out.

`ffprobe-bridge.mjs` prepares the way round:

- When Nuvio passes `NUVIO_FFPROBE_URL`, AIOStreams' ffprobe path becomes `nuvio-ffprobe`.
- `child_process.execFile` is patched (with `syncBuiltinESMExports`), so every ffprobe run becomes a JSON `POST` to that address.
- Nuvio would answer from its own player's probe (`AetherEngine.probe(url:)`, FFmpeg).
- Without the variable nothing changes. When nobody answers, AIOStreams gets `ENOENT`, the same as "no ffprobe".

The contract is in `aio-node/FFPROBE.md`: three requests (version; format, streams and chapters; a few video frames for HDR10+) and exactly the fields AIOStreams reads. The bridge was checked against AIOStreams' own ffprobe code, with a stand-in that answers using the real ffprobe.

---

## 12. Nuvio's JS plugins through AIOStreams

**Idea:** a plugin can be put into AIOStreams' list next to the other addons, so AIOStreams sorts, filters and formats its results like everything else. Then it is shown **only there**, not twice.

- **Per plugin:** the plugin's settings get a *Through AIOStreams* switch, off by default.
- **In AIOStreams:** add the **"Nuvio plugins"** card on the configuration page once. It is a preset that `nuvio-main.mjs` adds to AIOStreams' `PresetManager` at start-up (`fromId` and `getPresetList` wrapped), so AIOStreams' files stay unchanged and the card survives updates.
  - The card fetches `plugins.json` from Nuvio's plugin server (cached for 5 s) and makes **one addon per plugin**, with the plugin's name.
  - It has the usual add-on options (timeout, default 20 s; resources; media types; pin; library; passthrough), the same for each plugin.
- **Nuvio's side** (`PluginAIOBridge.swift`) is served on the plugin server, `http://127.0.0.1:8766/<token>/stremio/`:
  - `plugins.json`: the plugins set *Through AIOStreams* (key, name, resources);
  - `p/<key>/manifest.json`: a Stremio manifest with streams and subtitles (for `tt`/`tmdb:` ids or the plugin's own prefixes), plus its catalogs and metadata;
  - `p/<key>/<resource>/<type>/<id>.json`:
    - **streams:** `getStreams` runs to the end (no progressive results), with TMDB ids resolved as usual. Headers become `behaviorHints.proxyHeaders`, and links resolved on play keep pointing at the plugin server.
    - **subtitles:** `getSubtitles`;
    - **catalogs and metadata:** as the plugin's virtual add-on already answers them.
- **Hiding:** once AIOStreams has asked for the plugins (its configuration has the card), and while AIOStreams runs with its addon on, Nuvio leaves those plugins' own stream groups, subtitles, catalogs and metadata out. **Ratings stay in Nuvio**, because AIOStreams has none.
  - Without AIOStreams, or with the switch off, the plugin is shown directly again.
- **Off means off:** the main plugins switch now stops the plugin server and keeps no plugin JS contexts; the card then gives no add-ons.
- **Tested:**
  - unit tests (manifest, stream objects, the ratings-only manifest, routes);
  - a smoke test on Linux with the real AIOStreams (section 15): the card is on the configuration page, and a stand-in plugin's stream comes through AIOStreams' stream answer.

---

## 13. What doesn't work, or works differently

| | |
|---|---|
| AIOStreams' own Usenet engine (yEnc, FUSE mounts) | Off. AIOStreams' Usenet results that come as `nzbUrl` + `servers` (Stremio NNTP) play through Nuvio Usenet |
| ffprobe | Not until Nuvio answers the bridge (section 11) |
| Anything needing child processes or native addons | Not on tvOS; shims cover what AIOStreams needs to start and serve |
| Speed | JIT-less V8 and emulated WebAssembly. The start is about 2 s on the Apple TV 4K; the first search after a start is the slowest (hence the warm-up) |
| Stop or restart AIOStreams | Node starts once per app run: restart Nuvio |
| Configuration storage | AIOStreams' database lives in the app container. tvOS may clear Caches; the configuration comes back from the Keychain backup |
| The addon on other devices | Never synced: `127.0.0.1` exists only on this Apple TV. With *Save to Nuvio Account* the configuration is synced, and each Apple TV makes its own addon from it (section 7) |
| AIOStreams' rate limits | Off (`DISABLE_RATE_LIMITS=true`): everything comes from 127.0.0.1 (section 3) |

---

## 14. Settings (the sheet)

*Settings → Integrations → AIOStreams → Manage.* The card sits under *Plugins* and shows the state and the version.

| Item | |
|---|---|
| Status + configuration page | State, start times, memory, the page address and a QR code |
| Start AIOStreams / Test Node.js only | Start now / the Node self-test |
| Start with Nuvio | Run AIOStreams whenever Nuvio runs |
| Check for updates / Update AIOStreams | Newest release vs current / install it for the next start |
| Use the previous version | Back to the previous version from the next start |
| Source / Restore the default source | Official image, another image or tag, or a package URL |
| Detailed AIOStreams log | Every request in the log (from the next start) |
| Use the AIOStreams Addon | The addon on or off (on this Apple TV only) |
| Save to Nuvio Account | These settings and the configuration, with its password, in this profile of the Nuvio account (section 7) |
| Anime searches | AniList ID / Converted ID / Both (section 8) |
| Last run, Log | How the previous run ended; the live log |

---

## 15. Tests

| | |
|---|---|
| `AIOStreamsHostTests` | On the tvOS simulator, inside the app: installs AIOStreams from the official image, starts it, checks the versions and updates, saves a configuration as the page does and asks the addon for streams; then the backup, the warm-up and a configuration restored after AIOStreams lost it. Only with `AIO_TESTS=1` (`TEST_RUNNER_AIO_TESTS=1` for xcodebuild): it downloads the image and leaves AIOStreams running for the rest of the test run |
| `AIOSettingsSyncTests` | *Save to Nuvio Account*: the choice, export, import, the newer backup wins, the same password |
| `PluginRuntimeTests`, `PluginPlatformTests`, `PluginAIOBridgeTests` | The plugins, and plugins through AIOStreams |
| Linux, outside this repository | `smoke.sh` from the official image with the same installer, Node 24 `--jitless` and WebAssembly through polywasm: install, configuration page, saving a configuration, streams, the versions port, a second start with the held refreshes, the "Nuvio plugins" card with a stand-in plugin (http and `nzbUrl` streams), the ports taken away and back after the wake file is written, no rate limits; a pinned and the newest version. And the ffprobe bridge against AIOStreams' real ffprobe code |

The app's whole test suite gives the same result as tvOS Beta 3.5.1 without these changes: 14 tests fail on both, none of them in what this adds.

---

## 16. Not done yet / ideas

- **ffprobe, Nuvio's side:** answer `NUVIO_FFPROBE_URL` from AetherEngine's probe (section 11).
- **Marketplace presets:** the same trick as the "Nuvio plugins" card can add other presets (e.g. NimeToDex) to AIOStreams' marketplace without touching its files.
- **AniList ids inside AIOStreams:** today only addons with the `anilist` prefix get them. The other option, AIOStreams converting ids for its other addons, would mean maintaining a change in AIOStreams; so far Nuvio asks with both ids (section 8).
- **Stale outgoing connections after waking:** the first `fetch` after a long sleep can fail (`fetch failed due to network error`) because tvOS closed the kept-alive sockets as well. Searches retry and work; something to watch.
