package com.edgemapper.attestation

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.util.Base64
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.TaskCompletionSource
import com.google.firebase.FirebaseApp
import com.google.firebase.appcheck.AppCheckProvider
import com.google.firebase.appcheck.AppCheckProviderFactory
import com.google.firebase.appcheck.AppCheckToken
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.OutputStreamWriter
import java.net.URL
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.ProviderException
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/**
 * Custom [AppCheckToken] carrying an official Firebase App Check JWT minted by `attest-gate`.
 */
class AttestGateAppCheckToken(
    private val jwt: String,
    private val expirationTimeMillis: Long,
) : AppCheckToken() {
    override fun getToken(): String = jwt
    override fun getExpireTimeMillis(): Long = expirationTimeMillis
}

/**
 * Firebase [AppCheckProvider] backed by Android Hardware Key Attestation + self-hosted `attest-gate`.
 *
 * Works identically on stock Android and GrapheneOS with zero dependency on Google Play Services,
 * Play Store, or Play Integrity.
 */
class AttestGateAppCheckProvider(
    private val baseUrl: String,
    private val executor: ExecutorService = sharedExecutor,
) : AppCheckProvider {

    companion object {
        private const val TAG = "AttestGateProvider"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val CONNECT_TIMEOUT_MS = 10_000
        private const val READ_TIMEOUT_MS = 15_000
        private const val MAX_RESPONSE_BYTES = 64 * 1024
        private const val MIN_NONCE_BYTES = 16
        private const val MAX_NONCE_BYTES = 128

        private val sharedExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "attest-gate-worker").apply { isDaemon = true }
        }
    }

    override fun getToken(): Task<AppCheckToken> {
        val taskSource = TaskCompletionSource<AppCheckToken>()
        executor.execute {
            try {
                val token = fetchAttestedAppCheckToken()
                taskSource.setResult(token)
            } catch (e: Exception) {
                Log.e(TAG, "Hardware attestation failed: ${e.message}")
                taskSource.setException(e)
            }
        }
        return taskSource.task
    }

    /**
     * Synchronous hardware attestation flow:
     * 1. POST /v1/challenge -> receive single-use nonce (16..128 bytes base64url).
     * 2. Generate ephemeral secp256r1 key in AndroidKeyStore with attestation challenge
     *    (StrongBox first, falling back to TEE if StrongBox is unavailable).
     * 3. Extract X.509 certificate chain and immediately delete the ephemeral key alias.
     * 4. POST /v1/attest with challenge + Base64 DER chain -> receive Firebase App Check JWT.
     */
    fun fetchAttestedAppCheckToken(): AttestGateAppCheckToken {
        val cleanBaseUrl = baseUrl.trim().trimEnd('/')
        val parsedBase = URL(cleanBaseUrl)
        require(parsedBase.protocol.equals("https", ignoreCase = true) && parsedBase.host.isNotEmpty()) {
            "ATTEST_GATE_BASE_URL must be a valid https:// URL."
        }

        // Step 1: Fetch single-use challenge from attest-gate.
        val challengeResponse = httpPostJson("$cleanBaseUrl/v1/challenge", "{}")
        val challengeB64Url = challengeResponse.getString("challenge")
        val nonceBytes = Base64.decode(
            challengeB64Url,
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        require(nonceBytes.size in MIN_NONCE_BYTES..MAX_NONCE_BYTES) {
            "attest-gate returned an invalid attestation challenge length (${nonceBytes.size} bytes)."
        }

        // Step 2 & 3: Generate ephemeral attested EC P-256 key, read cert chain, delete alias.
        val certChainB64 = generateHardwareAttestationChain(nonceBytes)

        // Step 4: Exchange hardware attestation chain for an official Firebase App Check JWT.
        val attestPayload = JSONObject().apply {
            put("challenge", challengeB64Url)
            put("certificate_chain", JSONArray(certChainB64))
        }
        val attestResponse = httpPostJson("$cleanBaseUrl/v1/attest", attestPayload.toString())

        val token = attestResponse.getString("token")
        var expireTimeMillis = attestResponse.getLong("expire_time_millis")
        // Guard against servers returning Unix seconds instead of milliseconds.
        if (expireTimeMillis in 1L..99_999_999_999L) {
            expireTimeMillis *= 1000L
        }
        return AttestGateAppCheckToken(token, expireTimeMillis)
    }

    private fun generateHardwareAttestationChain(nonceBytes: ByteArray): List<String> {
        val alias = "attest_gate_ephemeral_${UUID.randomUUID()}"
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

        try {
            generateEphemeralEcKey(alias, nonceBytes)

            val certs = keyStore.getCertificateChain(alias)
                ?: throw IllegalStateException("AndroidKeyStore returned null certificate chain")
            if (certs.size < 2) {
                throw IllegalStateException("Expected certificate chain length >= 2, got ${certs.size}")
            }

            return certs.map { cert ->
                Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
            }
        } finally {
            // Always delete the ephemeral key immediately so Keystore slots are never leaked.
            runCatching {
                if (keyStore.containsAlias(alias)) {
                    keyStore.deleteEntry(alias)
                }
            }.onFailure { err ->
                Log.w(TAG, "Failed to delete ephemeral attestation key: ${err.message}")
            }
        }
    }

    private fun generateEphemeralEcKey(alias: String, nonceBytes: ByteArray) {
        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)

        fun buildSpec(useStrongBox: Boolean): KeyGenParameterSpec {
            val builder = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setAttestationChallenge(nonceBytes)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                builder.setIsStrongBoxBacked(useStrongBox)
            }
            return builder.build()
        }

        // Prefer StrongBox (dedicated secure element) when available on Android 9+ (API 28+);
        // catch StrongBoxUnavailableException (and OEM ProviderException wrappers) to fall back to TEE.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                kpg.initialize(buildSpec(useStrongBox = true))
                kpg.generateKeyPair()
                return
            } catch (_: StrongBoxUnavailableException) {
                // Fall back to hardware TEE
            } catch (e: ProviderException) {
                if (e.cause !is StrongBoxUnavailableException) {
                    Log.w(TAG, "StrongBox keygen failed; falling back to hardware TEE")
                }
            }
        }

        kpg.initialize(buildSpec(useStrongBox = false))
        kpg.generateKeyPair()
    }

    private fun httpPostJson(urlString: String, jsonBody: String): JSONObject {
        val targetUrl = URL(urlString)
        require(targetUrl.protocol.equals("https", ignoreCase = true)) {
            "Refusing non-HTTPS attest-gate request."
        }
        val conn = (targetUrl.openConnection() as HttpsURLConnection).apply {
            requestMethod = "POST"
            instanceFollowRedirects = false
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            doInput = true
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("Accept", "application/json")
        }

        try {
            OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { writer ->
                writer.write(jsonBody)
                writer.flush()
            }

            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val body = stream?.use { input ->
                val baos = ByteArrayOutputStream()
                val buf = ByteArray(4096)
                var total = 0
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    total += read
                    if (total > MAX_RESPONSE_BYTES) {
                        throw IllegalStateException("attest-gate response exceeded $MAX_RESPONSE_BYTES bytes")
                    }
                    baos.write(buf, 0, read)
                }
                baos.toString(Charsets.UTF_8.name())
            }.orEmpty()

            if (status !in 200..299) {
                val safeSummary = body.replace(Regex("\\s+"), " ").take(200)
                throw IllegalStateException("attest-gate returned HTTP $status: $safeSummary")
            }

            return JSONObject(body)
        } finally {
            conn.disconnect()
        }
    }
}

/**
 * [AppCheckProviderFactory] for registering [AttestGateAppCheckProvider] with Firebase App Check.
 */
class AttestGateAppCheckProviderFactory(
    private val attestGateBaseUrl: String,
) : AppCheckProviderFactory {

    override fun create(firebaseApp: FirebaseApp): AppCheckProvider {
        return AttestGateAppCheckProvider(baseUrl = attestGateBaseUrl)
    }
}
