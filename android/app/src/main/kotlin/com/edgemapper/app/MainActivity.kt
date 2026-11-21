package com.edgemapper.app

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.credentials.CreateCredentialException
import android.credentials.CreateCredentialRequest
import android.credentials.CreateCredentialResponse
import android.credentials.CredentialManager
import android.credentials.CredentialOption
import android.credentials.GetCredentialException
import android.credentials.GetCredentialRequest
import android.credentials.GetCredentialResponse
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import android.os.PersistableBundle
import android.provider.OpenableColumns
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.text.InputType
import android.util.Base64
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.autofill.AutofillManager
import android.widget.EditText
import android.widget.LinearLayout
import com.edgemapper.attestation.AttestGateAppCheckProviderFactory
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.FirebaseAppCheck
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.PSource
import javax.crypto.spec.SecretKeySpec
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

class MainActivity : FlutterActivity() {
    companion object {
        private const val COMPASS_CHANNEL = "com.edgemapper.app/compass"
        private const val GEMINI_NANO_CHANNEL = "com.edgemapper.app/gemini_nano"
        private const val BROWSER_CHANNEL = "com.edgemapper.app/browser"
        private const val PHOTO_CHANNEL = "com.edgemapper.app/photo"
        private const val FILE_PICKER_CHANNEL = "com.edgemapper.app/file_picker"
        private const val SECURE_VAULT_CHANNEL = "com.edgemapper.app/secure_vault"
        private const val PASSWORD_MANAGER_CHANNEL = "com.edgemapper.app/password_manager"
        private const val E2EE_KEYSTORE_CHANNEL = "com.edgemapper.app/e2ee_keystore"
        private const val TRAIL_BG_CHANNEL = "com.edgemapper.app/trail_background"
        private const val PICK_GPS_FILE_REQUEST_CODE = 42089
        private const val OS_AUTH_REQUEST_CODE = 42090
        private const val POST_NOTIFICATIONS_REQUEST_CODE = 42091
        private const val MAX_GPS_FILE_BYTES = 12 * 1024 * 1024
        private const val MIN_VAULT_PASSPHRASE_LENGTH = 12
        private const val VAULT_AES_KEY_ALIAS = "edge_mapper_vault_aes256_gcm_v1"
        private const val VAULT_BIOMETRIC_AES_KEY_ALIAS = "edge_mapper_vault_biometric_aes256_gcm_v2"
        private const val VAULT_PREFS_NAME = "edge_mapper_secure_vault_v1"
        private const val E2EE_USER_PRIV_KEY_ALIAS = "edge_mapper_user_priv_cache_aes256_gcm_v1"
        private const val E2EE_USER_PRIV_BIO_RSA_ALIAS = "edge_mapper_user_priv_bio_rsa_v2"
        private const val E2EE_USER_PRIV_PREFS_NAME = "edge_mapper_e2ee_user_priv_cache_v1"
        private const val AICORE_PACKAGE = "com.google.android.aicore"
        private const val CHANNEL = "dev.attestgate/app_check"

        @Volatile
        private var installedAttestGateUrl: String? = null
    }

    private val photoExecutor: ExecutorService = Executors.newFixedThreadPool(2)
    private var browserChannel: MethodChannel? = null
    private var pendingOAuthCallbackUrl: String? = null
    private var awaitingOAuthReturn: Boolean = false
    private var leftActivityForOAuth: Boolean = false
    private var pendingFilePickerResult: MethodChannel.Result? = null
    private var pendingOsAuthCallback: ((Boolean, String?) -> Unit)? = null
    private var vaultUnlockedForSession: Boolean = false
    private var activePassphraseKey: SecretKey? = null
    private var activeBiometricDek: SecretKey? = null
    private var cachedVaultJson: String? = null

    private fun resolveFirebaseApp(): FirebaseApp? {
        return runCatching { FirebaseApp.getInstance() }.getOrNull()
            ?: FirebaseApp.initializeApp(this)
    }

    private fun isDebuggableBuild(): Boolean =
        (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun isAllowedExternalUri(uri: Uri): Boolean {
        return when (uri.scheme?.lowercase()) {
            "https", "bitcoin", "lightning" -> true
            "http" -> {
                val host = uri.host?.lowercase().orEmpty()
                host == "localhost" || host == "127.0.0.1" || host.endsWith(".onion")
            }
            else -> false
        }
    }

    private fun installAttestGateProviderIfNeeded(baseUrl: String): Boolean {
        val cleanUrl = baseUrl.trim().trimEnd('/')
        if (cleanUrl.isEmpty()) return false
        val parsed = Uri.parse(cleanUrl)
        if (!parsed.scheme.equals("https", ignoreCase = true) || parsed.host.isNullOrBlank()) {
            return false
        }
        val app = resolveFirebaseApp() ?: return false
        if (installedAttestGateUrl == cleanUrl) return true
        // Keep token auto-refresh DISABLED when using AttestGate: limited-use tokens
        // have a 5-minute (299s) TTL which is <= Firebase SDK's 5-minute refresh buffer,
        // causing TokenRefreshManager to spin in a tight loop and trigger HTTP 429.
        FirebaseAppCheck.getInstance(app).installAppCheckProviderFactory(
            AttestGateAppCheckProviderFactory(cleanUrl),
            false,
        )
        installedAttestGateUrl = cleanUrl
        if (isDebuggableBuild()) {
            Log.i("AttestGateProvider", "Installed AttestGateAppCheckProviderFactory (app=${app.name})")
        }
        return true
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Native Compass Stream (zero third-party Gradle namespace issues)
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            COMPASS_CHANNEL
        ).setStreamHandler(CompassStreamHandler(applicationContext))

        // 2. Native Gemini Nano / AICore Bridge
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GEMINI_NANO_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAvailability" -> {
                    result.success(checkGeminiNanoAvailability())
                }
                "generateOsmDraft" -> {
                    // Hook for ML Kit GenAI Prompt API / AICore on supported devices (Pixel 8/9+).
                    // Pixel 6a (Tensor G1, 6GB RAM) does not support AICore Gemini Nano,
                    // so we report unsupported cleanly and let Dart route to ML Kit Vision + OCR.
                    val status = checkGeminiNanoAvailability()
                    result.success(
                        mapOf(
                            "supported" to false,
                            "reason" to (status["reason"] ?: "Gemini Nano prompt runtime unavailable on this device.")
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }

        // 3. External Browser URL Launcher & Automatic OSM OAuth 2.0 Deep-Link Callback
        val bChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BROWSER_CHANNEL
        )
        browserChannel = bChannel
        bChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val parsed = Uri.parse(url.trim())
                        if (!isAllowedExternalUri(parsed)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(Intent.ACTION_VIEW, parsed).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "launchOAuth" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val parsed = Uri.parse(url.trim())
                        if (!parsed.scheme.equals("https", ignoreCase = true) || parsed.host.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        pendingOAuthCallbackUrl = null
                        awaitingOAuthReturn = true
                        leftActivityForOAuth = false
                        val intent = Intent(Intent.ACTION_VIEW, parsed).apply {
                            addCategory(Intent.CATEGORY_BROWSABLE)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        awaitingOAuthReturn = false
                        leftActivityForOAuth = false
                        result.success(false)
                    }
                }
                "cancelOAuth" -> {
                    awaitingOAuthReturn = false
                    leftActivityForOAuth = false
                    pendingOAuthCallbackUrl = null
                    result.success(true)
                }
                "consumePendingOAuthCallback" -> {
                    val url = pendingOAuthCallbackUrl
                    pendingOAuthCallbackUrl = null
                    result.success(url)
                }
                else -> result.notImplemented()
            }
        }
        captureOAuthCallbackIntent(intent, deliverNow = false)

