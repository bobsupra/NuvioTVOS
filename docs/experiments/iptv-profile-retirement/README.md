# Local experiment: profile retirement and IPTV cleanup

This is a standalone state-machine prototype, not integrated with the app or the PR. It does not include a concrete durable journal, does not implement logout, and does not guarantee crash safety by itself.

The proposed order is: recover any previous intent; durably record IDs to retire; commit the profile list; then recover by reading the authoritative list. If an ID is still present, the commit did not remove it and its sources stay. If absent, delete its sources and only then remove it from the journal. Failed cleanup keeps its marker and blocks reuse. A failed or ambiguous profile read must stop recovery, never be interpreted as an empty profile list. Retrying deletion must be idempotent.

Integration requires:

- a durable, atomic, error-reporting implementation of the journal, including migration of #522's existing UserDefaults marks;
- one serialized owner for all profile mutations, IPTV reads/writes, and ID reuse, including the launch recovery task; a task that deletes prepared records without reconciling the profile list is unsafe;
- a genuinely authoritative error-reporting profile read. Current `getProfiles()` catches errors and can return an empty list, so it cannot directly serve as that boundary;
- a way to recover correctly for both file-backed and UserDefaults-backed profile storage, and clarify when each profile commit itself is durable;
- a separate protocol for full sign-out and the retained guest slot: absence from the profile list alone is insufficient there;
- coordination with #522 generations, favourites and recent channel cleanup, and with pending playlist loads;
- review of I/O failure, crash boundaries, and all legacy or other writers before connecting it to production.

The accompanying XCTest file describes deterministic state transitions only. The coordinator assumes its storage and serialization contracts; the mock does not establish disk durability, platform behavior, or integration correctness.
