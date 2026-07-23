# Future Implementation

## Apple TV storage architecture

### Current state

Large and structured payloads have been moved out of `NSUserDefaults` into atomic files under Application Support. Existing values are migrated automatically. This is the immediate fix for the tvOS preferences-size crash and should ship before the database work.

The file-backed layer is a migration bridge, not the final persistence model. It still reads and rewrites complete JSON payloads, and tvOS may purge local files when device storage is low.

### Target architecture

| Data | Storage |
| --- | --- |
| Small UI settings, flags, and active profile ID | `NSUserDefaults`, kept comfortably below 512 KB |
| Authentication tokens and secrets | Keychain |
| Profiles, library, watched items, watch progress, collections, and download metadata | SQLite through SQLDelight |
| Stream links, binge groups, and continue-watching enrichment | SQLite cache tables with expiry and bounded retention |
| Important user data | Backend remains authoritative and can restore purged local state |

SQLDelight is preferred for the Apple client because its native driver supports Kotlin/Native and tvOS. Database work must run off the main thread and repositories should update individual rows rather than serializing entire datasets.

### Migration sequence

1. Add SQLDelight and create versioned schemas for the growing datasets.
2. Migrate watch progress, watched items, library, collections, and download metadata first.
3. Migrate disposable stream and enrichment caches.
4. On first database launch, import existing file-backed payloads in a transaction.
5. Mark a payload as migrated only after the transaction commits successfully.
6. Keep the source file until the imported rows have been verified, then delete it.
7. Retain the file reader for at least one release so users can safely upgrade across versions.

### Cache policy

- Stream links: expire by age and retain at most 500 entries per profile.
- Binge groups: retain the 500 most recently used entries per profile.
- Continue-watching enrichment: retain only the bounded set required by the UI.
- Remove expired cache rows during writes and periodic maintenance.
- Do not arbitrarily prune library, collection, watched-history, or watch-progress records. Sync those records with the backend instead.

### Acceptance criteria

- `NSUserDefaults` contains no growing collections or JSON snapshots.
- No database or file operation runs synchronously on the UI thread.
- Updates write only affected rows rather than complete datasets.
- Interrupted migrations are retryable without duplication or data loss.
- The app rebuilds disposable caches after tvOS purges local storage.
- Important user state restores from the backend after reinstall or local-data eviction.
