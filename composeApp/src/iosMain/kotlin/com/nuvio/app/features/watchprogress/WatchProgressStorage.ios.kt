package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.storage.AppleFileStringStorage

actual object WatchProgressStorage {
    private const val payloadKey = "watch_progress_payload"

    actual fun loadPayload(profileId: Int): String? =
        AppleFileStringStorage.load("${payloadKey}_$profileId")

    actual fun savePayload(profileId: Int, payload: String) {
        AppleFileStringStorage.save("${payloadKey}_$profileId", payload)
    }
}
