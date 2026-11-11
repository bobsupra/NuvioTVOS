# Nuvio JS plugins on Apple TV

Nuvio on Apple TV runs the same JavaScript plugins (scrapers) as Nuvio on Android, directly on the Apple TV (`tvosApp/NuvioTV/Sources/Core/Plugins/`). Repositories are installed from a link, just like on Android, and the repository list syncs through the Nuvio account. On top of the Android format it adds a few Apple TV extensions:

- subtitles, catalogs, metadata, search and ratings from plugins,
- `nzbUrl` streams for Nuvio Usenet,
- a Verify hook,
- `localStorage`,
- a browser page for setting everything up from a computer.

**Status:** everything described here is built and tested on a real Apple TV: streams, settings, sync, Test, Developer Mode, the setup page, subtitles, catalogs, metadata, search and ratings.

**Plugins written for Apple TV** (`tvos` in `supportedPlatforms`, or `"keepAlive": true`) also get:

- **one JavaScript context while Nuvio runs:** calls are multiplexed by id; a context is dropped after 10 idle minutes, beyond 12 providers, on memory warnings and after a timeout;
- **progressive results:** `getStreams` gets `emit(list)`, and emitted streams show in the provider's group while it searches; the returned list replaces them;
- **resolve on play:** a stream may carry `resolve` instead of `url`; the player opens an address on the on-device server (127.0.0.1:8766), and the plugin's `resolveStream()` returns the link it is redirected to;
- **its own pages:** `handleRequest()` serves a provider's configuration page (`"configPage": true`, *Configure* on the setup page, sandboxed) and routes for the player (`NUVIO.server.url`), with `NUVIO.settings.get`/`save`;
- **files:** `NUVIO.files`, 50 MB of text files per provider; `localStorage` up to 5 MB.

Every plugin request (keys masked) and its timing is in the provider's Logs. Repositories update on their own at most once a day.

**Through AIOStreams:** with AIOStreams running inside Nuvio, a plugin can be served to AIOStreams as an add-on instead of being shown directly (`docs/aiostreams-in-nuvio.md`, section 12).

---

## What the user gets

**Settings → Integrations → Plugins**

- **Repository URL:** paste a `manifest.json` link, a GitHub link (`blob` links become `raw` automatically) or an Android short code.
- **Use Plugins:** one switch for all plugins.
- **Repositories:** Update, move up/down, Remove, and a per-repository **Developer Mode** switch.
- **Providers:** each scraper can be switched on and off and has three buttons:
  - **Settings:** the form the provider describes in `onSettings()`, plus **Verify** when the plugin has `onVerify`.
  - **Test:** one search for a sample movie or episode, showing the streams and/or subtitles, the time it took and the provider's log lines.
  - **Logs:** the provider's latest `console` output.
- **Set Up from a Computer:** a QR code and an address for doing all of the above in a browser on the same network (details below).

**Where plugin results appear**

- **Streams:** each enabled provider is a group on the stream screen next to the add-ons (`plugin:<id>`, as on Android). Results go through the same Stremio stream decoder as add-on results, so debrid, torrents, headers, subtitles and Nuvio Usenet all behave like add-on streams.
- **Subtitles:** in the player's subtitle list next to the subtitle add-ons. Preferred-language auto-selection works for them too.
- **Catalogs, metadata, search and ratings:** a plugin that offers them is presented to the app as an add-on that exists only on the Apple TV (details below). Its rows appear on Home and Discover and can be ordered and hidden like any add-on's. Its catalogs with a `search` extra are used for search. Its own ids get its metadata in Details, and its rating sources appear in the rating settings, Details, the Home hero and episodes.

**Sync and storage**

- **Sync:** the repository list syncs through the account's `plugins` table (`sync_push_plugins` RPC), with the same first-sync rule as Android. Repositories added on nuvio.tv or on Android show up on the Apple TV, and the other way round.
- **Settings stay on the device:** provider settings are kept in the Keychain per profile and are never synced. They often hold API keys.

---

## Compatibility with Nuvio on Android

The goal was that a plugin written for Android TV runs unchanged on Apple TV.

