#!/usr/bin/env bash
# Fixes the package-conflict install error AND wires up real release
# signing (used only when you've set up android/app/key.properties
# locally -- see the separate key.properties + ulimit-release.jks
# files, which are NOT in this script since they're secrets and
# must never be committed to git).
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "android/app"
cat > "android/app/build.gradle" << 'PATCH_EOF'
plugins {
    id "com.android.application"
    id "kotlin-android"
    id "dev.flutter.flutter-gradle-plugin"
}

// Real release signing, loaded from android/app/key.properties -- a
// file that is NOT committed to git (see .gitignore) and must be
// created locally with the real keystore credentials. If it's absent
// (CI, or a fresh clone), releaseSigningReady stays false and the
// release build type falls back to the checked-in testing keystore
// below instead of failing the build.
def keyPropertiesFile = file("key.properties")
def keyProperties = new Properties()
def releaseSigningReady = keyPropertiesFile.exists()
if (releaseSigningReady) {
    keyProperties.load(new FileInputStream(keyPropertiesFile))
}

android {
    namespace "com.ulimit.app"
    compileSdk 34
    ndkVersion flutter.ndkVersion

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17
    }

    sourceSets {
        main.java.srcDirs += "src/main/kotlin"
    }

    defaultConfig {
        applicationId "com.ulimit.app"
        // sqlite3_flutter_libs and drift both work fine from API 23+;
        // going lower buys negligible reach in 2026 and complicates the
        // AccessibilityService APIs used above.
        minSdk 23
        targetSdk 34
        versionCode flutter.versionCode
        versionName flutter.versionName
    }

    // A fixed, checked-in keystore for testing/sideload/CI builds --
    // NOT a real release key. Its whole point is that every build, on
    // any machine or CI run without android/app/key.properties set up,
    // signs with the exact same certificate, so installing a new build
    // over an old one is always a valid "update" rather than Android
    // refusing with "Package conflicts with an existing package."
    // (Previously this pointed at signingConfigs.debug -- Android's
    // AMBIENT ~/.android/debug.keystore, which doesn't exist on GitHub
    // Actions runners and gets freshly auto-generated with a different
    // random key on every single CI run.)
    signingConfigs {
        testing {
            storeFile file("ulimit-testing.jks")
            storePassword "ulimit123"
            keyAlias "ulimit"
            keyPassword "ulimit123"
        }
        if (releaseSigningReady) {
            release {
                storeFile file(keyProperties["storeFile"])
                storePassword keyProperties["storePassword"]
                keyAlias keyProperties["keyAlias"]
                keyPassword keyProperties["keyPassword"]
            }
        }
    }

    buildTypes {
        release {
            // The real key when android/app/key.properties exists
            // locally; the shared testing key otherwise, so CI and
            // fresh clones still produce a consistently-signed,
            // installable APK without ever touching the real secret.
            signingConfig releaseSigningReady ? signingConfigs.release : signingConfigs.testing
            minifyEnabled false
            shrinkResources false
        }
        debug {
            signingConfig signingConfigs.testing
        }
    }
}

flutter {
    source "../.."
}

dependencies {
    // Biometric availability check (BiometricManager) used in
    // MainActivity.kt's isBiometricAvailable().
    implementation "androidx.biometric:biometric:1.1.0"
    implementation "androidx.core:core-ktx:1.13.1"
}
PATCH_EOF

mkdir -p "."
cat > ".gitignore" << 'PATCH_EOF'
# Flutter/Dart
.dart_tool/
.packages
build/
.flutter-plugins
.flutter-plugins-dependencies
.pub-cache/
.pub/
pubspec.lock

# Drift/build_runner generated code — regenerated via build_runner,
# not hand-edited, so it doesn't need to live in git history. Remove
# this line if your team prefers committing generated code for
# reproducible CI builds without a build_runner step.
*.g.dart

# Android
android/.gradle/
android/captures/
android/gradlew
android/gradlew.bat
android/local.properties
android/**/GeneratedPluginRegistrant.java
android/key.properties
android/app/key.properties

# Real Play Store release keys only -- NOT the checked-in
# android/app/ulimit-testing.jks used for consistent testing/sideload/CI
# signing (that one is intentionally committed, and has no real secret
# value). Your real keystore, whatever you name it, is excluded by this
# key.properties exclusion above pointing at it -- these two extra
# patterns are just a backstop in case a real key ever gets named
# something generic like release.jks and dropped in without a
# key.properties entry yet.
*-release.jks
release.keystore

# iOS
ios/Flutter/.last_build_id
ios/Pods/
ios/.symlinks/
ios/Flutter/Flutter.framework
ios/Flutter/Flutter.podspec
**/*.xcuserstate

# IDE
.idea/
.vscode/
*.iml

# OS
.DS_Store
Thumbs.db

# Local env / secrets — this app has no backend, but keep this in
# place for API keys (e.g. future crash reporting, IAP config) rather
# than adding it later after something's already been committed.
.env
*.env.local
PATCH_EOF

mkdir -p "android/app"
base64 -d > "android/app/ulimit-testing.jks" << 'B64_EOF'
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
B64_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Fix package-conflict install error with a fixed testing keystore; wire up real release signing via android/app/key.properties when present"
git push

echo "Pushed. Removing this script."
echo ""
echo "Uninstall the currently-installed Ulimit app once before your"
echo "next install -- its old signature wont match this fixed key."
echo ""
echo "For REAL release builds: copy the key.properties file I gave you"
echo "separately (and ulimit-release.jks) into android/app/ -- both are"
echo "gitignored and will never be committed."
rm -- "$0"
