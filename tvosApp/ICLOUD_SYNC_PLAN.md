# iCloud Settings Sync — Implementation Plan

**Goal:** settings, integrations, and server configuration follow the user's Apple
Account across Apple TVs. Set up a Samba server on Apple TV A, open the app on
Apple TV B, and it is already there — credentials included.

**Status:** Phases 0–4 built and verified syncing on one Apple TV (records saving,
change tags cached, no errors). Phases 5–8 outstanding. §11 still unanswered.

Two things found on device that the plan had wrong:

- tvOS refuses Application Support and Documents; only `Library/Caches` and `tmp` are
  writable. `CloudSyncStateStore` had nowhere to persist system fields, so every save
  went up tagless and came back `partialFailure` → `serverRecordChanged`.
- Phase 4 is a conditional gate, not a deletion — see §4.

## Decisions log

| # | Decision | Chosen |
|---|---|---|
| 1 | Transport | **CloudKit private DB** via `CKSyncEngine`, per-entity records |
| 2 | Secrets | **Sync all secrets**, end-to-end encrypted via `CKRecord.encryptedValues` |
| 3 | Coexistence with Nuvio account sync | **iCloud replaces settings sync**, plus a one-way push-mirror (see §4) |
| 4 | Profile scope | **All profiles + their settings**; PINs never leave the device |
| 5 | Home layout | **In scope for v1** as its own record (see §5) |

## 1. Ground truth — what exists today

| Thing | Where | Shape |
|---|---|---|
| All app settings | `Sources/UI/Settings/SettingsView.swift:109-314` (`SettingsKey`) | ~150 keys in a per-profile `UserDefaults` suite `nuvio.tv.profile.settings.<id>` |
| Suite plumbing | `Sources/Models/CatalogModels.swift:5130` (`ProfileSettings`) | `.current` points at the active profile; `store(for:)` reaches any profile |
| SMB servers | `SettingsKey.smbServers` → `Sources/Core/SMB/SMBServerStore.swift` | JSON `[SMBServerConfig]` blob in the suite |
| Jellyfin servers | `SettingsKey.jellyfinServers` → `Sources/Core/Jellyfin/JellyfinServerStore.swift` | same pattern |
| Add-ons | `SettingsKey.streamAddonManifestURLs` / `…States` | JSON; read in `Sources/Data/Repository/CatalogRepository.swift:707` |
| Secrets | `SMBCredentialStore`, `JellyfinCredentialStore`, `AISubtitleKeyStore`, `SimklKeychainTokenStorage` | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — device-only by construction |
| Profiles | `Sources/DomainModels.swift:91` (`ProfileManager`) | `nuvio-profiles.json` in Application Support |
| Existing sync | `Sources/Core/Sync/NuvioSyncService.swift:2410` / `:2427` | `exportSettings` / `importSettings` over `SettingsKey.all` → Supabase RPCs |

Two facts shape everything below:

1. **`exportSettings`/`importSettings` already do what iCloud sync needs.** The blob
   shape, the encode/decode of heterogeneous `UserDefaults` values, and the
   device-local exclusion set are all solved. Reuse that logic; do not reinvent it.
2. **`Sources/` is the compiled tree.** `NuvioTV/Sources/` is a byte-identical stale
   duplicate left over from commit `9c2681d`. Do not edit it. New files need
   hand-written `pbxproj` entries (`PBXBuildFile`, `PBXFileReference`, group child,
   Sources build phase).

## 2. tvOS constraints that force the design

- **iCloud Keychain on tvOS — UNRESOLVED, blocks Phase 5.** The plan assumes tvOS does
  not participate in iCloud Keychain, so secrets must ride the CloudKit payload. The
  Phase 0 probe contradicted that: `SecItemAdd` with `kSecAttrSynchronizable` returned
  `errSecSuccess` on device. That only proves the attribute is *accepted*, not that the
  item leaves the Apple TV, so it is not yet a reason to change the design. Pending a
  two-device round-trip (`CloudKeychainProbe`). See §12.
- **tvOS purges the Keychain under storage pressure.** The CloudKit copy doubles as
  recovery for a TV that lost its own credentials.
- `CKSyncEngine` requires tvOS 17; target is **17.5**. `CKRecord.encryptedValues`
  requires tvOS 15 and works in the private database only.
- **The tvOS Simulator cannot sign into iCloud.** All validation happens on two
  physical Apple TVs signed into the same Apple Account.
