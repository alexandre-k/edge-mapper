import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
if (hasKeystoreProperties) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

// Automatically activate Firebase Google Services as soon as google-services.json is placed in android/app/.
// Keeping this conditional lets you compile and install the APK straight away before setting up Firebase.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "com.edgemapper.app"
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.edgemapper.app"
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                val storeFilePath = keystoreProperties.getProperty("storeFile")?.trim()
                require(!storeFilePath.isNullOrEmpty()) {
                    "android/key.properties is missing storeFile"
                }
                val resolvedStoreFile = file(storeFilePath).takeIf { it.exists() }
                    ?: rootProject.file(storeFilePath)
                require(resolvedStoreFile.exists()) {
                    "Keystore file not found: ${resolvedStoreFile.path} (check storeFile in android/key.properties)"
                }
                storeFile = resolvedStoreFile
                if (resolvedStoreFile.extension.equals("p12", ignoreCase = true) ||
                    resolvedStoreFile.extension.equals("pfx", ignoreCase = true)
                ) {
                    storeType = "PKCS12"
                }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        getByName("profile") {
            if (hasKeystoreProperties) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        release {
            // Use android/key.properties when present; fall back to debug keys so zero-config builds still work.
            val isCi = System.getenv("CI") == "true"
            require(!isCi || hasKeystoreProperties) {
                "android/key.properties is required for CI release builds"
            }
            signingConfig = if (hasKeystoreProperties) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Multilingual on-device OCR models (bundled locally for 100% offline use on Pixel 6a)
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
    // Match firebase_core's Firebase BoM; only core App Check custom provider API is needed in Kotlin
    // (Flutter's firebase_ai plugin handles Gemini requests in Dart).
    implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
    implementation("com.google.firebase:firebase-appcheck")
}

flutter {
    source = "../.."
}
