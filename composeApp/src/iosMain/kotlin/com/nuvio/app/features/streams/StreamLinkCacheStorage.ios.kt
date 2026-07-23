package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

actual object StreamLinkCacheStorage {
    actual fun loadEntry(hashedKey: String): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(hashedKey))

    actual fun saveEntry(hashedKey: String, payload: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(hashedKey), payload)
    }

    actual fun removeEntry(hashedKey: String) {
        AppleFileStringStorage.remove(ProfileScopedKey.of(hashedKey))
    }
}