        // 4. Native RAM-safe JPEG Photo Compression for Firebase Cross-Device Sync
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PHOTO_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "compressToJpegBytes") {
                val path = call.argument<String>("path")
                val rawMaxBytes = call.argument<Int>("maxBytes") ?: (420 * 1024)
                val maxBytes = rawMaxBytes.coerceIn(32 * 1024, 10 * 1024 * 1024)
                if (path.isNullOrBlank() || !isAllowedPhotoPath(path)) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                photoExecutor.execute {
                    val compressed = compressImageFileToJpeg(path, maxBytes)
                    runOnUiThread { result.success(compressed) }
                }
            } else {
                result.notImplemented()
            }
        }

        // 5. Native Storage Access Framework Document Picker for External Ham Radio GPS Logs
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_PICKER_CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "pickTextFile") {
                pendingFilePickerResult?.success(null)
                pendingFilePickerResult = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, PICK_GPS_FILE_REQUEST_CODE)
                } catch (e: Exception) {
                    pendingFilePickerResult = null
                    result.error("PICKER_FAILED", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }

        // 7. OS-Encrypted Secrets Vault (AndroidKeyStore StrongBox/TEE AES-256-GCM + Biometric/Device Lock + PBKDF2 Passphrase)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_VAULT_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    result.success(getAndroidVaultStatus())
                }
                "readAllSecrets" -> {
                    try {
                        result.success(readAndroidVaultSecrets())
                    } catch (e: Exception) {
                        result.error("VAULT_READ_FAILED", e.message, null)
                    }
                }
                "writeSecrets" -> {
                    val json = call.argument<String>("secretsJson") ?: "{}"
                    try {
                        writeAndroidVaultSecrets(json)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("VAULT_WRITE_FAILED", e.message, null)
                    }
                }
                "enableOsBiometricLock" -> {
                    enableHardwareBiometricVault(result)
                }
                "unlockWithOsBiometric" -> {
                    unlockHardwareBiometricVault(result)
                }
                "enablePassphrase" -> {
                    if (isVaultCurrentlyLocked()) {
                        result.error("VAULT_LOCKED", "Unlock the vault before changing protection mode.", null)
                        return@setMethodCallHandler
                    }
                    val passphrase = call.argument<String>("passphrase") ?: ""
                    if (passphrase.length < MIN_VAULT_PASSPHRASE_LENGTH) {
                        result.error(
                            "WEAK_PASSPHRASE",
                            "Passphrase must be at least $MIN_VAULT_PASSPHRASE_LENGTH characters.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val current = cachedVaultJson ?: decryptKeystoreVaultPayload() ?: "{}"
                            val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
                            val key = derivePbkdf2Key(passphrase, salt)
                            val (ivB64, ctB64) = encryptWithSecretKey(key, current)
                            val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
                            prefs.edit()
                                .putString("mode", "passphrase")
                                .putString("salt", Base64.encodeToString(salt, Base64.NO_WRAP))
                                .putString("iv", ivB64)
                                .putString("ct", ctB64)
                                .remove("key_type")
                                .remove("wrapped_dek_iv")
                                .remove("wrapped_dek_ct")
                                .apply()
                            deleteKeystoreAliasQuietly(VAULT_AES_KEY_ALIAS)
                            deleteKeystoreAliasQuietly(VAULT_BIOMETRIC_AES_KEY_ALIAS)
                            activePassphraseKey = key
                            activeBiometricDek = null
                            vaultUnlockedForSession = true
                            cachedVaultJson = current
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PASSPHRASE_FAILED", e.message, null) }
                        }
                    }.start()
                }
                "unlockWithPassphrase" -> {
                    val passphrase = call.argument<String>("passphrase") ?: ""
                    Thread {
                        try {
                            val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
                            val saltB64 = prefs.getString("salt", null)
                                ?: throw IllegalStateException("No passphrase vault configured.")
                            val ivB64 = prefs.getString("iv", null) ?: ""
                            val ctB64 = prefs.getString("ct", null) ?: ""
                            val salt = Base64.decode(saltB64, Base64.NO_WRAP)
                            val key = derivePbkdf2Key(passphrase, salt)
                            val plain = if (ctB64.isEmpty()) "{}" else decryptWithSecretKey(key, ivB64, ctB64)
                            activePassphraseKey = key
                            activeBiometricDek = null
                            vaultUnlockedForSession = true
                            cachedVaultJson = plain
                            runOnUiThread { result.success(plain) }
                        } catch (_: Exception) {
                            runOnUiThread {
                                result.error("BAD_PASSPHRASE", "Incorrect vault passphrase.", null)
                            }
                        }
                    }.start()
                }
                "switchToOsKeystore" -> {
                    if (isVaultCurrentlyLocked()) {
                        result.error("VAULT_LOCKED", "Unlock the vault before changing protection mode.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val current = cachedVaultJson ?: decryptKeystoreVaultPayload() ?: "{}"
                        val (ivB64, ctB64) = encryptWithKeystoreAes(current)
                        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
                        prefs.edit()
                            .putString("mode", "os_keystore")
                            .putString("iv", ivB64)
                            .putString("ct", ctB64)
                            .remove("salt")
                            .remove("key_type")
                            .remove("wrapped_dek_iv")
                            .remove("wrapped_dek_ct")
                            .apply()
                        deleteKeystoreAliasQuietly(VAULT_BIOMETRIC_AES_KEY_ALIAS)
                        activePassphraseKey = null
                        activeBiometricDek = null
                        vaultUnlockedForSession = true
                        cachedVaultJson = current
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SWITCH_FAILED", e.message, null)
                    }
                }
                "lock" -> {
                    vaultUnlockedForSession = false
                    activePassphraseKey = null
                    activeBiometricDek = null
                    cachedVaultJson = null
                    result.success(true)
                }
                "e2eeEncrypt" -> {
                    var keyBytes: ByteArray? = null
                    var plainBytes: ByteArray? = null
                    try {
                        keyBytes = Base64.decode(call.argument<String>("keyB64") ?: "", Base64.NO_WRAP)
                        plainBytes = Base64.decode(call.argument<String>("plainB64") ?: "", Base64.NO_WRAP)
                        val aadBytes = Base64.decode(call.argument<String>("aadB64") ?: "", Base64.NO_WRAP)
                        require(keyBytes.size == 32) { "AES-256-GCM requires a 32-byte key." }
                        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, iv))
                        if (aadBytes.isNotEmpty()) cipher.updateAAD(aadBytes)
                        val ct = cipher.doFinal(plainBytes)
                        result.success(
                            mapOf(
                                "ivB64" to Base64.encodeToString(iv, Base64.NO_WRAP),
                                "ctB64" to Base64.encodeToString(ct, Base64.NO_WRAP)
                            )
                        )
                    } catch (e: Exception) {
                        result.error("E2EE_ENCRYPT_FAILED", e.message, null)
                    } finally {
                        keyBytes?.fill(0)
                        plainBytes?.fill(0)
                    }
                }
                "e2eeDecrypt" -> {
                    var keyBytes: ByteArray? = null
                    var plain: ByteArray? = null
                    try {
                        keyBytes = Base64.decode(call.argument<String>("keyB64") ?: "", Base64.NO_WRAP)
                        val ivBytes = Base64.decode(call.argument<String>("ivB64") ?: "", Base64.NO_WRAP)
                        val ctBytes = Base64.decode(call.argument<String>("ctB64") ?: "", Base64.NO_WRAP)
                        val aadBytes = Base64.decode(call.argument<String>("aadB64") ?: "", Base64.NO_WRAP)
                        require(keyBytes.size == 32) { "AES-256-GCM requires a 32-byte key." }
                        require(ivBytes.size == 12) { "AES-256-GCM requires a 12-byte IV." }
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, ivBytes))
                        if (aadBytes.isNotEmpty()) cipher.updateAAD(aadBytes)
                        plain = cipher.doFinal(ctBytes)
                        result.success(Base64.encodeToString(plain, Base64.NO_WRAP))
                    } catch (e: Exception) {
                        result.error("E2EE_DECRYPT_FAILED", e.message, null)
                    } finally {
                        keyBytes?.fill(0)
                        plain?.fill(0)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 8. Native Android Credential Manager & Autofill Bridge (Bitwarden, KeePassDX, Proton Pass, etc.)
        // Invokes the system Credential Provider / Autofill service directly — NEVER copies to clipboard.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PASSWORD_MANAGER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveSyncKey" -> {
                    val label = call.argument<String>("label")?.trim().orEmpty()
                        .ifEmpty { "Edge Mapper Sync Key" }
                    val syncKey = call.argument<String>("syncKey")?.trim().orEmpty()
                    if (syncKey.isEmpty()) {
                        result.success(
                            mapOf(
                                "prompted" to false,
                                "saved" to false,
                                "message" to "No Sync Key to save."
                            )
                        )
                        return@setMethodCallHandler
                    }
                    saveSyncKeyToAndroidPasswordManager(label, syncKey, result)
                }
                "retrieveSyncKey" -> {
                    retrieveSyncKeyFromAndroidPasswordManager(result)
                }
                "copySensitive" -> {
                    val text = call.argument<String>("text") ?: ""
                    result.success(copySensitiveToClipboard(text))
                }
                else -> result.notImplemented()
            }
        }

        // 9. Local Hardware Caching for E2EE User_Priv (Android Keystore AES-256-GCM,
        //    AES/GCM/NoPadding, setRandomizedEncryptionRequired(true), TEE/StrongBox)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            E2EE_KEYSTORE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStatus" -> {
                    result.success(
                        mapOf(
                            "supported" to true,
                            "detail" to "Android Keystore AES-256-GCM (StrongBox/TEE, randomized IV)"
                        )
                    )
                }
                "cacheUserPriv" -> {
                    val uid = call.argument<String>("uid")?.trim().orEmpty()
                    val userPrivB64 = call.argument<String>("userPrivB64")?.trim().orEmpty()
                    val authSeedB64 = call.argument<String>("authSeedB64")?.trim().orEmpty()
                    if (uid.isEmpty() || userPrivB64.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val rawPriv = Base64.decode(userPrivB64, Base64.NO_WRAP)
                        val rawSeed = if (authSeedB64.isNotEmpty()) Base64.decode(authSeedB64, Base64.NO_WRAP) else null
                        try {
                            val ok = cacheE2eeUserPrivInKeystore(uid, rawPriv, rawSeed)
                            result.success(ok)
                        } finally {
                            rawPriv.fill(0)
                            rawSeed?.fill(0)
                        }
                    } catch (e: Exception) {
                        result.error("KEYSTORE_CACHE_FAILED", e.message, null)
                    }
                }
                "loadCachedUserPriv" -> {
                    val requestedUid = call.argument<String>("uid")?.trim().orEmpty()
                    try {
                        val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
                        // Never allow unauthenticated unwrap when biometric-bound RSA-OAEP is stored.
                        if (prefs.getString("key_type", "") == "biometric_rsa_oaep") {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val loaded = loadE2eeUserPrivFromKeystore(requestedUid.ifEmpty { null })
                        if (loaded == null) {
                            result.success(null)
                        } else {
                            val (uid, priv, seed) = loaded
                            try {
                                result.success(
                                    mapOf(
                                        "uid" to uid,
                                        "userPrivB64" to Base64.encodeToString(priv, Base64.NO_WRAP),
                                        "authSeedB64" to (seed?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: "")
                                    )
                                )
                            } finally {
                                priv.fill(0)
                                seed?.fill(0)
                            }
                        }
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
                "unlockCachedUserPrivWithBiometric" -> {
                    val requestedUid = call.argument<String>("uid")?.trim().orEmpty()
                    val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    if (!km.isDeviceSecure) {
                        result.error(
                            "NO_DEVICE_LOCK",
                            "Set up a fingerprint or screen lock in Android Settings first.",
                            null
                        )
                        return@setMethodCallHandler
                    }
                    unlockE2eeUserPrivHardwareBiometric(requestedUid.ifEmpty { null }, result)
                }
                "hasCachedUserPriv" -> {
                    val requestedUid = call.argument<String>("uid")?.trim().orEmpty()
                    val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
                    val storedUid = prefs.getString("uid", null)
                    val hasCt = !prefs.getString("ct", null).isNullOrEmpty()
                    val matchesUid = requestedUid.isEmpty() || storedUid == requestedUid
                    result.success(!storedUid.isNullOrEmpty() && matchesUid && hasCt)
                }
                "clearCachedUserPriv" -> {
                    val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
                    prefs.edit().clear().apply()
                    deleteKeystoreAliasQuietly(E2EE_USER_PRIV_KEY_ALIAS)
                    deleteKeystoreAliasQuietly(E2EE_USER_PRIV_BIO_RSA_ALIAS)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // 10. Android 13+ Notification permission helper for background trail recording foreground service
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TRAIL_BG_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        val perm = android.Manifest.permission.POST_NOTIFICATIONS
                        if (checkSelfPermission(perm) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(perm), POST_NOTIFICATIONS_REQUEST_CODE)
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installProvider" -> {
                        val baseUrl = call.argument<String>("baseUrl")
                        if (baseUrl.isNullOrBlank()) {
                            result.error("INVALID_ARGS", "Missing required argument 'baseUrl'", null)
                            return@setMethodCallHandler
                        }
                        if (!installAttestGateProviderIfNeeded(baseUrl)) {
                            result.error(
                                "FIREBASE_NOT_INITIALIZED",
                                "Default FirebaseApp is not initialized.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        result.success(null)
                    }

                    "getToken" -> {
                        val app = resolveFirebaseApp()
                        if (app == null) {
                            result.error(
                                "FIREBASE_NOT_INITIALIZED",
                                "Default FirebaseApp is not initialized.",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        if (installedAttestGateUrl == null) {
                            result.error(
                                "PROVIDER_NOT_INSTALLED",
                                "AttestGate App Check provider is not configured (set ATTEST_GATE_BASE_URL in .env).",
                                null,
                            )
                            return@setMethodCallHandler
                        }
                        val forceRefresh = call.argument<Boolean>("forceRefresh") ?: false
                        FirebaseAppCheck.getInstance(app)
                            .getAppCheckToken(forceRefresh)
                            .addOnSuccessListener { token ->
                                result.success(
                                    mapOf(
                                        "token" to token.token,
                                        "expireTimeMillis" to token.expireTimeMillis,
                                    ),
                                )
                            }
                            .addOnFailureListener { err ->
                                result.error(
                                    "ATTESTATION_FAILED",
                                    err.message ?: "Hardware attestation failed",
                                    null,
                                )
                            }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureOAuthCallbackIntent(intent, deliverNow = true)
    }

    override fun onPause() {
        super.onPause()
        if (awaitingOAuthReturn) {
            leftActivityForOAuth = true
        }
    }

    override fun onResume() {
        super.onResume()
        if (awaitingOAuthReturn && leftActivityForOAuth) {
            leftActivityForOAuth = false
            window?.decorView?.postDelayed({
                if (awaitingOAuthReturn) {
                    awaitingOAuthReturn = false
                    browserChannel?.invokeMethod("onOAuthCancelled", null)
                }
            }, 900L)
        }
    }

    private fun captureOAuthCallbackIntent(intent: Intent?, deliverNow: Boolean = true) {
        val uri = intent?.data ?: return
        if (uri.scheme == "edgemapper" && uri.host == "oauth2" && uri.path == "/callback") {
            val url = uri.toString()
            awaitingOAuthReturn = false
            leftActivityForOAuth = false
            val ch = browserChannel
            if (deliverNow && ch != null) {
                pendingOAuthCallbackUrl = null
                runOnUiThread {
                    ch.invokeMethod("onOAuthCallback", url)
                }
            } else {
                pendingOAuthCallbackUrl = url
            }
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == OS_AUTH_REQUEST_CODE) {
            val cb = pendingOsAuthCallback
            pendingOsAuthCallback = null
            cb?.invoke(resultCode == Activity.RESULT_OK, if (resultCode == Activity.RESULT_OK) null else "Screen lock verification cancelled.")
            return
        }
        if (requestCode == PICK_GPS_FILE_REQUEST_CODE) {
            val callback = pendingFilePickerResult
            pendingFilePickerResult = null
            if (callback == null) return
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            if (uri == null) {
                callback.success(null)
                return
            }
            Thread {
                try {
                    val fileName = resolveDocumentName(uri) ?: "radio_track.log"
                    val content = readTextFromUri(uri)
                    runOnUiThread {
                        if (content == null) {
                            callback.error(
                                "FILE_TOO_LARGE",
                                "Selected GPS log exceeds 12 MB limit.",
                                null
                            )
                        } else {
                            callback.success(
                                mapOf("fileName" to fileName, "content" to content)
                            )
                        }
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        callback.error("READ_FAILED", e.message, null)
                    }
                }
            }.start()
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun resolveDocumentName(uri: Uri): String? {
        val raw = try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (_: Exception) {
            uri.lastPathSegment
        } ?: return null
        val base = raw.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\x00-\\x1F\\x7F]"), "")
            .replace("..", "")
            .trim()
        return base.ifEmpty { null }
    }

    private fun readTextFromUri(uri: Uri): String? {
        contentResolver.openInputStream(uri)?.use { input ->
            val baos = ByteArrayOutputStream()
            val buf = ByteArray(16 * 1024)
            var total = 0
            while (true) {
                val read = input.read(buf)
                if (read <= 0) break
                total += read
                if (total > MAX_GPS_FILE_BYTES) return null
                baos.write(buf, 0, read)
            }
            return baos.toString(Charsets.UTF_8.name())
        }
        return ""
    }

    private fun getAndroidVaultStatus(): Map<String, Any> {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString("mode", "os_keystore") ?: "os_keystore"
        val keyType = prefs.getString("key_type", "") ?: ""
        val hasCipher = !prefs.getString("ct", null).isNullOrEmpty()
        val locked = when (mode) {
            "os_biometric" -> {
                if (keyType == "biometric_crypto") activeBiometricDek == null
                else !vaultUnlockedForSession
            }
            "passphrase" -> activePassphraseKey == null
            else -> false
        }
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val canOsAuth = km.isDeviceSecure
        val detail = when {
            mode == "os_biometric" && keyType == "biometric_crypto" ->
                "Hardware StrongBox/TEE Biometric CryptoObject AES-256-GCM (fingerprint required to unwrap key)"
            mode == "os_biometric" ->
                "Hardware AndroidKeyStore AES-256-GCM gated by OS Biometrics / Screen Lock"
            mode == "passphrase" ->
                "PBKDF2-SHA-256 (600k iterations) + AES-256-GCM vault passphrase (Bitwarden-compatible)"
            else ->
                "Hardware-backed AndroidKeyStore AES-256-GCM (StrongBox / TEE)"
        }
        return mapOf(
            "mode" to mode,
            "isLocked" to locked,
            "hasStoredSecrets" to hasCipher,
            "supportsPasskeyPrf" to false,
            "supportsOsBiometric" to canOsAuth,
            "credentialLabel" to if (mode == "os_biometric") "Android Hardware Fingerprint / Biometrics" else "",
            "detail" to detail
        )
    }

    private fun readAndroidVaultSecrets(): Map<String, Any> {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString("mode", "os_keystore") ?: "os_keystore"
        val keyType = prefs.getString("key_type", "") ?: ""
        if (mode == "os_biometric" &&
            ((keyType == "biometric_crypto" && activeBiometricDek == null) || !vaultUnlockedForSession)
        ) {
            return mapOf("locked" to true, "secretsJson" to "{}")
        }
        if (mode == "passphrase" && activePassphraseKey == null) {
            return mapOf("locked" to true, "secretsJson" to "{}")
        }
        if (cachedVaultJson != null) {
            return mapOf("locked" to false, "secretsJson" to cachedVaultJson!!)
        }
        val plain = when {
            mode == "os_biometric" && keyType == "biometric_crypto" -> {
                val iv = prefs.getString("iv", null)
                val ct = prefs.getString("ct", null)
                val dek = activeBiometricDek
                if (iv.isNullOrEmpty() || ct.isNullOrEmpty() || dek == null) "{}"
                else decryptWithSecretKey(dek, iv, ct)
            }
            mode == "passphrase" -> {
                val iv = prefs.getString("iv", null)
                val ct = prefs.getString("ct", null)
                if (iv.isNullOrEmpty() || ct.isNullOrEmpty()) "{}"
                else decryptWithSecretKey(activePassphraseKey!!, iv, ct)
            }
            else -> decryptKeystoreVaultPayload() ?: "{}"
        }
        cachedVaultJson = plain
        return mapOf("locked" to false, "secretsJson" to plain)
    }

    private fun writeAndroidVaultSecrets(secretsJson: String) {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString("mode", "os_keystore") ?: "os_keystore"
        val keyType = prefs.getString("key_type", "") ?: ""
        if (mode == "os_biometric") {
            if (keyType == "biometric_crypto") {
                val dek = activeBiometricDek
                    ?: throw IllegalStateException("Vault is locked — authenticate with Fingerprint / Biometrics first.")
                val (ivB64, ctB64) = encryptWithSecretKey(dek, secretsJson)
                prefs.edit().putString("iv", ivB64).putString("ct", ctB64).apply()
                cachedVaultJson = secretsJson
                return
            }
            if (!vaultUnlockedForSession) {
                throw IllegalStateException("Vault is locked — authenticate with OS biometrics first.")
            }
        }
        if (mode == "passphrase") {
            val key = activePassphraseKey
                ?: throw IllegalStateException("Vault is locked — unlock with passphrase first.")
            val (ivB64, ctB64) = encryptWithSecretKey(key, secretsJson)
            prefs.edit().putString("iv", ivB64).putString("ct", ctB64).apply()
            cachedVaultJson = secretsJson
            return
        }
        val (ivB64, ctB64) = encryptWithKeystoreAes(secretsJson)
        prefs.edit()
            .putString("mode", mode)
            .putString("iv", ivB64)
            .putString("ct", ctB64)
            .apply()
        cachedVaultJson = secretsJson
    }

    private fun deleteKeystoreAliasQuietly(alias: String) {
        try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (ks.containsAlias(alias)) {
                ks.deleteEntry(alias)
            }
        } catch (_: Exception) {}
    }

    /**
     * Generates a hardware-bound AndroidKeyStore AES-256-GCM key whose use is
     * cryptographically gated by `BiometricPrompt.CryptoObject` (StrongBox/TEE,
     * `setUserAuthenticationRequired(true)`, per-use timeout = 0, invalidated if
     * a new rogue fingerprint is enrolled). Returns Pair(key, strongBiometricOnly).
     */
    private fun createHardwareBiometricKeystoreKey(): Pair<SecretKey, Boolean> {
        deleteKeystoreAliasQuietly(VAULT_BIOMETRIC_AES_KEY_ALIAS)
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")

        val bm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            getSystemService(BiometricManager::class.java)
        } else null
        val hasStrongBiometric = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && bm != null) {
            bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS
        } else false

        val authTypes = if (hasStrongBiometric) {
            KeyProperties.AUTH_BIOMETRIC_STRONG
        } else {
            KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
        }

        fun buildSpec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(
                VAULT_BIOMETRIC_AES_KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && hasStrongBiometric) {
                b.setInvalidatedByBiometricEnrollment(true)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // timeout = 0 forces per-operation CryptoObject hardware authorization
                b.setUserAuthenticationParameters(0, authTypes)
            } else {
                @Suppress("DEPRECATION")
                b.setUserAuthenticationValidityDurationSeconds(-1)
            }
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                b.setIsStrongBoxBacked(true)
            }
            return b.build()
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                kg.init(buildSpec(strongBox = true))
                return Pair(kg.generateKey(), hasStrongBiometric)
            } catch (_: Exception) {
                // Fall back to hardware TEE if StrongBox rejects spec
            }
        }
        kg.init(buildSpec(strongBox = false))
        return Pair(kg.generateKey(), hasStrongBiometric)
    }

    private fun getExistingHardwareBiometricKey(): SecretKey? {
        return try {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            ks.getKey(VAULT_BIOMETRIC_AES_KEY_ALIAS, null) as? SecretKey
        } catch (_: Exception) {
            null
        }
    }

    private fun authenticateCryptoObject(
        title: String,
        subtitle: String,
        cipher: Cipher,
        strongBiometricOnly: Boolean,
        onComplete: (Cipher?, String?) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onComplete(null, "Hardware CryptoObject requires Android 11+.")
            return
        }
        var completed = false
        fun finishOnce(unlockedCipher: Cipher?, err: String?) {
            if (completed) return
            completed = true
            runOnUiThread { onComplete(unlockedCipher, err) }
        }
        try {
            val builder = BiometricPrompt.Builder(this)
                .setTitle(title)
                .setSubtitle(subtitle)
            if (strongBiometricOnly) {
                builder.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                builder.setNegativeButton("Cancel", mainExecutor) { _, _ ->
                    finishOnce(null, "Fingerprint authentication cancelled.")
                }
            } else {
                builder.setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
                )
            }
            builder.build().authenticate(
                BiometricPrompt.CryptoObject(cipher),
                CancellationSignal(),
                mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult?) {
                        val c = authResult?.cryptoObject?.cipher
                        if (c != null) {
                            finishOnce(c, null)
                        } else {
                            finishOnce(null, "Biometric hardware did not authorize cipher.")
                        }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                        finishOnce(null, errString?.toString() ?: "Biometric authentication cancelled.")
                    }
                }
            )
        } catch (e: Exception) {
            finishOnce(null, e.message ?: "Biometric CryptoObject prompt failed.")
        }
    }

    private fun isVaultCurrentlyLocked(): Boolean {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val mode = prefs.getString("mode", "os_keystore") ?: "os_keystore"
        val keyType = prefs.getString("key_type", "") ?: ""
        return when (mode) {
            "os_biometric" ->
                (keyType == "biometric_crypto" && activeBiometricDek == null) || !vaultUnlockedForSession
            "passphrase" -> activePassphraseKey == null
            else -> false
        }
    }

    private fun enableHardwareBiometricVault(result: MethodChannel.Result) {
        if (isVaultCurrentlyLocked()) {
            result.error("VAULT_LOCKED", "Unlock the vault before changing protection mode.", null)
            return
        }
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!km.isDeviceSecure) {
            result.error("NO_DEVICE_LOCK", "Set up a fingerprint or screen lock in Android Settings first.", null)
            return
        }
        val current = cachedVaultJson ?: runCatching { decryptKeystoreVaultPayload() }.getOrNull() ?: "{}"

        // Android 11+ (API 30+): True hardware-enforced BiometricPrompt.CryptoObject envelope encryption.
        // Fail closed on API 30+ rather than silently downgrading to an unauthenticated Keystore key.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val (bioKek, strongOnly) = createHardwareBiometricKeystoreKey()
                val wrapCipher = Cipher.getInstance("AES/GCM/NoPadding")
                wrapCipher.init(Cipher.ENCRYPT_MODE, bioKek)

                authenticateCryptoObject(
                    title = "Encrypt Private Sync Key",
                    subtitle = "Scan your fingerprint to seal your key inside Android hardware keystore",
                    cipher = wrapCipher,
                    strongBiometricOnly = strongOnly
                ) { authorizedCipher, err ->
                    if (authorizedCipher == null) {
                        result.error("AUTH_FAILED", err ?: "Fingerprint authentication cancelled.", null)
                        return@authenticateCryptoObject
                    }
                    try {
                        // Generate fresh 256-bit DEK, wrap DEK with hardware Biometric KEK, encrypt vault with DEK
                        val dekBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
                        val dek = SecretKeySpec(dekBytes, "AES")
                        val wrappedDekIv = authorizedCipher.iv
                        val wrappedDekCt = authorizedCipher.doFinal(dekBytes)
                        dekBytes.fill(0)

                        val (ivB64, ctB64) = encryptWithSecretKey(dek, current)
                        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
                        prefs.edit()
                            .putString("mode", "os_biometric")
                            .putString("key_type", "biometric_crypto")
                            .putBoolean("strong_only", strongOnly)
                            .putString("wrapped_dek_iv", Base64.encodeToString(wrappedDekIv, Base64.NO_WRAP))
                            .putString("wrapped_dek_ct", Base64.encodeToString(wrappedDekCt, Base64.NO_WRAP))
                            .putString("iv", ivB64)
                            .putString("ct", ctB64)
                            .remove("salt")
                            .apply()

                        // Erase legacy unauthenticated keystore key so ciphertext cannot be unwrapped without biometrics
                        deleteKeystoreAliasQuietly(VAULT_AES_KEY_ALIAS)
                        activePassphraseKey = null
                        activeBiometricDek = dek
                        vaultUnlockedForSession = true
                        cachedVaultJson = current
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("BIOMETRIC_ENABLE_FAILED", e.message, null)
                    }
                }
                return
            } catch (e: Exception) {
                result.error(
                    "BIOMETRIC_ENABLE_FAILED",
                    e.message ?: "Hardware biometric key setup failed.",
                    null
                )
                return
            }
        }

        // Legacy fallback for Android 7-10 (API 24-29)
        promptOsAuthentication(
            title = "Protect Edge Mapper Vault",
            subtitle = "Use device biometrics or screen lock to guard your private Sync Key"
        ) { ok, err ->
            if (!ok) {
                result.error("AUTH_FAILED", err ?: "OS authentication cancelled.", null)
                return@promptOsAuthentication
            }
            try {
                val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
                val (ivB64, ctB64) = encryptWithKeystoreAes(current)
                prefs.edit()
                    .putString("mode", "os_biometric")
                    .putString("iv", ivB64)
                    .putString("ct", ctB64)
                    .remove("salt")
                    .remove("key_type")
                    .apply()
                activePassphraseKey = null
                activeBiometricDek = null
                vaultUnlockedForSession = true
                cachedVaultJson = current
                result.success(true)
            } catch (e: Exception) {
                result.error("BIOMETRIC_ENABLE_FAILED", e.message, null)
            }
        }
    }

    private fun unlockHardwareBiometricVault(result: MethodChannel.Result) {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val keyType = prefs.getString("key_type", "") ?: ""
        if (keyType == "biometric_crypto" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val wrappedIvB64 = prefs.getString("wrapped_dek_iv", null)
            val wrappedCtB64 = prefs.getString("wrapped_dek_ct", null)
            val bioKek = getExistingHardwareBiometricKey()
            if (wrappedIvB64.isNullOrEmpty() || wrappedCtB64.isNullOrEmpty() || bioKek == null) {
                result.error(
                    "BIOMETRIC_KEY_INVALIDATED",
                    "Hardware biometric key was invalidated (e.g. new fingerprint enrolled). Recover using your emk1-... key from Bitwarden.",
                    null
                )
                return
            }
            try {
                val unwrapCipher = Cipher.getInstance("AES/GCM/NoPadding")
                unwrapCipher.init(
                    Cipher.DECRYPT_MODE,
                    bioKek,
                    GCMParameterSpec(128, Base64.decode(wrappedIvB64, Base64.NO_WRAP))
                )
                val strongOnly = prefs.getBoolean("strong_only", true)
                authenticateCryptoObject(
                    title = "Unlock Private Sync Key",
                    subtitle = "Scan your fingerprint to decrypt your local Sync Key",
                    cipher = unwrapCipher,
                    strongBiometricOnly = strongOnly
                ) { authorizedCipher, err ->
                    if (authorizedCipher == null) {
                        result.error("AUTH_FAILED", err ?: "Fingerprint authentication cancelled.", null)
                        return@authenticateCryptoObject
                    }
                    try {
                        val dekBytes = authorizedCipher.doFinal(Base64.decode(wrappedCtB64, Base64.NO_WRAP))
                        val dek = SecretKeySpec(dekBytes, "AES")
                        dekBytes.fill(0)

                        val iv = prefs.getString("iv", null) ?: ""
                        val ct = prefs.getString("ct", null) ?: ""
                        val plain = if (ct.isEmpty()) "{}" else decryptWithSecretKey(dek, iv, ct)
                        activeBiometricDek = dek
                        vaultUnlockedForSession = true
                        cachedVaultJson = plain
                        result.success(plain)
                    } catch (e: Exception) {
                        result.error("UNLOCK_FAILED", e.message, null)
                    }
                }
                return
            } catch (e: Exception) {
                result.error(
                    "BIOMETRIC_KEY_INVALIDATED",
                    "Biometric key could not be initialized (${e.message}). Recover using your emk1-... key from Bitwarden.",
                    null
                )
                return
            }
        }

        // Legacy os_biometric unlock (Android 7-10 or pre-upgrade vault)
        promptOsAuthentication(
            title = "Unlock Edge Mapper Vault",
            subtitle = "Verify your identity to decrypt your Private Sync Key"
        ) { ok, err ->
            if (!ok) {
                result.error("AUTH_FAILED", err ?: "OS authentication cancelled.", null)
                return@promptOsAuthentication
            }
            try {
                val plain = decryptKeystoreVaultPayload() ?: "{}"
                vaultUnlockedForSession = true
                cachedVaultJson = plain
                result.success(plain)
            } catch (e: Exception) {
                result.error("UNLOCK_FAILED", e.message, null)
            }
        }
    }

    private fun getOrCreateE2eeUserPrivKeystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = ks.getKey(E2EE_USER_PRIV_KEY_ALIAS, null)
        if (existing is SecretKey) return existing

        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val strongBoxSpec = KeyGenParameterSpec.Builder(
                    E2EE_USER_PRIV_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .setIsStrongBoxBacked(true)
                    .build()
                kg.init(strongBoxSpec)
                return kg.generateKey()
            } catch (_: Exception) {
                // Fallback to hardware TEE AndroidKeyStore when StrongBox is unavailable
            }
        }
        val teeSpec = KeyGenParameterSpec.Builder(
            E2EE_USER_PRIV_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        kg.init(teeSpec)
        return kg.generateKey()
    }

    private fun getOrCreateE2eeBiometricRsaKeyPair(): Pair<KeyStore.PrivateKeyEntry, Boolean> {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val bm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            getSystemService(BiometricManager::class.java)
        } else null
        val hasStrongBiometric = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && bm != null) {
            bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                BiometricManager.BIOMETRIC_SUCCESS
        } else false

        val existing = ks.getEntry(E2EE_USER_PRIV_BIO_RSA_ALIAS, null)
        if (existing is KeyStore.PrivateKeyEntry) {
            return Pair(existing, hasStrongBiometric)
        }

        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
        val builder = KeyGenParameterSpec.Builder(
            E2EE_USER_PRIV_BIO_RSA_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setKeySize(2048)
            .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA1)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
            .setUserAuthenticationRequired(true)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val authTypes = if (hasStrongBiometric) {
                KeyProperties.AUTH_BIOMETRIC_STRONG
            } else {
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL
            }
            builder.setUserAuthenticationParameters(0, authTypes)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            builder.setInvalidatedByBiometricEnrollment(true)
        }
        kpg.initialize(builder.build())
        kpg.generateKeyPair()
        val entry = ks.getEntry(E2EE_USER_PRIV_BIO_RSA_ALIAS, null) as KeyStore.PrivateKeyEntry
        return Pair(entry, hasStrongBiometric)
    }

    private fun cacheE2eeUserPrivInKeystore(
        uid: String,
        rawUserPriv: ByteArray,
        rawAuthSeed: ByteArray?
    ): Boolean {
        if (rawUserPriv.size != 32) return false
        val payload = if (rawAuthSeed != null && rawAuthSeed.size == 16) {
            ByteArray(48).also {
                System.arraycopy(rawAuthSeed, 0, it, 0, 16)
                System.arraycopy(rawUserPriv, 0, it, 16, 32)
            }
        } else {
            rawUserPriv.copyOf()
        }
        try {
            val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            // Android 11+ (API 30+) with screen lock: wrap random DEK with hardware-biometric
            // RSA-OAEP public key so caching requires no extra prompt while decryption is
            // cryptographically gated by BiometricPrompt.CryptoObject inside TEE/StrongBox.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && km.isDeviceSecure) {
                try {
                    val (entry, strongOnly) = getOrCreateE2eeBiometricRsaKeyPair()
                    val dekBytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
                    try {
                        val dek = SecretKeySpec(dekBytes, "AES")
                        val aesCipher = Cipher.getInstance("AES/GCM/NoPadding")
                        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
                        aesCipher.init(Cipher.ENCRYPT_MODE, dek, GCMParameterSpec(128, iv))
                        aesCipher.updateAAD("e2ee-user-priv-cache|v2|$uid".toByteArray(Charsets.UTF_8))
                        val ct = aesCipher.doFinal(payload)

                        val rsaCipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                        val oaepParams = OAEPParameterSpec(
                            "SHA-256",
                            "MGF1",
                            MGF1ParameterSpec.SHA1,
                            PSource.PSpecified.DEFAULT
                        )
                        rsaCipher.init(Cipher.ENCRYPT_MODE, entry.certificate.publicKey, oaepParams)
                        val wrappedDek = rsaCipher.doFinal(dekBytes)

                        val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
                        prefs.edit()
                            .putString("uid", uid)
                            .putString("key_type", "biometric_rsa_oaep")
                            .putBoolean("strong_only", strongOnly)
                            .putString("wrapped_dek", Base64.encodeToString(wrappedDek, Base64.NO_WRAP))
                            .putString("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
                            .putString("ct", Base64.encodeToString(ct, Base64.NO_WRAP))
                            .apply()
                        deleteKeystoreAliasQuietly(E2EE_USER_PRIV_KEY_ALIAS)
                        return true
                    } finally {
                        dekBytes.fill(0)
                    }
                } catch (_: Exception) {
                    // Fall back below if RSA OAEP biometric keygen is unavailable on this device
                }
            }

            val key = getOrCreateE2eeUserPrivKeystoreKey()
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key)
            cipher.updateAAD("e2ee-user-priv-cache|v1|$uid".toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            val ct = cipher.doFinal(payload)
            val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
            prefs.edit()
                .putString("uid", uid)
                .putString("key_type", "aes_keystore_v1")
                .remove("wrapped_dek")
                .putString("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
                .putString("ct", Base64.encodeToString(ct, Base64.NO_WRAP))
                .apply()
            return true
        } finally {
            payload.fill(0)
        }
    }

    private fun unlockE2eeUserPrivHardwareBiometric(
        expectedUid: String?,
        result: MethodChannel.Result
    ) {
        val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
        val storedUid = prefs.getString("uid", null)
        if (storedUid.isNullOrEmpty() || (!expectedUid.isNullOrEmpty() && storedUid != expectedUid)) {
            result.success(null)
            return
        }
        val keyType = prefs.getString("key_type", "") ?: ""
        if (keyType == "biometric_rsa_oaep" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val wrappedDekB64 = prefs.getString("wrapped_dek", null)
            val ivB64 = prefs.getString("iv", null)
            val ctB64 = prefs.getString("ct", null)
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val privKey = ks.getKey(E2EE_USER_PRIV_BIO_RSA_ALIAS, null) as? PrivateKey
            if (wrappedDekB64.isNullOrEmpty() || ivB64.isNullOrEmpty() || ctB64.isNullOrEmpty() || privKey == null) {
                result.error(
                    "BIOMETRIC_KEY_INVALIDATED",
                    "Hardware biometric key was invalidated. Unlock using your Recovery Key.",
                    null
                )
                return
            }
            try {
                val unwrapCipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
                val oaepParams = OAEPParameterSpec(
                    "SHA-256",
                    "MGF1",
                    MGF1ParameterSpec.SHA1,
                    PSource.PSpecified.DEFAULT
                )
                unwrapCipher.init(Cipher.DECRYPT_MODE, privKey, oaepParams)
                val strongOnly = prefs.getBoolean("strong_only", true)
                authenticateCryptoObject(
                    title = "Unlock Edge Mapper Vault",
                    subtitle = "Use your fingerprint or screen lock to unwrap your X25519 key from Android Keystore",
                    cipher = unwrapCipher,
                    strongBiometricOnly = strongOnly
                ) { authorizedCipher, err ->
                    if (authorizedCipher == null) {
                        result.error("AUTH_FAILED", err ?: "Fingerprint authentication cancelled.", null)
                        return@authenticateCryptoObject
                    }
                    var dekBytes: ByteArray? = null
                    var plain: ByteArray? = null
                    try {
                        dekBytes = authorizedCipher.doFinal(Base64.decode(wrappedDekB64, Base64.NO_WRAP))
                        val aesCipher = Cipher.getInstance("AES/GCM/NoPadding")
                        aesCipher.init(
                            Cipher.DECRYPT_MODE,
                            SecretKeySpec(dekBytes, "AES"),
                            GCMParameterSpec(128, Base64.decode(ivB64, Base64.NO_WRAP))
                        )
                        aesCipher.updateAAD("e2ee-user-priv-cache|v2|$storedUid".toByteArray(Charsets.UTF_8))
                        plain = aesCipher.doFinal(Base64.decode(ctB64, Base64.NO_WRAP))
                        val triple = when (plain.size) {
                            48 -> Triple(storedUid, plain.copyOfRange(16, 48), plain.copyOfRange(0, 16))
                            32 -> Triple(storedUid, plain.copyOf(), null)
                            else -> null
                        }
                        if (triple == null) {
                            result.success(null)
                        } else {
                            val (uid, priv, seed) = triple
                            try {
                                result.success(
                                    mapOf(
                                        "uid" to uid,
                                        "userPrivB64" to Base64.encodeToString(priv, Base64.NO_WRAP),
                                        "authSeedB64" to (seed?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: "")
                                    )
                                )
                            } finally {
                                priv.fill(0)
                                seed?.fill(0)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("KEYSTORE_UNLOCK_FAILED", e.message, null)
                    } finally {
                        dekBytes?.fill(0)
                        plain?.fill(0)
                    }
                }
                return
            } catch (e: Exception) {
                result.error(
                    "BIOMETRIC_KEY_INVALIDATED",
                    "Biometric key could not be initialized (${e.message}). Unlock with your Recovery Key.",
                    null
                )
                return
            }
        }

        // Legacy AES-Keystore entry (API 24-29 or pre-upgrade cache)
        promptOsAuthentication(
            title = "Unlock Edge Mapper Vault",
            subtitle = "Use your fingerprint or screen lock to unwrap your X25519 key from Android Keystore"
        ) { ok, err ->
            if (!ok) {
                result.error("AUTH_FAILED", err ?: "Authentication cancelled.", null)
                return@promptOsAuthentication
            }
            try {
                val loaded = loadE2eeUserPrivFromKeystore(expectedUid)
                if (loaded == null) {
                    result.success(null)
                } else {
                    val (uid, priv, seed) = loaded
                    try {
                        result.success(
                            mapOf(
                                "uid" to uid,
                                "userPrivB64" to Base64.encodeToString(priv, Base64.NO_WRAP),
                                "authSeedB64" to (seed?.let { Base64.encodeToString(it, Base64.NO_WRAP) } ?: "")
                            )
                        )
                    } finally {
                        priv.fill(0)
                        seed?.fill(0)
                    }
                }
            } catch (e: Exception) {
                result.error("KEYSTORE_UNLOCK_FAILED", e.message, null)
            }
        }
    }

    private fun loadE2eeUserPrivFromKeystore(
        expectedUid: String?
    ): Triple<String, ByteArray, ByteArray?>? {
        val prefs = getSharedPreferences(E2EE_USER_PRIV_PREFS_NAME, Context.MODE_PRIVATE)
        val storedUid = prefs.getString("uid", null) ?: return null
        if (!expectedUid.isNullOrEmpty() && storedUid != expectedUid) return null
        val ivB64 = prefs.getString("iv", null) ?: return null
        val ctB64 = prefs.getString("ct", null) ?: return null
        val key = getOrCreateE2eeUserPrivKeystoreKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, Base64.decode(ivB64, Base64.NO_WRAP))
        cipher.init(Cipher.DECRYPT_MODE, key, spec)
        cipher.updateAAD("e2ee-user-priv-cache|v1|$storedUid".toByteArray(Charsets.UTF_8))
        val plain = cipher.doFinal(Base64.decode(ctB64, Base64.NO_WRAP))
        return try {
            when (plain.size) {
                48 -> Triple(
                    storedUid,
                    plain.copyOfRange(16, 48),
                    plain.copyOfRange(0, 16)
                )
                32 -> Triple(storedUid, plain.copyOf(), null)
                else -> null
            }
        } finally {
            plain.fill(0)
        }
    }

    private fun getOrCreateVaultKeystoreKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = ks.getKey(VAULT_AES_KEY_ALIAS, null)
        if (existing is SecretKey) return existing

        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val strongBoxSpec = KeyGenParameterSpec.Builder(
                    VAULT_AES_KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setIsStrongBoxBacked(true)
                    .build()
                kg.init(strongBoxSpec)
                return kg.generateKey()
            } catch (_: Exception) {
                // Fallback to standard hardware TEE AndroidKeyStore
            }
        }
        val teeSpec = KeyGenParameterSpec.Builder(
            VAULT_AES_KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        kg.init(teeSpec)
        return kg.generateKey()
    }

    private fun encryptWithKeystoreAes(plainText: String): Pair<String, String> {
        val key = getOrCreateVaultKeystoreKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val iv = cipher.iv
        val ct = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return Pair(
            Base64.encodeToString(iv, Base64.NO_WRAP),
            Base64.encodeToString(ct, Base64.NO_WRAP)
        )
    }

    private fun decryptKeystoreVaultPayload(): String? {
        val prefs = getSharedPreferences(VAULT_PREFS_NAME, Context.MODE_PRIVATE)
        val ivB64 = prefs.getString("iv", null) ?: return null
        val ctB64 = prefs.getString("ct", null) ?: return null
        val key = getOrCreateVaultKeystoreKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val spec = GCMParameterSpec(128, Base64.decode(ivB64, Base64.NO_WRAP))
        cipher.init(Cipher.DECRYPT_MODE, key, spec)
        val plain = cipher.doFinal(Base64.decode(ctB64, Base64.NO_WRAP))
        return String(plain, Charsets.UTF_8)
    }

    private fun derivePbkdf2Key(passphrase: String, salt: ByteArray): SecretKey {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, 600000, 256)
        var secretBytes: ByteArray? = null
        return try {
            secretBytes = factory.generateSecret(spec).encoded
            SecretKeySpec(secretBytes, "AES")
        } finally {
            spec.clearPassword()
            secretBytes?.fill(0)
        }
    }

    private fun encryptWithSecretKey(key: SecretKey, plainText: String): Pair<String, String> {
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
        val ct = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return Pair(
            Base64.encodeToString(iv, Base64.NO_WRAP),
            Base64.encodeToString(ct, Base64.NO_WRAP)
        )
    }

    private fun decryptWithSecretKey(key: SecretKey, ivB64: String, ctB64: String): String {
        val iv = Base64.decode(ivB64, Base64.NO_WRAP)
        val ct = Base64.decode(ctB64, Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        val plain = cipher.doFinal(ct)
        return String(plain, Charsets.UTF_8)
    }

    private fun promptOsAuthentication(
        title: String,
        subtitle: String,
        onComplete: (Boolean, String?) -> Unit
    ) {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!km.isDeviceSecure) {
            onComplete(false, "Set up a screen lock or fingerprint in Android Settings first.")
            return
        }
        var completed = false
        fun finishOnce(ok: Boolean, err: String?) {
            if (completed) return
            completed = true
            runOnUiThread { onComplete(ok, err) }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val builder = BiometricPrompt.Builder(this)
                    .setTitle(title)
                    .setSubtitle(subtitle)
                    .setAllowedAuthenticators(
                        BiometricManager.Authenticators.BIOMETRIC_STRONG or
                            BiometricManager.Authenticators.DEVICE_CREDENTIAL
                    )
                val prompt = builder.build()
                prompt.authenticate(
                    CancellationSignal(),
                    mainExecutor,
                    object : BiometricPrompt.AuthenticationCallback() {
                        override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) {
                            finishOnce(true, null)
                        }
                        override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                            finishOnce(false, errString?.toString() ?: "Authentication cancelled.")
                        }
                    }
                )
                return
            } catch (_: Exception) {
                // Fall back to KeyguardManager device credential prompt below
            }
        }
        @Suppress("DEPRECATION")
        val intent = km.createConfirmDeviceCredentialIntent(title, subtitle)
        if (intent == null) {
            finishOnce(false, "Device credential confirmation is unavailable.")
            return
        }
        pendingOsAuthCallback = { ok, err -> finishOnce(ok, err) }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, OS_AUTH_REQUEST_CODE)
    }

    private fun isAllowedPhotoPath(path: String): Boolean {
        return try {
            val target = File(path).canonicalFile
            if (!target.isFile) return false
            val allowedRoots = listOfNotNull(
                filesDir?.canonicalFile,
                cacheDir?.canonicalFile,
                externalCacheDir?.canonicalFile,
                getExternalFilesDir(null)?.canonicalFile,
                dataDir?.canonicalFile?.let { File(it, "app_flutter").canonicalFile }
            )
            allowedRoots.any { root ->
                val rootPath = root.path.trimEnd(File.separatorChar) + File.separatorChar
                target.path.startsWith(rootPath)
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun compressImageFileToJpeg(path: String, maxBytes: Int): ByteArray? {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            val srcW = bounds.outWidth
            val srcH = bounds.outHeight
            if (srcW <= 0 || srcH <= 0) return null

            val initialMaxDim = 1280
            var sampleSize = 1
            while (max(srcW / sampleSize, srcH / sampleSize) > initialMaxDim * 2) {
                sampleSize *= 2
            }

            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            var bitmap = BitmapFactory.decodeFile(path, decodeOpts) ?: return null

            // Respect EXIF orientation so vertical phone photos stay upright after sync
            bitmap = applyExifOrientation(path, bitmap)

            val presets = listOf(
                Pair(1280, 80),
                Pair(1024, 74),
                Pair(840, 68),
                Pair(640, 60),
                Pair(480, 52),
                Pair(360, 46)
            )

            var bestBytes: ByteArray? = null
            for ((targetDim, quality) in presets) {
                val maxSide = max(bitmap.width, bitmap.height)
                val working = if (maxSide > targetDim) {
                    val scale = targetDim.toFloat() / maxSide.toFloat()
                    val w = max(1, (bitmap.width * scale).roundToInt())
                    val h = max(1, (bitmap.height * scale).roundToInt())
                    Bitmap.createScaledBitmap(bitmap, w, h, true)
                } else {
                    bitmap
                }

                val baos = ByteArrayOutputStream()
                working.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                val out = baos.toByteArray()
                if (working !== bitmap) {
                    working.recycle()
                }
                bestBytes = out
                if (out.size <= maxBytes) {
                    bitmap.recycle()
                    return out
                }
            }

            bitmap.recycle()
            bestBytes
        } catch (_: Exception) {
            null
        }
    }

    private fun applyExifOrientation(path: String, src: Bitmap): Bitmap {
        return try {
            val exif = ExifInterface(path)
            val orientation = exif.getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL
            )
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
                else -> return src
            }
            val rotated = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
            if (rotated !== src) src.recycle()
            rotated
        } catch (_: Exception) {
            src
        }
    }

    private fun checkGeminiNanoAvailability(): Map<String, Any> {
        val deviceModel = "${Build.MANUFACTURER} ${Build.MODEL}".trim()
        val aicoreInstalled = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                packageManager.getPackageInfo(
                    AICORE_PACKAGE,
                    PackageManager.PackageInfoFlags.of(0)
                )
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(AICORE_PACKAGE, 0)
            }
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }

        // Pixel 6 / 6a / 7 / 7a lack AICore Gemini Nano support even if Android OS is updated.
        val isPixel6Or7 = Build.MODEL.contains("Pixel 6", ignoreCase = true) ||
            Build.MODEL.contains("Pixel 7", ignoreCase = true)

        val reason = when {
            isPixel6Or7 ->
                "AICore / Gemini Nano is not supported on $deviceModel (requires Pixel 8+ / supported NPU). Using fast on-device ML Kit Vision + Multilingual OCR offline."
            !aicoreInstalled ->
                "Android AICore is not installed on $deviceModel. Using fast on-device ML Kit Vision + Multilingual OCR offline."
            else ->
                "Android AICore detected on $deviceModel. ML Kit GenAI Prompt API can be enabled here; falling back to ML Kit Vision + OCR in current build."
        }

        return mapOf(
            "available" to (aicoreInstalled && !isPixel6Or7),
            "aicoreInstalled" to aicoreInstalled,
            "deviceModel" to deviceModel,
            "sdkInt" to Build.VERSION.SDK_INT,
            "reason" to reason
        )
    }

    private fun saveSyncKeyToAndroidPasswordManager(
        accountLabel: String,
        syncKey: String,
        result: MethodChannel.Result
    ) {
        // Priority 1: Android 14+ (API 34+) native AOSP CredentialManager.createCredential()
        // Directly launches Bitwarden (or any configured Credential Provider) without touching the clipboard.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val cm = getSystemService(CredentialManager::class.java)
            if (cm != null) {
                try {
                    val displayInfo = Bundle().apply {
                        putCharSequence("androidx.credentials.BUNDLE_KEY_USER_ID", accountLabel)
                        putCharSequence(
                            "androidx.credentials.BUNDLE_KEY_USER_DISPLAY_NAME",
                            "Edge Mapper Private Sync Key"
                        )
                    }
                    val credData = Bundle().apply {
                        putString("androidx.credentials.BUNDLE_KEY_ID", accountLabel)
                        putString("androidx.credentials.BUNDLE_KEY_PASSWORD", syncKey)
                        putBundle("androidx.credentials.BUNDLE_KEY_REQUEST_DISPLAY_INFO", displayInfo)
                    }
                    val request = CreateCredentialRequest.Builder(
                        "android.credentials.TYPE_PASSWORD_CREDENTIAL",
                        credData,
                        Bundle()
                    )
                        .setAlwaysSendAppInfoToProvider(true)
                        .build()

                    cm.createCredential(
                        this,
                        request,
                        null,
                        mainExecutor,
                        object : OutcomeReceiver<CreateCredentialResponse, CreateCredentialException> {
                            override fun onResult(response: CreateCredentialResponse) {
                                result.success(
                                    mapOf(
                                        "prompted" to true,
                                        "saved" to true,
                                        "message" to "Saved directly to Bitwarden / Android Credential Manager."
                                    )
                                )
                            }

                            override fun onError(error: CreateCredentialException) {
                                Log.w("EdgeMapperPM", "CredentialManager save error (${error.type}): ${error.message}")
                                if (error.type == CreateCredentialException.TYPE_USER_CANCELED) {
                                    result.success(
                                        mapOf(
                                            "prompted" to true,
                                            "saved" to false,
                                            "message" to "Password manager save cancelled."
                                        )
                                    )
                                    return
                                }
                                // Fall back to Android Autofill Service if no Credential Provider handled it
                                val autofillPrompted = triggerAndroidAutofillSave(accountLabel, syncKey)
                                result.success(
                                    mapOf(
                                        "prompted" to autofillPrompted,
                                        "saved" to false,
                                        "message" to if (autofillPrompted) {
                                            "Sent directly to your Android Autofill password manager (Bitwarden / KeePassDX)."
                                        } else {
                                            "No password manager provider enabled. Enable Bitwarden (or your password manager) in Android Settings → Passwords, passkeys & accounts."
                                        }
                                    )
                                )
                            }
                        }
                    )
                    return
                } catch (e: Exception) {
                    Log.w("EdgeMapperPM", "CredentialManager createCredential failed: ${e.message}")
                }
            }
        }

        // Priority 2 (Android 8–13 / fallback): AOSP AutofillManager.commit() — still no clipboard copy.
        val autofillPrompted = triggerAndroidAutofillSave(accountLabel, syncKey)
        result.success(
            mapOf(
                "prompted" to autofillPrompted,
                "saved" to false,
                "message" to if (autofillPrompted) {
                    "Sent directly to your Android Autofill password manager (Bitwarden / KeePassDX)."
                } else {
                    "No password manager service enabled. Enable Bitwarden (or your password manager) in Android Settings → Passwords & autofill."
                }
            )
        )
    }

    private fun retrieveSyncKeyFromAndroidPasswordManager(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            result.success(null)
            return
        }
        val cm = getSystemService(CredentialManager::class.java)
        if (cm == null) {
            result.success(null)
            return
        }
        try {
            val passwordOption = CredentialOption.Builder(
                "android.credentials.TYPE_PASSWORD_CREDENTIAL",
                Bundle(),
                Bundle()
            ).build()
            val request = GetCredentialRequest.Builder(Bundle())
                .addCredentialOption(passwordOption)
                .build()

            cm.getCredential(
                this,
                request,
                null,
                mainExecutor,
                object : OutcomeReceiver<GetCredentialResponse, GetCredentialException> {
                    override fun onResult(response: GetCredentialResponse) {
                        val key = response.credential.data
                            .getString("androidx.credentials.BUNDLE_KEY_PASSWORD")
                            ?.trim()
                        result.success(if (key.isNullOrEmpty()) null else key)
                    }

                    override fun onError(error: GetCredentialException) {
                        Log.w("EdgeMapperPM", "CredentialManager retrieve error (${error.type}): ${error.message}")
                        result.success(null)
                    }
                }
            )
        } catch (e: Exception) {
            Log.w("EdgeMapperPM", "CredentialManager getCredential failed: ${e.message}")
            result.success(null)
        }
    }

    private fun copySensitiveToClipboard(secret: String): Boolean {
        return try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return false
            val clip = ClipData.newPlainText("Edge Mapper Private Sync Key", secret)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                clip.description.extras = PersistableBundle().apply {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                }
            }
            clipboard.setPrimaryClip(clip)
            true
        } catch (e: Exception) {
            Log.w("EdgeMapperPM", "Sensitive clipboard copy failed: ${e.message}")
            false
        }
    }

    /**
     * Triggers Android's AOSP Autofill Framework (`AutofillManager.commit()`)
     * using transient native username/password EditTexts so Bitwarden, KeePassDX,
     * Proton Pass, 1Password, or any local Android password manager prompts the
     * user to save the generated Private Sync Key (works on GrapheneOS without Play Services).
     */
    private fun triggerAndroidAutofillSave(accountLabel: String, syncKey: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val afm = getSystemService(AutofillManager::class.java) ?: return false
            if (!afm.isEnabled) return false

            val root = window?.decorView?.findViewById<ViewGroup>(android.R.id.content)
                ?: return false

            val container = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                alpha = 0.01f
                isFocusable = false
                layoutParams = ViewGroup.LayoutParams(1, 1)
            }

            val usernameField = EditText(this).apply {
                id = View.generateViewId()
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
                setAutofillHints(View.AUTOFILL_HINT_USERNAME)
                inputType = InputType.TYPE_CLASS_TEXT
                setText(accountLabel)
            }

            val passwordField = EditText(this).apply {
                id = View.generateViewId()
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_YES
                setAutofillHints(View.AUTOFILL_HINT_PASSWORD)
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                setText(syncKey)
            }

            container.addView(usernameField)
            container.addView(passwordField)
            root.addView(container)

            afm.notifyViewEntered(usernameField)
            afm.notifyValueChanged(usernameField)
            afm.notifyViewExited(usernameField)

            afm.notifyViewEntered(passwordField)
            afm.notifyValueChanged(passwordField)
            afm.notifyViewExited(passwordField)

            afm.commit()

            root.postDelayed({
                try {
                    usernameField.setText("")
                    passwordField.setText("")
                    root.removeView(container)
                } catch (_: Exception) {}
            }, 350L)

            true
        } catch (e: Exception) {
            Log.w("EdgeMapperPM", "Android Autofill save prompt skipped: ${e.message}")
            false
        }
    }
}