- **Sideloaded builds have no entitlement.** The codebase already handles
  "unsigned/sideload signing combinations" (`DomainModels.swift:578-635`). iCloud sync
  is a signed-install-only feature and must degrade to a silent no-op, never an error.
- **`NuvioSyncManager` pushes on every `UserDefaults.didChangeNotification`**
  (`NuvioSyncService.swift:141-147`). Applying a remote change trips it. Every apply
  path needs an origin guard or the two managers ping-pong.

## 2a. Sync is manual, and deletions do not propagate

Two deliberate departures from the obvious design, both chosen for blast radius:

**Sync only runs from Settings → Sync Now.** `CKSyncEngine` is configured with
`automaticallySync = false` and nothing triggers on scene activation. The engine still
tracks pending changes and persists its state; it just does not touch the network on its
own. The cost is that a change made on one Apple TV does not appear on another until
someone asks for it.

**Remote deletions are never applied.** `CloudSyncManager.delete` is a no-op. Removing a
server — or resetting settings — on one Apple TV must not remove it from the others.
Because the shared record still exists, a local removal is recorded in a per-profile
`dismissedRecords` set so the next fetch does not restore it; that set lives in the
profile suite rather than the sync cache, since Caches is purgeable and a purge would
resurrect every deleted server. The trade: clearing a server everywhere means removing
it on each device.

Relatedly, `resetSettings()` no longer clears `smbServers`, `jellyfinServers`, or their
scan indexes. Those are hand-entered hosts, shares, and Keychain credentials, not
"settings defaults"; removing a server is its own explicit action in Integrations.

## 3. Ownership model

| Domain | Authority |
|---|---|
| Settings, integrations, SMB/Jellyfin servers, add-ons, home layout, secrets | **iCloud** (read authority, always) |
| Watch state, library, collections, continue-watching | **Nuvio account** (unchanged) |
| Profile list | Nuvio account **when signed in**; iCloud when not |
| Home layout | Nuvio account **when signed in**; iCloud when not (see §5) |

The rule behind the last two rows: never let two systems be read authorities for the
same data. When a Nuvio session is active it wins and the iCloud record is written but
not applied.

## 4. The push-mirror

Today `NuvioSyncManager` both writes and reads settings against Supabase:

- **Push** — `pushProfileSettings` (`NuvioSyncService.swift:1972`) writes tvOS settings
  into the shared blob under `tvos_settings`, `debrid_settings`, `tmdb_settings`,
  `stream_badge_settings`.
- **Pull** — `pullProfileSettings` (`:1936`) reads that blob back and calls
  `importSettings`, writing into the local suite.

Since iCloud becomes the settings authority, **the pull must go** — otherwise two
systems write the same suite. **The push stays.**

Two corrections found while implementing this:

1. It is **four** import calls, not one: `importSettings`, `importDebridSettings`,
   `importTmdbSettings`, and `importStreamBadgeSettings` all write into the local
   suite. Dropping only the first would have left three writers behind.
2. Removing them unconditionally **regresses sideloaded installs**, which ship with no
   iCloud entitlement and would end up with no settings sync at all. So the imports are
   gated on `CloudSyncManager.isSettingsAuthority` rather than deleted: iCloud reads
   when it is available, the account reads when it is not. The two are mutually
   exclusive, so there is still only ever one read authority.

```
                  writes                    reads
Apple TV  ──┬──> iCloud (CloudKit) ──> Apple TV     ← the authority
            └──> Supabase blob ─────> Android TV / mobile
                                       ✗ never back to Apple TV
```

This preserves one direction of cross-platform parity: the Android TV and mobile apps
keep seeing debrid keys and TMDB config changed on the Apple TV. It does **not**
preserve the reverse — a debrid key changed on Android TV will no longer reach the
Apple TV, because nothing reads the account blob anymore. That is an accepted cost.

Implementation: gate the four imports in `pullProfileSettings` behind
`CloudSyncManager.isSettingsAuthority`, and leave `pushProfileSettings` untouched.

The return value carries the mirror decision. `false` makes the caller push, so when
iCloud is authoritative *and has merged at least once*, the account row is refreshed
from local state on every pull. Before that first merge it returns `true` (no push) —
a device that has not yet pulled from iCloud holds nothing authoritative, and pushing
would overwrite the mirror other platforms read with this device's defaults.

## 5. Home layout

