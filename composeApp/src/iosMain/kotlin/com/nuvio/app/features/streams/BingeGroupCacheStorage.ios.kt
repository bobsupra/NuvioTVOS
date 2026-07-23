package com.nuvio.app.features.streams

import com.nuvio.app.core.storage.AppleFileStringStorage
import com.nuvio.app.core.storage.ProfileScopedKey

actual object BingeGroupCacheStorage {
    actual fun load(hashedKey: String): String? =
        AppleFileStringStorage.load(ProfileScopedKey.of(hashedKey))

    actual fun save(hashedKey: String, value: String) {
        AppleFileStringStorage.save(ProfileScopedKey.of(hashedKey), value)
    }

    actual fun remove(hashedKey: String) {
        AppleFileStringStorage.remove(ProfileScopedKey.of(hashedKey))
    }
}