| | Same as Android TV |
|---|---|
| **Manifest** | `name`, `version`, `scrapers[]` with `id`, `name`, `version`, `filename`, `supportedTypes`, `enabled`, `hasSettings`, `logo`, `contentLanguage`, `formats`, `supportedPlatforms` / `disabledPlatforms`. Parsing is lossy and also accepts a bare array of scrapers. Apple TV runs a scraper unless `tvos` is disabled, or unless the scraper lists platforms that include neither `tvos` nor `ios` (the iOS app runs the same JS). |
| **Repository URLs** | Short codes, GitHub `blob` → `raw`, appending `manifest.json`, fixing the scheme, canonical `/manifest.json`. The scraper id is `<manifest url lowercased>:<id>`. |
| **`getStreams(tmdbId, mediaType, season, episode)`** | The TMDB id when TMDB knows the title, otherwise the content id. `mediaType` is `movie` or `tv`, or `series` when the scraper lists `series`. |
| **Environment** | `fetch` (`ok`, `status`, `headers.get`, `text`, `json` → `null` on bad JSON, `arrayBuffer`; network errors resolve with status 0; `redirect: "manual"`), `cheerio` (also via `require('cheerio' \| 'cheerio-without-node-native' \| 'react-native-cheerio')`), real `crypto-js` 4.2.0 (`require('crypto-js')`), `URLSearchParams` (`keys`/`entries` as arrays), `TMDB_API_KEY`, `SCRAPER_ID`, `SCRAPER_SETTINGS`, desktop User-Agent, a `WebAssembly` placeholder. |
| **Limits** | 60 s per call, at most 10 plugins running at once. |
| **Results → streams** | Android TV's layout: name (or title, or provider) + `" - quality"`, the title below, then `size • language`. Text containing `[object` is dropped. `headers` become proxy headers (without `Range`). `subtitles` default the language to `Unknown`. |
| **Settings form** | `onSettings()` with `text` (`isPassword`), `select`, `toggle` / `switch` / `checkbox`, `info`, and `defaultValue`. |

Not possible on Apple TV: **CloudStream extensions** (`.cs3` / DEX). They are Android bytecode, so the Apple TV runs JavaScript plugins only.

---

## What Apple TV adds over Android (for plugin authors)

Every addition is optional, and Android ignores the extra manifest keys. Providers that rely on Apple TV-only features should be marked `"supportedPlatforms": ["tvos"]` so that Android hides them, since the repository list syncs between devices.

| Feature | Android TV | Apple TV |
|---|---|---|
| **5th `getStreams` argument** | — | `{ imdbId, tmdbId, videoId, type, season, episode, platform: "tvos" }`. A plugin gets the IMDb id even when the first argument is a TMDB id (Usenet indexers need it). |
| **Usenet streams** | — | `nzbUrl` (with `fileMustInclude`, `fileIdx`, `servers`), played by Nuvio Usenet (native NNTP). The Stremio fields `description` and `behaviorHints` are read too. |
| **Subtitles from plugins** | — | `"resources": ["subtitles"]` in the manifest (`"stream"` is the default), optional `"idPrefixes"`, and `getSubtitles(type, id, context)` → `[{ url, lang, label }]`. `context` contains `imdbId`, `tmdbId`, `season`, `episode`, `filename`, `videoSize` and `videoHash`. Calls have a 20 s limit and answers are cached for 10 minutes. |
| **Catalogs, metadata, search** | — (CloudStream extensions only) | `"resources": ["catalog", "meta"]` with Stremio `catalogs`. `getCatalog(type, id, extra)` → `{ metas }` (extras: `search`, `skip`, `genre`) and `getMeta(type, id)` → `{ meta }`. Metadata is used only for the plugin's own `idPrefixes`; `tt` / `tmdb` ids keep Cinemeta / TMDB. |
| **Ratings** | — | `"resources": ["ratings"]` with Nuvio's `ratingSources`, and `getRatings(type, id, context)` → `[{ source, value, url }]`, also per episode (`tt…:1:2`). Built-in sources can't be replaced. |
| **Checking settings** | — | `onVerify(settings)` → `{ ok, message }` behind a **Verify** button, run with the values in the form before they are saved. |
| **Storage** | — | `localStorage` per provider and profile (up to 2 MB, `QuotaExceededError` above). |
| **Platform** | — | `NUVIO_PLATFORM === "tvos"` |
| **Browser APIs** | `URL`, `atob` / `btoa`, a minimal `AbortController` | The same, plus `crypto.subtle` (SHA digests, HMAC, AES-GCM / CBC / ECB, PBKDF2), `crypto.getRandomValues` / `randomUUID`, `TextEncoder` / `TextDecoder`, `AbortSignal`, `Headers` / `Request` / `Response`, `structuredClone` |
| **Web setup** | Repository list only (add/remove); every change is confirmed on the TV. | Repositories (add, update, order, remove, developer mode), providers (on/off), **provider settings incl. API keys**, Verify, Test and **live logs**. Details in the next section. |
| **Test** | The Matrix (TMDB 603), with diagnostics. | Movie (The Matrix) or episode (Breaking Bad S1E1), or any IMDb id on the web page. Shows streams and/or subtitles, the time taken and the log lines from that run. |
| **Developer Mode** | — | Per repository: the code is downloaded again before every call, so an author can edit and retry without bumping versions. Serving the folder from a computer works too (`http://<pc-ip>:8080/manifest.json`). |