Home catalog order and hidden rows travel through **separate RPCs** —
`pushHomeCatalogSettings` (`:235`) and `pullHomeCatalogSettings` (`:1712`) — not the
profile-settings blob. Phase 4 does not touch them, so signed-in users keep that sync
in both directions, unaffected. Account-less users never had it.

The `HomeLayout` record is therefore **new capability for account-less users**, not a
regression fix. It is in scope because home row order and hidden catalogs are exactly
what a user perceives as "my configuration." It follows the §3 rule: written always,
**applied only when no Nuvio session is active.**

It carries the four keys that are *not* in `SettingsKey.all`:

- `homeCatalogOrder` — local tvOS reorder
- `homeCatalogSyncedOrder` — account order
- `homeCatalogDisabled` — hidden catalog keys
- `homeCollectionDisabled` — hidden collection ids

It deliberately excludes `homeCatalogTitles`, `homeCatalogDisabledAddonIDs`, and
`homeCatalogDisabledAddonNames` — local derived snapshots Home rewrites on every load.
`homeLayout` and `heroCatalogs` already live in `SettingsKey.all` and ride the settings
record; do not duplicate them here.

## 6. CloudKit schema

Container `iCloud.com.rb.nuviotvos` (team `852397N5X9`), private database, custom zone
`NuvioSync`:

| Record type | recordName | Fields |
|---|---|---|
| `ProfileList` | `profiles` | `payload` (JSON: id, name, avatarId, isAdmin), `updatedAt`, `deviceID` |
| `ProfileSettings` | `settings-<pid>` | `payload` (JSON: key → encoded value), `stamps` (JSON: key → ms), `secrets` **encrypted**, `schemaVersion` |
| `SMBServer` | `smb-<uuid>` | `profileID`, `config` (JSON `SMBServerConfig`), `password` **encrypted**, `updatedAt` |
| `JellyfinServer` | `jf-<uuid>` | `profileID`, `config`, `token` **encrypted**, `updatedAt` |
| `AddonList` | `addons-<pid>` | `payload` (ordered manifest URLs + enabled states), `updatedAt` |
| `HomeLayout` | `home-<pid>` | `payload` (the four keys in §5), `updatedAt` |

Servers get **one record each** so two TVs adding different servers both survive and a
deletion on TV A propagates as a real tombstone. Settings get one record with **per-key
timestamps** so a theme change on TV A and a subtitle-size change on TV B merge instead
of clobbering.

**Excluded from sync:**

- `smbLibraryIndex` / `jellyfinLibraryIndex` — large derived scan output; each TV
  rescans. Revisit later as a `CKAsset`.
- `homeCatalogTitles`, `homeCatalogDisabledAddonIDs`, `homeCatalogDisabledAddonNames` —
  local derived.
- `accountSyncWatchState` — per-device policy, already excluded at
  `NuvioSyncService.swift:2416`.
- Profile PINs — never.

## 7. The per-key timestamp problem

`UserDefaults` records no modification times, and there are 100+ `@AppStorage` call
sites, so wrapping every write is off the table.

**`SettingsChangeJournal`** — a debounced `UserDefaults.didChangeNotification` observer
that diffs the current suite against a cached snapshot and stamps only the keys that
actually moved, into a sidecar `nuvio.icloud.stamps.<pid>`. Zero call-site changes, and
it reuses a notification the app already fires.

Merge is then per-key last-writer-wins, with a deterministic device-ID tiebreak on
equal timestamps.

## 8. Phases

### Phase 0 — Capability and provisioning *(~1h, needs Apple Developer portal access)*

Create the iCloud container `iCloud.com.rb.nuviotvos` in the portal under team
`852397N5X9`. Add
`com.apple.developer.icloud-container-identifiers` and
`com.apple.developer.icloud-services: [CloudKit]` to `NuvioTV/NuvioTV.entitlements`;
let automatic signing regenerate the profile.

**Gate:** a temporary row in Settings → About printing `CKContainer.accountStatus()`
reads `.available` on both Apple TVs. Nothing else starts until this is green.

> Do not edit the entitlements file before the container exists in the portal —
> automatic signing will fail and the build breaks until it does.

### Phase 1 — Snapshot layer, no CloudKit *(~1 day)*

New files under `Sources/Core/Sync/iCloud/`: `CloudSyncSnapshot.swift`,
`SettingsChangeJournal.swift`, `CloudSyncPolicy.swift`.

