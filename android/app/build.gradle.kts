// The Android app. AGP 9 compiles Kotlin itself; no AndroidX, no libraries beyond :core. Its one
// native library is our own C (src/main/jni), built with the NDK.
plugins { id("com.android.application") }

// One version for every platform: VERSION at the repo root. versionCode must only grow: 1.2.3 → 10203.
val appVersion = rootProject.file("../VERSION").readText().trim()
val appVersionCode = appVersion.split(".").map { it.toInt() }.let { (a, b, c) -> a * 10000 + b * 100 + c }

// Release signing: the key never enters the repo. scripts/keystore.sh makes it once
// (~/.cicada-android/release.jks, its password in the Keychain); scripts/build.sh and CI hand it
// over in these variables. Without them the release build stays unsigned: never the debug key.
val releaseKeystore = System.getenv("CICADA_KEYSTORE")?.let { file(it) }?.takeIf { it.isFile }

android {
    namespace = "com.wquguru.cicada"
    compileSdk = 36
    // 说话人识别's voiceprint library (src/main/jni): scripts/install-sdk.sh and CI install this NDK.
    ndkVersion = "29.0.14206865"
    defaultConfig {
        applicationId = "com.wquguru.cicada"
        minSdk = 29
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersion
        // Every phone (64- and 32-bit ARM) and the arm64 or x86_64 emulator: an APK with native code
        // doesn't install on an ABI it leaves out.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }
    externalNativeBuild { ndkBuild { path = file("src/main/jni/Android.mk") } }
    // The voiceprint weights stay uncompressed: NativeVoiceprints sizes the asset to know its copy is whole.
    androidResources { noCompress += "bin" }
    signingConfigs {
        if (releaseKeystore != null) create("release") {
            storeFile = releaseKeystore
            // PKCS12 has one password for the store and the key.
            storePassword = System.getenv("CICADA_KEYSTORE_PASSWORD")
            keyPassword = System.getenv("CICADA_KEYSTORE_PASSWORD")
            keyAlias = System.getenv("CICADA_KEY_ALIAS") ?: "cicada"
        }
    }
    buildTypes {
        // The dev build has its own id (so its own records and key), log and the debug receiver
        // that scripts/cicadactl.sh drives.
        debug { applicationIdSuffix = ".dev"; versionNameSuffix = "-dev" }
        release {
            isMinifyEnabled = false
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { buildConfig = true }
    sourceSets {
        getByName("main") {
            assets.directories.add(layout.buildDirectory.dir("generated/strings").get().asFile.path)
            assets.directories.add(layout.buildDirectory.dir("generated/voiceprint").get().asFile.path)
        }
    }
}
kotlin { jvmToolchain(21) }

dependencies { implementation(project(":core")) }

// The UI text: the Mac's Localizable.strings (and .stringsdict, its plurals) and the Android-only Android.strings, both keyed by
// the Chinese, into assets/Resources/<lang>.lproj/.
val copyStrings by tasks.registering(Sync::class) {
    into(layout.buildDirectory.dir("generated/strings/Resources"))
    for (lang in listOf("zh-Hans", "en", "ja", "ko")) {
        from(rootProject.file("../Resources/$lang.lproj")) { include("Localizable.strings", "Localizable.stringsdict"); into("$lang.lproj") }
        from(file("src/main/strings/$lang.lproj")) { include("Android.strings"); into("$lang.lproj") }
    }
}
// 说话人识别's weights: the Linux app's linux/models/voiceprint.bin (the Mac's model, converted by
// linux/scripts/convert-voiceprint.py), not a second copy in the repo.
val copyVoiceprint by tasks.registering(Sync::class) {
    from(rootProject.file("../linux/models")) { include("voiceprint.bin") }
    into(layout.buildDirectory.dir("generated/voiceprint"))
}
tasks.named("preBuild") { dependsOn(copyStrings, copyVoiceprint) }
