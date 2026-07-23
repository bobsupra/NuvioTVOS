package com.nuvio.app.features.trakt

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

internal actual object TraktSettingsStorage {
    private const val payloadKey = "trakt_settings_payload"

    actual fun loadPayload(): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(payloadKey), payload)
    }
}