Add `SettingsKey.cloudSynced` and `SettingsKey.cloudSecrets` alongside the existing
`deviceLocal` set. Pure Swift, no CloudKit import — fully unit-testable in
`NuvioTVTests` with no iCloud account. Merge correctness gets proven here.

### Phase 2 — Engine *(~1.5 days)*

`CloudSyncSchema.swift`, `CloudSyncEngine.swift`. A `CKSyncEngine` delegate handling
`.stateUpdate`, `.fetchedRecordZoneChanges`, `.sentRecordZoneChanges`, `.accountChange`.

State serialization goes to a **file** in Application Support — reuse
`ProfileViewModel.makeDefaultProfileManager`'s writable-directory probe
(`DomainModels.swift:578`), which already handles sideload containers where Application
Support is not writable. Not `UserDefaults`: that feeds the write storm and risks the
oversized-plist abort the codebase already guards against.

Get the encrypted/plain field split right here, before any real data exists — a field
that ships plaintext cannot be converted to encrypted later.

### Phase 3 — Store wiring *(~1 day)*

`SMBServerStore.upsert`/`remove` and the `JellyfinServerStore` equivalents enqueue
record saves and deletes. The apply path writes with `CloudSyncOrigin.isApplyingRemote`
set, then posts each store's existing `changedNotification` so live UI updates.

### Phase 4 — Coexistence surgery *(~0.5 day)*

Delete the `importSettings` call at `NuvioSyncService.swift:1936`. Leave
`pushProfileSettings` (`:1972`) exactly as it is — see §4. Add the origin guard to the
`didChangeNotification` observer at `:141`.

### Phase 5 — Secrets *(~0.5 day)*

Split the settings payload into plain `payload` and encrypted `secrets`. Pull SMB
passwords, Jellyfin tokens, AI subtitle keys, and the Simkl token out of the Keychain on
export; write them back on apply. Add a "Sync passwords and API keys" toggle, default on.

### Phase 6 — UI *(~0.5 day)*

Inside `SettingsView.swift`, in the Account section near `:1600` beside "Sync Watched
State": iCloud toggle, status row, last-synced timestamp, "Sync Now", and a destructive
"Reset iCloud Data" with confirmation.

Reuse the existing `SettingsToggleRow` / `SettingsActionRow` / `SettingsInfoRow` — they
already handle tvOS focus correctly. These components are private to `SettingsView.swift`,
so the new rows must live in that file.

### Phase 7 — Validation *(~1 day)*

Unit tests for the Phase 1 merge layer. Two-device matrix on physical hardware:
add/edit/delete a server on each side, simultaneous edits to different keys,
simultaneous edits to the same key, sign-out mid-sync, airplane-mode divergence.

### Phase 8 — Rollout

**Release checklist, in order:**

1. **Promote the schema.** CloudKit Console → `iCloud.com.rb.nuviotvos` → Development →
   *Deploy Schema Changes* → Production. The record types were auto-created in
   Development by the first real sync. Skip this and every user hits
   `CKError.unknownItem`, which the app reports as "CloudKit schema missing".
2. **Verify the encrypted fields survived promotion** — `SMBServer.password`,
   `JellyfinServer.token`, `ProfileSettings.secrets` must all read as *Encrypted Bytes*
   in Production. A field created plaintext cannot be converted later without dropping
   the record type.
3. **Flip `aps-environment`** in `NuvioTV.entitlements` from `development` to
   `production` for a release build.
4. **Feature flag:** `SettingsKey.iCloudSyncEnabled` already gates the whole feature per
   device and defaults on. To ship dark, change that default to `false`.
5. **Confirm a fresh install merges rather than clobbers**: install on a third device
   signed into the same Apple Account, press Sync Now, and check that its defaults did
   not overwrite the zone. Per-key stamps should make the existing values win.

**Verified on hardware:** two Apple TVs, same Apple Account. Settings, integrations, SMB
and Jellyfin servers all arrived, servers connected with their synced credentials. Media
indexes are rebuilt per device by design (§6).

**Estimate:** roughly 6 working days, plus ~7 hand-edited `pbxproj` file registrations.

## 9. End-to-end trace

**TV A** — user adds SMB server `10.0.1.5` with a password.

1. `SMBSettingsSection` → `SMBServerStore.upsert` (`SMBServerStore.swift:29`)
2. Persists JSON to the suite, `SMBCredentialStore.save` writes the password to the
   Keychain, posts `changedNotification`
