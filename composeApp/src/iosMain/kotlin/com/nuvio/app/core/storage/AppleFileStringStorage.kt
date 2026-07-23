package com.nuvio.app.core.storage

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.usePinned
import platform.Foundation.NSBundle
import platform.Foundation.NSFileManager
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSUserDefaults
import platform.posix.SEEK_END
import platform.posix.fclose
import platform.posix.fopen
import platform.posix.fread
import platform.posix.fseek
import platform.posix.ftell
import platform.posix.fwrite
import platform.posix.rename
import platform.posix.rewind
import platform.posix.unlink

/**
 * File-backed storage for payloads that are too large or too numerous for tvOS UserDefaults.
 *
 * Values are stored separately so they do not contribute to tvOS's 1 MB defaults-database
 * termination threshold. The first access also migrates every known legacy bulk value in one
 * pass, which makes already-oversized installations safe before their next defaults write.
 */
@OptIn(ExperimentalForeignApi::class)
internal object AppleFileStringStorage {
    private const val storageDirectoryName = "nuvio_payloads"
    private const val fileExtension = ".data"

    private val lock = SynchronizedObject()
    private var legacyMigrationAttempted = false

    fun load(key: String): String? = synchronized(lock) {
        migrateLegacyValuesIfNeeded()
        readFile(pathForKey(key))
            ?: NSUserDefaults.standardUserDefaults.stringForKey(key)
    }

    fun save(key: String, value: String) = synchronized(lock) {
        migrateLegacyValuesIfNeeded()
        if (writeFile(pathForKey(key), value)) {
            // Handles values written by an older app version after the one-time migration.
            val defaults = NSUserDefaults.standardUserDefaults
            if (defaults.objectForKey(key) != null) {
                defaults.removeObjectForKey(key)
            }
        }
    }

    fun remove(key: String) = synchronized(lock) {
        migrateLegacyValuesIfNeeded()
        removeFile(pathForKey(key))
        val defaults = NSUserDefaults.standardUserDefaults
        if (defaults.objectForKey(key) != null) {
            defaults.removeObjectForKey(key)
        }
    }

    fun wipe() = synchronized(lock) {
        val path = storageDirectoryPath()
        if (NSFileManager.defaultManager.fileExistsAtPath(path)) {
            NSFileManager.defaultManager.removeItemAtPath(path, error = null)
        }
        removeLegacyValuesFromDefaults()
        legacyMigrationAttempted = true
    }

    private fun migrateLegacyValuesIfNeeded() {
        if (legacyMigrationAttempted) return
        legacyMigrationAttempted = true

        val defaults = NSUserDefaults.standardUserDefaults
        val domainName = NSBundle.mainBundle.bundleIdentifier ?: return
        val domain = defaults.persistentDomainForName(domainName) ?: return
        val migratedKeys = mutableSetOf<String>()

        domain.forEach { (rawKey, rawValue) ->
            val key = rawKey as? String ?: return@forEach
            val value = rawValue as? String ?: return@forEach
            if (!isLegacyBulkKey(key)) return@forEach

            val path = pathForKey(key)
            if (
                NSFileManager.defaultManager.fileExistsAtPath(path) ||
                writeFile(path, value)
            ) {
                migratedKeys += key
            }
        }

        if (migratedKeys.isEmpty()) return

        // Replace the app domain once with the smaller dictionary. Removing legacy values one at
        // a time could itself trigger tvOS's size-limit abort while the domain remains oversized.
        val retainedDomain = domain.filterKeys { rawKey ->
            (rawKey as? String) !in migratedKeys
        }
        defaults.setPersistentDomain(retainedDomain, forName = domainName)
    }

    private fun removeLegacyValuesFromDefaults() {
        val defaults = NSUserDefaults.standardUserDefaults
        val domainName = NSBundle.mainBundle.bundleIdentifier ?: return
        val domain = defaults.persistentDomainForName(domainName) ?: return
        if (domain.keys.none { rawKey -> (rawKey as? String)?.let(::isLegacyBulkKey) == true }) return

        val retainedDomain = domain.filterKeys { rawKey ->
            (rawKey as? String)?.let(::isLegacyBulkKey) != true
        }
        defaults.setPersistentDomain(retainedDomain, forName = domainName)
    }

