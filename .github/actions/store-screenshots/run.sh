#!/usr/bin/env bash
# Capture and frame store screenshots on a GitHub-hosted runner.
# CI_HOSTED_RUNNER and RUNNER_ENVIRONMENT are set by the action so ap-ci-quota
# does not bill the organization when a quota check runs inside the job.
set -euo pipefail

if [ "${STORE_SCREENSHOTS_FORCE:-false}" != "true" ] && [ ! -f .doppelt-digital-create-new-screenshots ]; then
  echo "No screenshot trigger. Add .doppelt-digital-create-new-screenshots to capture."
  exit 0
fi

ROOT="$(pwd)"
PIPELINE_LIB_DIR="${RUNNER_TEMP:-/tmp}/app-project-pipelines"

ensure_pipeline_lib() {
  if [ -d "${PIPELINE_LIB_DIR}/frontend-template/static/test-goldens" ]; then
    return 0
  fi
  rm -rf "${PIPELINE_LIB_DIR}"
  git clone --depth 1 https://gitlab.com/doppelt-digital/app-project-pipelines.git "${PIPELINE_LIB_DIR}"
}

ensure_imagemagick() {
  if command -v magick >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq imagemagick
  elif command -v brew >/dev/null 2>&1; then
    brew install imagemagick
  else
    echo "ImageMagick is required for Frameit."
    exit 1
  fi
}

ensure_bundle() {
  ensure_pipeline_lib
  export GEM_HOME="${ROOT}/.gem"
  export PATH="${GEM_HOME}/bin:${PATH}"
  # Fastlane rejects Bundler 3 and 4. GitHub macOS images ship Bundler 4.
  gem install bundler:2.7.2 --no-document
  hash -r || true
  export BUNDLE_GEMFILE="${PIPELINE_LIB_DIR}/frontend-template/static/test-goldens/Gemfile"
  export BUNDLE_PATH="${ROOT}/.bundle-frameit"
  export BUNDLE_USER_HOME="${BUNDLE_PATH}"
  export BUNDLE_USER_CACHE="${BUNDLE_PATH}/cache"
  mkdir -p "${BUNDLE_USER_CACHE}"
  bundle config set --local path "${BUNDLE_PATH}"
  bundle install
}

capture() {
  if [ -f package.json ] && grep -q '"screenshots"' package.json; then
    if [ -f package-lock.json ]; then
      npm ci
    else
      npm install
    fi
    npx playwright install --with-deps chromium || npx playwright install chromium
    rm -rf test/goldens/fastlane/screenshots
    mkdir -p test/goldens/fastlane/screenshots
    npm run screenshots
    return 0
  fi
  if [ -f pubspec.yaml ]; then
    ensure_pipeline_lib
    ensure_imagemagick
    rsync -a "${PIPELINE_LIB_DIR}/frontend-template/static/" "${ROOT}/"
    flutter pub get
    dart_defines=()
    for env_file in \
      env/shared.custom.env \
      env/shared.generated.env \
      env/screenshot-tests.custom.env \
      env/screenshot-tests.generated.env
    do
      if [ -f "${env_file}" ]; then
        dart_defines+=(--dart-define-from-file="${env_file}")
      fi
    done
    flutter test --update-goldens "${dart_defines[@]}"
    dart "${PIPELINE_LIB_DIR}/frontend-template/static/test/scripts/test_post_actions.dart"
    return 0
  fi
  if [ -f ios/fastlane/Snapfile ]; then
    ensure_bundle
    (
      cd ios
      bundle exec fastlane snapshot
    )
    python3 "${PIPELINE_LIB_DIR}/frontend-template/general/bin/normalize-native-ios-screenshots.py" \
      --project-dir "${ROOT}"
    return 0
  fi
  if [ -f gradlew ]; then
    chmod +x gradlew
    ./gradlew assembleDebug
    echo "Android debug build finished. Screenshot capture still needs a project screenshots script."
    return 0
  fi
  echo "No screenshot capture entry point found."
  exit 1
}

capture

if [ ! -f test/goldens/Framefile.json ]; then
  echo "Captured files are present, but test/goldens/Framefile.json is missing, so nothing was framed."
  exit 1
fi

ensure_imagemagick
ensure_bundle

cd test/goldens
shopt -s nullglob
mkdir -p fastlane/screenshots
cp Framefile.json fastlane/screenshots/Framefile.json

frame_locale() {
  local locale="$1"
  local shot_dir="fastlane/screenshots/${locale}"
  if [ ! -d "${shot_dir}" ]; then
    echo "No PNGs for ${locale}"
    return 0
  fi
  if [ ! -f "${locale}/title.strings" ]; then
    echo "Missing title.strings for ${locale}"
    exit 1
  fi
  cp "${locale}/title.strings" "${shot_dir}/title.strings"
  if [ -f "${locale}/keyword.strings" ]; then
    cp "${locale}/keyword.strings" "${shot_dir}/keyword.strings"
  fi
  local held
  held="$(mktemp -d)"
  for platform in android ios; do
    rm -rf "${held}"
    mkdir -p "${held}"
    local device_re pending
    if [ "${platform}" = "android" ]; then
      device_re='samsung_galaxy|google_pixel|nexus_|pixel_'
    else
      device_re='iphone|ipad'
    fi
    local png base lower
    for png in "${shot_dir}"/*.png; do
      base="$(basename "${png}")"
      lower="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
      if ! printf '%s' "${lower}" | grep -Eq "${device_re}"; then
        mv "${png}" "${held}/${base}"
      fi
    done
    pending="$(find "${shot_dir}" -maxdepth 1 -type f -name '*.png' ! -iname '*framed*' | wc -l | tr -d ' ')"
    if [ "${pending}" -eq 0 ]; then
      echo "No unframed ${platform} screenshots for ${locale}"
    else
      echo "Framing ${pending} ${platform} screenshot(s) for ${locale}"
      if [ "${platform}" = "android" ]; then
        sed -i.bak 's/"use_platform": "[^"]*"/"use_platform": "ANDROID"/' fastlane/screenshots/Framefile.json
        sed -i.bak 's/"device_frame_version": "[^"]*"/"device_frame_version": "100"/' fastlane/screenshots/Framefile.json
        rm -f fastlane/screenshots/Framefile.json.bak
        bundle exec ruby "${PIPELINE_LIB_DIR}/frontend-template/general/bin/seed-android-frameit-frames.rb"
        (
          cd fastlane/screenshots
          bundle exec fastlane frameit android --resume
        )
      else
        sed -i.bak 's/"use_platform": "[^"]*"/"use_platform": "IOS"/' fastlane/screenshots/Framefile.json
        rm -f fastlane/screenshots/Framefile.json.bak
        (
          cd fastlane/screenshots
          bundle exec fastlane frameit ios --resume
        )
      fi
    fi
    for png in "${held}"/*.png; do
      mv "${png}" "${shot_dir}/$(basename "${png}")"
    done
  done
  rm -rf "${held}"
}

for locale_dir in */; do
  locale="${locale_dir%/}"
  case "${locale}" in
    fastlane|fonts|static_files) continue ;;
  esac
  frame_locale "${locale}"
done

framed="$(find fastlane/screenshots -type f -iname '*framed*.png' | wc -l | tr -d ' ')"
echo "Framed PNGs: ${framed}"
if [ "${framed}" -eq 0 ]; then
  echo "Frameit produced no framed screenshots."
  exit 1
fi
