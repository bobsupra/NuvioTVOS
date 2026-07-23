package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.storage.AppleFileStringStorage

actual object ContinueWatchingEnrichmentStorage {
    actual fun loadPayload(key: String): String? =
        AppleFileStringStorage.load(key)

    actual fun savePayload(key: String, payload: String) {
        AppleFileStringStorage.save(key, payload)
    }

    actual fun removePayload(key: String) {
        AppleFileStringStorage.remove(key)
    }
}
