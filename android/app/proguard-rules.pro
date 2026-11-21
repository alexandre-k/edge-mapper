# Keep Google ML Kit classes for release APK builds
-keep class com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.internal.mlkit_** { *; }
-dontwarn com.google.android.gms.internal.mlkit_**

# Keep only entry points required by AndroidManifest / Flutter / Firebase App Check
-keep class com.edgemapper.app.MainActivity { *; }
-keep class com.edgemapper.attestation.AttestGateAppCheckProviderFactory { *; }
-keep class com.edgemapper.attestation.AttestGateAppCheckProvider { *; }
-keep class com.edgemapper.attestation.AttestGateAppCheckToken { *; }
