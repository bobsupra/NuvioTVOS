package com.nuvio.app.features.plugins

import com.nuvio.app.core.storage.AppleFileStringStorage
import platform.Foundation.timeIntervalSince1970

internal object PluginStorage {
    private const val pluginsStateKey = "plugins_state"

    fun loadState(profileId: Int): String? =
        AppleFileStringStorage.load("${pluginsStateKey}_$profileId")

    fun saveState(profileId: Int, payload: String) {
        AppleFileStringStorage.save("${pluginsStateKey}_$profileId", payload)
    }

    fun loadScraperSettings(scraperId: String): String? =
        AppleFileStringStorage.load("settings_${scraperId}")

    fun saveScraperSettings(scraperId: String, payload: String) {
        AppleFileStringStorage.save("settings_${scraperId}", payload)
    }
}

internal fun currentPluginPlatform(): String = "ios"

internal fun currentEpochMillis(): Long =
    (platform.Foundation.NSDate().timeIntervalSince1970 * 1000.0).toLong()
