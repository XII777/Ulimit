#!/usr/bin/env bash
# Fixes: 'Minimum supported Gradle version is 8.7. Current version is 8.0.'
# No gradle-wrapper.properties was committed, so Flutter's tooling
# auto-bootstrapped a default (Gradle 8.0) incompatible with AGP 8.3.2.
set -e

if [ ! -f pubspec.yaml ]; then
  echo "Run this from inside your repo root (where pubspec.yaml lives)."
  exit 1
fi

mkdir -p "android/gradle/wrapper"
cat > "android/gradle/wrapper/gradle-wrapper.properties" << 'PATCH_EOF'
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.9-all.zip
PATCH_EOF

git add -A
git -c user.email="dev@ulimit.app" -c user.name="Ulimit Dev" commit -m "Pin Gradle wrapper to 8.9 (AGP 8.3.2 requires 8.7+; none was committed so Flutter defaulted to 8.0)"
git push

echo "Pushed. Removing this script."
rm -- "$0"
