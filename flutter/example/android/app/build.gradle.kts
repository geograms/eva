plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "radio.geogram.eva"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "radio.geogram.eva"
        // libcactus.so is built only for arm64-v8a, so restrict the APK to that ABI.
        // The `record` mic plugin requires API 23+, so floor minSdk at 23.
        minSdk = maxOf(23, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Build (or restore from cache) the native FFI library before assembling the
// app, so it never has to be produced by hand. native/build.sh is
// content-addressed: it skips in ~0.02s when libcactus.so is already current and
// restores from a machine-level cache otherwise (see native/README.md). A real
// change to the native sources triggers a recompile, which needs the Android
// NDK. Skipped on Windows / if the script is absent (the lib is arm64-only and
// developed on Linux/macOS).
val ensureNativeFfi by tasks.registering(Exec::class) {
    val script = rootProject.file("../native/build.sh")
    onlyIf {
        script.exists() &&
            !System.getProperty("os.name").lowercase().contains("windows")
    }
    workingDir = rootProject.projectDir
    // Expose the SDK so build.sh can locate the NDK if an actual recompile is
    // needed (cache hits don't need it).
    environment("ANDROID_HOME", android.sdkDirectory.absolutePath)
    commandLine("bash", script.absolutePath)
}

tasks.named("preBuild") {
    dependsOn(ensureNativeFfi)
}
