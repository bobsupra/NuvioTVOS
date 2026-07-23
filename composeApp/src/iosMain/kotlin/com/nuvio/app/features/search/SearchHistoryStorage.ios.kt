package com.nuvio.app.features.search

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

actual object SearchHistoryStorage {
    private const val payloadKey = "search_history_payload"

    actual fun loadPayload(): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(payloadKey), payload)
    }
}