Tools in the plugin repository: [`test/harness.js`](https://github.com/david325345/nuvio-plugins/blob/main/test/harness.js) runs any plugin in Node the way the Apple TV does. It uses the app's own polyfills, generated from `PluginPolyfills.swift`. Plugin authors can test without a TV, and the format is documented in the [README](https://github.com/david325345/nuvio-plugins#the-plugin-format-on-apple-tv).

---

## Set Up from a Computer

Typing API keys with the Siri Remote is slow, so the TV can serve a small page on the local network.

- **Where it listens:** an `NWListener` on the Apple TV's local IPv4 address only (`en*`), preferring port 8765.
- **Address:** every address carries a random token path (`http://192.168.x.x:8765/<token>/`). Requests outside the token get a 404 and never reach the app.
- **When it runs:** only while that screen is open on the TV, and it stops after 15 minutes without a request.
- **Saved passwords** are never sent back to the browser in full. The page shows `••••` and the last four characters, and leaving the field empty keeps the saved value.
- **Keep the Same Address** saves the token in the Keychain, so the page can be bookmarked. **New Address** makes a new one.
- **Page:** one self-contained HTML page (no external resources) with a small JSON API (`PluginWebAPI`). It goes through the same `PluginStore` as the TV screens, so changes show on the TV immediately.

---

## Catalogs, metadata and ratings as virtual add-ons

The app already has everything for catalogs, metadata, search and ratings in the shape of Stremio add-ons, so plugins plug into that instead of getting new screens.

- **Manifest:** a provider that lists `catalog`, `meta` or `ratings` gets a Stremio manifest built from its plugin manifest. That covers its `catalogs`, its `ratingSources`, and resource-level `idPrefixes` (metadata only for its own prefixes). The manifest URL is `https://plugins.nuvio.invalid/<key>/manifest.json?v=<revision>`. The `.invalid` domain can never resolve, and a changed manifest gets a new revision, so Home reloads.
- **Where the URLs go:** they are appended to `configuredStreamAddonManifestURLs` at runtime and are never written to the add-on preferences, so nothing reaches account sync. Stream discovery ignores them (they have no `stream` resource); plugin streams keep their own groups.
- **How requests are answered:** a `URLProtocol` (`PluginAddonURLProtocol`) handles them, registered for `URLSession.shared` and installed into the three add-on sessions. It calls `getCatalog`, `getMeta` or `getRatings` and returns the normal Stremio JSON. Answers must come within 8 s (the add-on sessions' limit). They are cached for 10 minutes (searches 2, metadata and ratings an hour), and the cache is cleared when the provider's settings are saved.

---

## Example: Usenet Direct

[Usenet Direct](https://github.com/david325345/nuvio-plugins) started as a server add-on, and the plugin moves it onto the Apple TV:

```
https://raw.githubusercontent.com/david325345/nuvio-plugins/main/manifest.json
```

- **What it does:** searches Newznab indexers (NZBGeek, altHUB, Usenet-Crawler, DogNZB and one custom indexer) by IMDb id and returns `nzbUrl` streams that **Nuvio Usenet** plays straight from the user's own usenet server.
- **Why a plugin rather than a server add-on:** the indexer keys stay in the TV's Keychain and the requests come from the user's own connection. With a shared server, every user's API key arrives from one IP address, and indexers rate-limit and flag that.
- **Apple TV features it uses:**
  - the 5th argument (`imdbId`),
  - `localStorage` caches (indexer capabilities for a day, TVmaze for 90 days, results for an hour, empty results for 15 minutes),
  - `onVerify` to check the keys with `t=caps`,
  - `nzbUrl` results,
  - `"supportedPlatforms": ["tvos"]`.
- **Searching:**
  - Movies: `t=movie&imdbid=`.
  - Series: `imdbid` where the indexer supports it for TV, otherwise IMDb → TVmaze → `tvdbid` / `tvmazeid`.
  - An indexer that reports its daily limit is skipped until midnight UTC.
- **Filtering and ordering:** results are filtered (passworded releases, wrong episode, resolution, size, CAM/TS) and sorted with Czech/Slovak audio and subtitles first.
- **Tests:** Node tests against a fake indexer and a fake TVmaze.

There is also a repository of examples (`…/main/examples/manifest.json`):

- **Example: OpenSubtitles** takes subtitles from the OpenSubtitles v3 add-on and keeps only the languages chosen in its settings.
- **Example: TVmaze** provides a "Streaming Today" catalog (with genre and skip), search, metadata for shows without an IMDb id, and show and episode ratings, all from the free TVmaze API.

---

## How it is built

All new code is in `Sources/Core/Plugins/`. Outside it, only small hooks were needed.

| Part | How it works |
|---|---|
| **Runtime** (`PluginRuntime.swift`, `PluginPolyfills.swift`) | JavaScriptCore with a fresh `JSContext` per call on its own serial queue. Natives are exposed as `@convention(block)` closures. Browser APIs are one embedded JS file (also used by the Node tests). Timers are native. `fetch` runs on a `URLSession` without cookies or cache, with a 20 MB response limit, and `AbortController` cancels the task. Calls are async, with timeouts. |
| **Android compatibility** (`PluginCompat.swift`, `PluginLibraries.swift`) | `cheerio` is a wrapper over **SwiftSoup** (a jsoup port, the same approach as Android's jsoup natives). Crypto comes from CryptoKit / CommonCrypto. `crypto-js` 4.2.0 is embedded (MIT) and loaded lazily. |
| **Store** (`PluginStore.swift`, `PluginModels.swift`) | Repositories and scrapers per profile in `LargePayloadStore`, plugin code as files, settings in the Keychain, `localStorage` per provider. |
| **Streams** (`PluginStreamDiscovery.swift`) | `StreamsRepository` adds plugin groups next to the add-on groups. The TMDB id comes from `TmdbDetailsService` (+10). |
| **Subtitles** (`PluginSubtitleDiscovery.swift`) | `CatalogRepository.subtitlesProgressively` asks the subtitle providers next to the add-ons. Answers are cached for 10 minutes, and the cache is cleared when settings are saved. |
| **Catalogs, metadata, ratings** (`PluginAddons.swift`) | The virtual add-on registry, the manifest builder, the `URLProtocol` and the response cache. `CatalogRepository` appends the URLs and installs the protocol into its two sessions (+22 lines in total with subtitles); `StreamsRepository` installs it into its manifest session and only asks stream providers whose `idPrefixes` match (+21). |
| **Sync** (`NuvioSyncService.swift`, +116) | Pull/push of the `plugins` table, with the same RPC and rules as Android. |
| **UI** (`SettingsView.swift`, +921) | The Plugins screen, the settings / test / logs sheets and the setup sheet. |
| **Web setup** (`PluginWebServer.swift`, `PluginWebAPI.swift`, `PluginWebPage.swift`) | As described above. |
| **Test** (`PluginTester.swift`) | Shared by the TV and the web page. |
| **Dependency** | `SwiftSoup` 2.14.3 (`Project.swift`, +3). |

**Size:** 21 files, about 7,700 added lines. Around 1,100 of them are the embedded JS polyfills and about 780 are tests.

**Tests:**
- `PluginRuntimeTests`, 25 XCTest cases: manifests and URLs, settings forms, the runtime and its browser globals, timeouts and errors, `localStorage`, cheerio, CryptoJS and WebCrypto against known values, `fetch` through a stub, Android result mapping, request ids, web server parsing, password handling, subtitles, the virtual add-on manifest, routes and results, and a virtual add-on served through `URLSession`.
- `scripts/test-plugin-polyfills.js` runs the embedded JS in Node (13 checks).
- In the plugin repository, the Usenet Direct tests (7), the subtitles example tests (5) and the TVmaze example tests (6).

---

## Next

- **Possible later:** metadata from plugins for `tt` / `tmdb` ids too (e.g. localized descriptions). This needs a rule for whose metadata wins, so it is left out for now.
