#!/usr/bin/env bash
set -euo pipefail

require_variables() {
  local name
  for name in "$@"; do
    if [ -z "${!name:-}" ]; then
      echo "::error::Missing ${name}. Resync the selected native signing connection in MainPath."
      exit 1
    fi
  done
}

case "${MAINPATH_NATIVE_OPERATION:-}" in
  android) require_variables ANDROID_APP_IDENTIFIER ANDROID_KEYSTORE_BASE64 ANDROID_KEYSTORE_PASSWORD ;;
  ios) require_variables IOS_APP_IDENTIFIER APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_KEY_ISSUER_ID APP_STORE_CONNECT_KEY APP_STORE_CONNECT_DEVELOPER_TEAM_ID MATCH_GIT_URL MATCH_GIT_BASIC_AUTHORIZATION MATCH_PASSWORD ;;
  publish-android|publish-ios)
    if [ "${GITHUB_EVENT_NAME:-}" != workflow_dispatch ] || [ "${GITHUB_REF:-}" != refs/heads/main ]; then
      echo "::error::Beta distribution requires an explicit workflow dispatch on main."
      exit 1
    fi
    if [ "$MAINPATH_NATIVE_OPERATION" = publish-android ]; then
      require_variables ANDROID_APP_IDENTIFIER PLAY_STORE_CREDENTIALS_BASE64
    else
      require_variables IOS_APP_IDENTIFIER APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_KEY_ISSUER_ID APP_STORE_CONNECT_KEY
    fi
    ;;
  *) echo '::error::Unsupported native operation'; exit 1 ;;
esac

export CI=true EXPO_NO_TELEMETRY=1 FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_HIDE_CHANGELOG=1
# shellcheck source=sanitize-expo-env.sh
. "$GITHUB_ACTION_PATH/sanitize-expo-env.sh"
export MAINPATH_PROJECT_ROOT="$PWD"
MAINPATH_SIGNING_DIR="$(mktemp -d "${RUNNER_TEMP:?}/mainpath-native.XXXXXX")"
export MAINPATH_SIGNING_DIR
cleanup() {
  rm -f "${MAINPATH_PROJECT_ROOT}/android/key.properties"
  rm -rf "$MAINPATH_SIGNING_DIR"
}
trap cleanup EXIT

case "$MAINPATH_NATIVE_OPERATION" in
  android|ios)
    if [ ! -f package-lock.json ]; then
      echo '::error::Native CI requires a committed package-lock.json.'
      exit 1
    fi
    node "$GITHUB_ACTION_PATH/prepare.cjs"
    npm ci
    npx --no-install expo config --type public --json > "$MAINPATH_SIGNING_DIR/expo-public.json"
    node "$GITHUB_ACTION_PATH/validate-config.cjs"
    npx --no-install expo prebuild --platform "$MAINPATH_NATIVE_OPERATION" --no-install
    ;;
esac

if [ "$MAINPATH_NATIVE_OPERATION" = android ]; then
  node "$GITHUB_ACTION_PATH/android-signing.cjs"
  bash "$GITHUB_ACTION_PATH/inject-expo-android-signing.sh" "$PWD/android/app/build.gradle"
  keytool -list -keystore "$MAINPATH_SIGNING_DIR/upload.jks" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD -alias "${ANDROID_KEYSTORE_ALIAS:-upload}" > /dev/null
  cd android
  chmod +x gradlew
  ./gradlew --no-daemon --max-workers=2 bundleRelease assembleRelease
  # Signature validation fails if Gradle produced an unsigned/debug artifact.
  aab="$(find app/build/outputs/bundle/release -maxdepth 1 -name '*.aab' -print -quit)"
  test -n "$aab"
  LC_ALL=C jarsigner -verify "$aab" | grep -q 'jar verified'
  keytool -exportcert -keystore "$MAINPATH_SIGNING_DIR/upload.jks" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD -alias "${ANDROID_KEYSTORE_ALIAS:-upload}" \
    -file "$MAINPATH_SIGNING_DIR/expected.der" > /dev/null
  keytool -printcert -rfc -jarfile "$aab" > "$MAINPATH_SIGNING_DIR/actual.pem"
  openssl x509 -in "$MAINPATH_SIGNING_DIR/actual.pem" -outform DER -out "$MAINPATH_SIGNING_DIR/actual.der"
  cmp "$MAINPATH_SIGNING_DIR/expected.der" "$MAINPATH_SIGNING_DIR/actual.der"
  apksigner="$(find "${ANDROID_HOME:?}/build-tools" -maxdepth 2 -type f -name apksigner | sort | tail -n 1)"
  test -n "$apksigner"
  apk="$(find app/build/outputs/apk/release -maxdepth 1 -name '*.apk' -print -quit)"
  test -n "$apk"
  "$apksigner" verify "$apk"
  exit 0
fi

# Keep signing files outside the checkout and outside uploaded artifact paths.
cp "$GITHUB_ACTION_PATH/Gemfile" "$MAINPATH_SIGNING_DIR/Gemfile"
export BUNDLE_GEMFILE="$MAINPATH_SIGNING_DIR/Gemfile"
export BUNDLE_PATH="$MAINPATH_SIGNING_DIR/gems"
bundle install --jobs 4 --retry 3
mkdir -p "$MAINPATH_SIGNING_DIR/fastlane"
cp "$GITHUB_ACTION_PATH/Fastfile" "$MAINPATH_SIGNING_DIR/fastlane/Fastfile"

case "$MAINPATH_NATIVE_OPERATION" in
  ios)
    bundle exec pod install --project-directory="$MAINPATH_PROJECT_ROOT/ios"
    cd "$MAINPATH_SIGNING_DIR"
    bundle exec fastlane build_ios_release
    ;;
  publish-ios)
    cd "$MAINPATH_SIGNING_DIR"
    bundle exec fastlane internal_testflight
    ;;
  publish-android)
    cd "$MAINPATH_SIGNING_DIR"
    bundle exec fastlane internal_play
    ;;
esac