private class CompassStreamHandler(
    private val context: Context
) : EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var eventSink: EventChannel.EventSink? = null

    private val rotationMatrix = FloatArray(9)
    private val orientationAngles = FloatArray(3)
    private var lastGravity: FloatArray? = null
    private var lastGeomagnetic: FloatArray? = null

    // Circular exponential smoothing to prevent jitter across 0°/360° North wraparound
    private var smoothSin = 0.0
    private var smoothCos = 1.0
    private var hasInitialReading = false
    private val alpha = 0.22
    private var lastAccuracy = SensorManager.SENSOR_STATUS_UNRELIABLE

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        hasInitialReading = false

        val rotationVector = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        if (rotationVector != null) {
            sensorManager.registerListener(this, rotationVector, SensorManager.SENSOR_DELAY_UI)
        } else {
            val accel = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            val magnet = sensorManager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
            if (accel != null && magnet != null) {
                sensorManager.registerListener(this, accel, SensorManager.SENSOR_DELAY_UI)
                sensorManager.registerListener(this, magnet, SensorManager.SENSOR_DELAY_UI)
            } else {
                events?.success(mapOf("heading" to null, "accuracy" to -1))
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        eventSink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        var azimuthRad: Double? = null

        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                SensorManager.getOrientation(rotationMatrix, orientationAngles)
                azimuthRad = orientationAngles[0].toDouble()
            }
            Sensor.TYPE_ACCELEROMETER -> {
                lastGravity = event.values.clone()
                azimuthRad = computeFallbackAzimuth()
            }
            Sensor.TYPE_MAGNETIC_FIELD -> {
                lastGeomagnetic = event.values.clone()
                azimuthRad = computeFallbackAzimuth()
            }
        }

        if (azimuthRad != null) {
            val s = sin(azimuthRad)
            val c = cos(azimuthRad)
            if (!hasInitialReading) {
                smoothSin = s
                smoothCos = c
                hasInitialReading = true
            } else {
                smoothSin = alpha * s + (1.0 - alpha) * smoothSin
                smoothCos = alpha * c + (1.0 - alpha) * smoothCos
            }

            var headingDeg = Math.toDegrees(atan2(smoothSin, smoothCos))
            if (headingDeg < 0) headingDeg += 360.0

            eventSink?.success(
                mapOf(
                    "heading" to headingDeg,
                    "accuracy" to lastAccuracy
                )
            )
        }
    }

    private fun computeFallbackAzimuth(): Double? {
        val g = lastGravity ?: return null
        val m = lastGeomagnetic ?: return null
        val ok = SensorManager.getRotationMatrix(rotationMatrix, null, g, m)
        if (!ok) return null
        SensorManager.getOrientation(rotationMatrix, orientationAngles)
        return orientationAngles[0].toDouble()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        lastAccuracy = accuracy
    }
}
