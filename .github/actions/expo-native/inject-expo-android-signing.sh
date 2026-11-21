#!/usr/bin/env sh
# Inject release/debug signing from android/key.properties into Expo's generated
# android/app/build.gradle (prebuild does not wire key.properties by default).
set -eu

BUILD_GRADLE="${1:-${FULL_PROJECT_DIR}/android/app/build.gradle}"

if [ ! -f "$BUILD_GRADLE" ]; then
  echo "❌ No Android build.gradle at ${BUILD_GRADLE}" >&2
  exit 1
fi

echo "🤖 Ensuring Expo Android release signing in ${BUILD_GRADLE}..."

BUILD_GRADLE="$BUILD_GRADLE" node <<'NODE'
const fs = require("fs");
const path = process.env.BUILD_GRADLE;
let contents = fs.readFileSync(path, "utf8");

const loadBlock = `def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}

`;

if (!contents.includes("keystoreProperties['releaseStoreFile']")) {
  if (!/android\s*\{/.test(contents)) {
    console.error("❌ Could not find android { block in build.gradle");
    process.exit(1);
  }
  contents = contents.replace(/android\s*\{/, `${loadBlock}android {`);

  const releaseSigning = `        release {
            if (keystorePropertiesFile.exists()) {
                def releaseStore = keystoreProperties['releaseStoreFile']
                storeFile releaseStore.startsWith("/") ? file(releaseStore) : rootProject.file(releaseStore)
                storePassword keystoreProperties['releaseStorePassword']
                keyAlias keystoreProperties['releaseKeyAlias']
                keyPassword keystoreProperties['releaseKeyPassword']
            }
        }
`;

  if (/signingConfigs\s*\{/.test(contents)) {
    contents = contents.replace(/signingConfigs\s*\{/, (match) => `${match}\n${releaseSigning}`);
  } else {
    contents = contents.replace(
      /android\s*\{/,
      (match) => `${match}\n    signingConfigs {\n${releaseSigning}    }\n`
    );
  }
}

// Force every release buildType to use signingConfigs.release (Expo defaults to debug).
function forceReleaseSigning(src) {
  const buildTypesIdx = src.search(/buildTypes\s*\{/);
  if (buildTypesIdx === -1) {
    console.error("❌ Could not find buildTypes { in build.gradle");
    process.exit(1);
  }

  // Find the release { block inside buildTypes by brace matching.
  const releaseMatch = src.slice(buildTypesIdx).match(/release\s*\{/);
  if (!releaseMatch) {
    console.error("❌ Could not find buildTypes.release { in build.gradle");
    process.exit(1);
  }
  const releaseStart = buildTypesIdx + releaseMatch.index + releaseMatch[0].length;

  let depth = 1;
  let i = releaseStart;
  while (i < src.length && depth > 0) {
    const ch = src[i];
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    i += 1;
  }
  const releaseEnd = i - 1; // position of closing }
  let body = src.slice(releaseStart, releaseEnd);

  body = body
    .replace(/signingConfig\s*=\s*signingConfigs\.\w+/g, "")
    .replace(/signingConfig\s+signingConfigs\.\w+/g, "");

  if (!/signingConfig\s+signingConfigs\.release/.test(body)) {
    body = `\n            signingConfig signingConfigs.release` + body;
  }

  return src.slice(0, releaseStart) + body + src.slice(releaseEnd);
}

contents = forceReleaseSigning(contents);

if (!/signingConfig\s+signingConfigs\.release/.test(contents)) {
  console.error("❌ Failed to force signingConfigs.release for release buildType");
  process.exit(1);
}

// Guard: release block must not still point at debug.
const releaseBlock = contents.match(/buildTypes\s*\{[\s\S]*release\s*\{([\s\S]*?)\n\s*\}/);
if (releaseBlock && /signingConfigs\.debug/.test(releaseBlock[1])) {
  console.error("❌ release buildType still references signingConfigs.debug");
  process.exit(1);
}

fs.writeFileSync(path, contents);
console.log("✅ Wrote signing config to", path);

// Print a short snippet for CI logs.
const snippet = contents.match(/buildTypes\s*\{[\s\S]{0,800}/);
if (snippet) {
  console.log("--- buildTypes snippet ---");
  console.log(snippet[0].split("\n").slice(0, 40).join("\n"));
  console.log("--- end snippet ---");
}
NODE

echo "✅ Expo Android signing injection complete."
