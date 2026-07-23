package com.nuvio.app.core.ui

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

actual object PosterCardStyleStorage {
    private const val payloadKey = "poster_card_style_payload"

    actual fun loadPayload(): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(payloadKey))

    actual fun savePayload(payload: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(payloadKey), payload)
    }
}