    private fun isLegacyBulkKey(key: String): Boolean =
        key == "profile_payload" ||
            key == "avatar_catalog_payload" ||
            key.startsWith("installed_manifest_urls_") ||
            key.startsWith("installed_manifest_enabled_states_") ||
            key.startsWith("plugins_state_") ||
            key.startsWith("settings_") ||
            key.startsWith("library_payload_") ||
            key.startsWith("watched_payload_") ||
            key.startsWith("watch_progress_payload_") ||
            key.startsWith("downloads_payload_") ||
            key.startsWith("collections_payload_") ||
            key.startsWith("collection_mobile_settings_payload_") ||
            key.startsWith("catalog_settings_payload_") ||
            key.startsWith("continue_watching_preferences_payload_") ||
            key.startsWith("meta_screen_settings_payload_") ||
            key.startsWith("poster_card_style_payload_") ||
            key.startsWith("search_history_payload_") ||
            key.startsWith("trakt_auth_payload_") ||
            key.startsWith("trakt_library_payload_") ||
            key.startsWith("trakt_settings_payload_") ||
            key.startsWith("episode_release_notifications_payload_") ||
            key.startsWith("stream_badge_rules_") ||
            key.startsWith("debrid_stream_badge_rules_") ||
            key.startsWith("cw_enrichment_cache_") ||
            key.startsWith("stream_link_") ||
            key.startsWith("binge_group_") ||
            key == "nuvio_sync_backend_selection_payload_v1"

    private fun pathForKey(key: String): String =
        "${storageDirectoryPath()}/${fileNameForKey(key)}$fileExtension"

    private fun storageDirectoryPath(): String {
        val path = "${NSHomeDirectory().trimEnd('/')}/Library/Application Support/$storageDirectoryName"
        NSFileManager.defaultManager.createDirectoryAtPath(
            path = path,
            withIntermediateDirectories = true,
            attributes = null,
            error = null,
        )
        return path
    }

    private fun fileNameForKey(key: String): String {
        val readablePrefix = buildString {
            key.take(80).forEach { character ->
                if (character.isLetterOrDigit() || character == '-' || character == '_' || character == '.') {
                    append(character)
                } else {
                    append('_')
                }
            }
        }
        val hash = key.fold(14695981039346656037UL) { current, character ->
            (current xor character.code.toULong()) * 1099511628211UL
        }
        return "$readablePrefix-${hash.toString(16)}"
    }

    @OptIn(ExperimentalForeignApi::class)
    private fun readFile(path: String): String? {
        val file = fopen(path, "rb") ?: return null
        return try {
            if (fseek(file, 0, SEEK_END) != 0) return null
            val length = ftell(file)
            if (length < 0 || length > Int.MAX_VALUE) return null
            rewind(file)

            val bytes = ByteArray(length.toInt())
            if (bytes.isNotEmpty()) {
                val bytesRead = bytes.usePinned { pinned ->
                    fread(pinned.addressOf(0), 1.convert(), bytes.size.convert(), file).toLong()
                }
                if (bytesRead != bytes.size.toLong()) return null
            }
            bytes.decodeToString()
        } finally {
            fclose(file)
        }
    }

    @OptIn(ExperimentalForeignApi::class)
    private fun writeFile(path: String, value: String): Boolean {
        val temporaryPath = "$path.tmp"
        val file = fopen(temporaryPath, "wb") ?: return false
        val bytes = value.encodeToByteArray()
        val wroteAllBytes = try {
            if (bytes.isEmpty()) {
                true
            } else {
                bytes.usePinned { pinned ->
                    fwrite(pinned.addressOf(0), 1.convert(), bytes.size.convert(), file).toLong() ==
                        bytes.size.toLong()
                }
            }
        } finally {
            fclose(file)
        }

        if (!wroteAllBytes) {
            unlink(temporaryPath)
            return false
        }

        if (rename(temporaryPath, path) != 0) {
            unlink(temporaryPath)
            return false
        }
        return true
    }

    @OptIn(ExperimentalForeignApi::class)
    private fun removeFile(path: String) {
        unlink(path)
        unlink("$path.tmp")
    }
}
