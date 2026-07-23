package com.nuvio.app.features.profiles

import com.nuvio.app.core.storage.AppleFileStringStorage

actual object AvatarStorage {
    private const val payloadKey = "avatar_catalog_payload"

    actual fun loadPayload(): String? =
        AppleFileStringStorage.load(payloadKey)

    actual fun savePayload(payload: String) {
        AppleFileStringStorage.save(payloadKey, payload)
    }
}