3. `CloudSyncManager` observes it, builds `SMBServer-<uuid>` with
   `encryptedValues["password"]`, enqueues to `CKSyncEngine`
4. Engine batches and uploads. The password is end-to-end encrypted before it leaves
   the device.

**TV B** — app foregrounds, `fetchChanges()`.

5. Delegate receives `.fetchedRecordZoneChanges` with the new record
6. Sets `CloudSyncOrigin.isApplyingRemote = true`, writes config into
   `nuvio.tv.profile.settings.<pid>`, writes the password into the local Keychain,
   clears the flag, posts `SMBServerStore.changedNotification`
7. `SMBServerStore.reload()` republishes; Settings updates live. Home's "Local titles"
   row appears after TV B runs its own first scan.
8. `NuvioSyncManager`'s `didChangeNotification` observer fires, sees the origin flag,
   and skips the Supabase push. No loop.

## 10. File manifest

**New** — all under `Sources/Core/Sync/iCloud/`, each needing manual `pbxproj`
registration:

- `CloudSyncSnapshot.swift`
- `SettingsChangeJournal.swift`
- `CloudSyncPolicy.swift`
- `CloudSyncSchema.swift`
- `CloudSyncEngine.swift`
- `CloudSyncManager.swift`
- `CloudSyncOrigin.swift`

**Modified:**

- `NuvioTV/NuvioTV.entitlements` — iCloud container + services *(Phase 0, after portal)*
- `Sources/UI/Settings/SettingsView.swift` — `cloudSynced`/`cloudSecrets` sets; Account
  section rows
- `Sources/NuvioTVApp.swift` — attach `CloudSyncManager` near `:283`
- `Sources/Core/Sync/NuvioSyncService.swift` — delete `importSettings` call at `:1936`;
  origin guard at `:141`
- `Sources/Core/SMB/SMBServerStore.swift`, `Sources/Core/Jellyfin/JellyfinServerStore.swift`
  — emit sync events
- `NuvioTV.xcodeproj/project.pbxproj` — file registrations

## 11. Open: does iCloud Keychain actually work on tvOS?

Phase 0 on device reported:

```
Container             iCloud.com.rb.nuviotvos
Account Status        Available
Keychain Attribute    accepted — revisit Phase 5
```

`accepted` means `SecItemAdd` did not reject `kSecAttrSynchronizable`. It does **not**
mean the item syncs — the keychain can store the flag locally and never participate in
iCloud Keychain. Acting on the weaker signal risks the worst failure mode this feature
has: passwords that silently never arrive on the second Apple TV.

Two caveats on the probe that fired:

1. It set no `kSecAttrAccessible`, so it used the default. Every real credential store
   uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and **`ThisDeviceOnly`
   classes can never sync**. The probe did not test the configuration the stores use.
2. Acceptance is local. Only a cross-device read proves transport.

**The resolving test** — `CloudKeychainProbe`, wired into Settings → Account & Profiles:

1. On **TV A**, press *Write Keychain Probe*. It stamps `<device name> @ <time>` into a
   synchronizable item using `kSecAttrAccessibleAfterFirstUnlock` (the relaxed class a
   syncing item requires).
2. Wait — iCloud Keychain propagation is not instant.
3. On **TV B**, press *Re-check* and read the *Keychain Round-Trip* row.

| Result on TV B | Meaning |
|---|---|
| TV A's name and timestamp | iCloud Keychain works. **Phase 5 collapses** — SMB passwords and Jellyfin tokens just set `kSecAttrSynchronizable`, and the encrypted CloudKit fields become unnecessary for them. |
| `not found`, persistently | Assumption holds. Plan proceeds unchanged. |
| TV B's own marker only | Items are local. Same as `not found`. |

If it does work, the cost is not zero: all three credential stores must relax from
`AfterFirstUnlockThisDeviceOnly` to `AfterFirstUnlock`, which widens when the secrets
are readable on-device. Worth it for the simplification, but it is a real tradeoff to
make deliberately.

## 12. Risks

- **Sideloaded installs get nothing.** Entitlement-dependent; must be a silent no-op
  with an honest status row.
- **Schema deploy is a one-way gate.** Production deploy must precede the first release
  build.
- **Encrypted-field migration is painful.** A field that ships plaintext cannot become
  encrypted later without a record migration. Settle the split in Phase 2 — and settle
  §11 first, since it decides whether secrets need CloudKit fields at all.
- **Cross-platform parity is now one-way.** Accepted; see §4.
