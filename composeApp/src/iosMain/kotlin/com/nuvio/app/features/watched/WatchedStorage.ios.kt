package com.nuvio.app.features.watched

import com.nuvio.app.core.storage.AppleFileStringStorage

actual object WatchedStorage {
    private fun payloadKey(profileId: Int) = "watched_payload_$profileId"

    actual fun loadPayload(profileId: Int): String? =
        AppleFileStringStorage.load(payloadKey(profileId))

    actual fun savePayload(profileId: Int, payload: String) {
        AppleFileStringStorage.save(payloadKey(profileId), payload)
    }
}
