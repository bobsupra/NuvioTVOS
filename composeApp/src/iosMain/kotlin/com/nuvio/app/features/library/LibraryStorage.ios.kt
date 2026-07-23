package com.nuvio.app.features.library

import com.nuvio.app.core.storage.AppleFileStringStorage

actual object LibraryStorage {
    private fun payloadKey(profileId: Int) = "library_payload_$profileId"

    actual fun loadPayload(profileId: Int): String? =
        AppleFileStringStorage.load(payloadKey(profileId))

    actual fun savePayload(profileId: Int, payload: String) {
        AppleFileStringStorage.save(payloadKey(profileId), payload)
    }
}
