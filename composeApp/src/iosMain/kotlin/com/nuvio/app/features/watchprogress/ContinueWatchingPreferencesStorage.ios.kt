package com.nuvio.app.features.watchprogress

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

actual object ContinueWatchingPreferencesStorage {
    private const val payloadKey = "continue_watching_preferences_payload"

    actual fun loadPayload(): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(payloadKey), payload)
    }
}
