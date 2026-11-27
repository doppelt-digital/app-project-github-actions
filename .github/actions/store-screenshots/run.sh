#!/usr/bin/env bash
# Capture and frame store screenshots. GitHub-hosted runners set CI_HOSTED_RUNNER
# and RUNNER_ENVIRONMENT so ap-ci-quota does not bill the organization.
set -euo pipefail

if [ "${STORE_SCREENSHOTS_FORCE:-false}" != "true" ] && [ ! -f .doppelt-digital-create-new-screenshots ]; then
  echo "No screenshot trigger. Add .doppelt-digital-create-new-screenshots to capture."
  exit 0
fi

capture() {
  if [ -f package.json ] && grep -q '"screenshots"' package.json; then
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npx playwright install --with-deps chromium || npx playwright install chromium
    npm run screenshots
    return
  fi
  if [ -f pubspec.yaml ]; then
    flutter pub get
    flutter test --update-goldens
    if [ -f test/scripts/test_post_actions.dart ]; then
      dart test/scripts/test_post_actions.dart
    fi
    return
  fi
  if [ -f ios/fastlane/Snapfile ] || [ -f fastlane/Snapfile ]; then
    bundle install
    bundle exec fastlane snapshot
    return
  fi
  if [ -f gradlew ]; then
    chmod +x gradlew
    ./gradlew assembleDebug
    echo "Android debug build finished. Screenshot capture still needs a project screenshots script or connected tests."
    return
  fi
  echo "No screenshot capture entry point found."
  exit 1
}

capture

if [ ! -f test/goldens/Framefile.json ]; then
  echo "Captured files are present, but test/goldens/Framefile.json is missing, so nothing was framed."
  exit 1
fi

gem install fastlane --no-document
cd test/goldens
shopt -s nullglob
for locale_dir in */; do
  locale="${locale_dir%/}"
  case "$locale" in
    fastlane|fonts|static_files) continue ;;
  esac
  if [ ! -d "fastlane/screenshots/$locale" ]; then
    echo "No PNGs for $locale"
    continue
  fi
  if [ ! -f "$locale/title.strings" ]; then
    echo "Missing title.strings for $locale"
    exit 1
  fi
  mkdir -p "fastlane/screenshots/$locale"
  cp "$locale/title.strings" "fastlane/screenshots/$locale/title.strings"
  cp Framefile.json fastlane/screenshots/Framefile.json
  (
    cd fastlane/screenshots
    fastlane frameit ios --resume || true
    fastlane frameit android --resume || true
  )
done

framed="$(find fastlane/screenshots -type f -iname '*framed*.png' | wc -l | tr -d ' ')"
echo "Framed PNGs: ${framed}"
if [ "${framed}" -eq 0 ]; then
  echo "Frameit produced no framed screenshots."
  exit 1
fi
