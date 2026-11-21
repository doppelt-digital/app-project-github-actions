const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { buildNumber, prepare } = require('./prepare.cjs');
const { writeSigning, escapeProperty } = require('./android-signing.cjs');

function fixture(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mainpath-native-test-'));
  try { fn(root); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('native reruns get increasing version codes and reject invalid/overflow configuration', () => {
  assert.equal(buildNumber({ GITHUB_RUN_NUMBER: '42', GITHUB_RUN_ATTEMPT: '1' }), 4201);
  assert.equal(buildNumber({ GITHUB_RUN_NUMBER: '42', GITHUB_RUN_ATTEMPT: '2', BUILD_NUMBER_OFFSET: '10000' }), 14202);
  for (const env of [
    { GITHUB_RUN_NUMBER: '1;echo injected' },
    { GITHUB_RUN_NUMBER: '1', GITHUB_RUN_ATTEMPT: '100' },
    { GITHUB_RUN_NUMBER: '1', BUILD_NUMBER_OFFSET: '-1' },
    { GITHUB_RUN_NUMBER: '21000001' },
  ]) assert.throws(() => buildNumber(env));
});

test('stamps both platforms while preserving identifiers and rejects prerelease marketing versions', () => fixture((root) => {
  fs.writeFileSync(`${root}/package.json`, JSON.stringify({ version: '1.2.3', dependencies: { expo: '58' } }));
  fs.writeFileSync(`${root}/app.json`, JSON.stringify({ expo: { name: 'Demo', ios: { bundleIdentifier: 'org.acme.app' }, android: { package: 'org.acme.app' } } }));
  prepare(root, { GITHUB_RUN_NUMBER: '7', GITHUB_RUN_ATTEMPT: '2', APP_VERSION: '2.0.0' });
  const app = JSON.parse(fs.readFileSync(`${root}/app.json`));
  assert.equal(app.expo.version, '2.0.0');
  assert.deepEqual(app.expo.ios, { bundleIdentifier: 'org.acme.app', buildNumber: '702' });
  assert.deepEqual(app.expo.android, { package: 'org.acme.app', versionCode: 702 });
  assert.throws(() => prepare(root, { GITHUB_RUN_NUMBER: '8', APP_VERSION: '2.0.0-beta' }));
}));

test('signing credentials remain outside artifact directories and properties escape special passwords', () => fixture((root) => {
  fs.mkdirSync(`${root}/android`);
  fs.mkdirSync(`${root}/signing`);
  writeSigning(root, `${root}/signing`, {
    ANDROID_KEYSTORE_BASE64: Buffer.from('historic-upload-key').toString('base64'),
    ANDROID_KEYSTORE_PASSWORD: ' leading:=\\\nsecret', ANDROID_KEYSTORE_ALIAS: 'custom-key',
  });
  assert.equal(fs.readFileSync(`${root}/signing/upload.jks`, 'utf8'), 'historic-upload-key');
  const properties = fs.readFileSync(`${root}/android/key.properties`, 'utf8');
  assert.match(properties, /releaseKeyAlias=custom-key/);
  assert.equal(properties.split('\n').filter(Boolean).length, 4);
  assert.match(properties, /releaseStorePassword=\\ leading\\:\\=/);
  assert.equal(fs.statSync(`${root}/android/key.properties`).mode & 0o777, 0o600);
  assert.equal(escapeProperty('a\nb\rc\td'), 'a\\nb\\rc\\td');
  assert.equal(escapeProperty('ä🚀'), '\\u00e4\\ud83d\\ude80');
}));

test('fails before installing dependencies when release signing is missing', () => {
  const result = spawnSync('bash', [path.join(__dirname, 'run.sh')], {
    env: { PATH: process.env.PATH, MAINPATH_NATIVE_OPERATION: 'android' }, encoding: 'utf8',
  });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Missing ANDROID_APP_IDENTIFIER/);
  assert.doesNotMatch(result.stdout + result.stderr, /npm/);
});

test('store lanes cannot be invoked from pushes or a non-main dispatch', () => {
  for (const [event, ref] of [['push', 'refs/heads/main'], ['workflow_dispatch', 'refs/heads/feature']]) {
    const result = spawnSync('bash', [path.join(__dirname, 'run.sh')], {
      env: { PATH: process.env.PATH, MAINPATH_NATIVE_OPERATION: 'publish-android', GITHUB_EVENT_NAME: event, GITHUB_REF: ref }, encoding: 'utf8',
    });
    assert.equal(result.status, 1);
    assert.match(result.stdout, /requires an explicit workflow dispatch on main/);
  }
});

const gitlabSigningSource = path.resolve(__dirname, '../../../frontend-template/general/bin/inject-expo-android-signing.sh');
test('uses the same Android signing injection as the GitLab pipeline', { skip: !fs.existsSync(gitlabSigningSource) }, () => {
  assert.equal(fs.readFileSync(path.join(__dirname, 'inject-expo-android-signing.sh'), 'utf8'),
    fs.readFileSync(gitlabSigningSource, 'utf8'));
});

test('dynamic Expo configs cannot silently override package identity or native build numbers', () => fixture((root) => {
  const file = `${root}/expo-public.json`;
  const env = { ...process.env, MAINPATH_SIGNING_DIR: root, MAINPATH_NATIVE_OPERATION: 'android',
    ANDROID_APP_IDENTIFIER: 'org.acme.app', GITHUB_RUN_NUMBER: '8', GITHUB_RUN_ATTEMPT: '1' };
  const validate = () => spawnSync(process.execPath, [path.join(__dirname, 'validate-config.cjs')], { env, encoding: 'utf8' });
  fs.writeFileSync(file, JSON.stringify({ android: { package: 'org.acme.app', versionCode: 801 } }));
  assert.equal(validate().status, 0);
  fs.writeFileSync(file, JSON.stringify({ android: { package: 'org.other.app', versionCode: 801 } }));
  assert.notEqual(validate().status, 0);
  fs.writeFileSync(file, JSON.stringify({ android: { package: 'org.acme.app', versionCode: 1 } }));
  assert.notEqual(validate().status, 0);
}));

for (const platform of ['android', 'ios']) {
  test(`optional native API environment stays correct through ${platform} prebuild and the native bundler`, () => fixture((root) => {
    const bin = path.join(root, 'bin');
    fs.mkdirSync(bin);
    fs.mkdirSync(path.join(root, 'tmp'));
    const tool = `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const name = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const phase = name === 'npx' ? (args.includes('config') ? 'expo-config' : 'expo-prebuild') :
  name === 'gradlew' ? 'native-gradle' : name === 'bundle' && args.includes('fastlane') ? 'native-xcode' :
  name === 'bundle' && args.includes('pod') ? 'pods' : name;
fs.appendFileSync(process.env.NATIVE_TEST_TRACE, JSON.stringify({phase, present: Object.hasOwn(process.env, 'EXPO_PUBLIC_API_URL'), value: process.env.EXPO_PUBLIC_API_URL, resolved: process.env.EXPO_PUBLIC_API_URL ?? 'https://native-default.invalid/api'}) + '\\n');
if (name === 'npx' && args.includes('config')) {
  const config = JSON.parse(fs.readFileSync('app.json', 'utf8')).expo;
  config.extra = {apiUrl: process.env.EXPO_PUBLIC_API_URL ?? 'https://native-default.invalid/api'};
  console.log(JSON.stringify(config));
}
if (name === 'npx' && args.includes('prebuild')) {
  fs.mkdirSync('android/app', {recursive: true});
  fs.writeFileSync('android/app/build.gradle', 'android {\\n signingConfigs { debug {} }\\n buildTypes { release { signingConfig signingConfigs.debug\\n } }\\n}\\n');
  fs.copyFileSync(__filename, 'android/gradlew');
}
if (phase === 'native-gradle' || phase === 'native-xcode') process.exit(23);
`;
    for (const name of ['npm', 'npx', 'keytool', 'bundle']) {
      fs.writeFileSync(path.join(bin, name), tool, { mode: 0o755 });
    }
    for (const optional of [undefined, '', ' \t', 'https://verified.example/api/app/v1']) {
      fs.writeFileSync(path.join(root, 'package.json'), JSON.stringify({version: '1.0.0'}));
      fs.writeFileSync(path.join(root, 'package-lock.json'), '{}');
      fs.writeFileSync(path.join(root, 'app.json'), JSON.stringify({expo: {
        android: {package: 'org.acme.app'}, ios: {bundleIdentifier: 'org.acme.app'},
      }}));
      const trace = path.join(root, 'trace.jsonl');
      fs.writeFileSync(trace, '');
      const env = {
        ...process.env, PATH: `${bin}${path.delimiter}${process.env.PATH}`,
        GITHUB_ACTION_PATH: __dirname, MAINPATH_NATIVE_OPERATION: platform,
        RUNNER_TEMP: path.join(root, 'tmp'), NATIVE_TEST_TRACE: trace,
        GITHUB_RUN_NUMBER: '9', GITHUB_RUN_ATTEMPT: '1',
        ANDROID_APP_IDENTIFIER: 'org.acme.app', ANDROID_KEYSTORE_BASE64: 'dGVzdA==',
        ANDROID_KEYSTORE_PASSWORD: 'test-only', IOS_APP_IDENTIFIER: 'org.acme.app',
        APP_STORE_CONNECT_KEY_ID: 'test', APP_STORE_CONNECT_KEY_ISSUER_ID: 'test',
        APP_STORE_CONNECT_KEY: 'test', APP_STORE_CONNECT_DEVELOPER_TEAM_ID: 'test',
        MATCH_GIT_URL: 'https://example.invalid/match', MATCH_GIT_BASIC_AUTHORIZATION: 'test', MATCH_PASSWORD: 'test',
      };
      delete env.EXPO_PUBLIC_API_URL;
      if (optional !== undefined) env.EXPO_PUBLIC_API_URL = optional;
      const result = spawnSync('bash', [path.join(__dirname, 'run.sh')], { cwd: root, env, encoding: 'utf8', timeout: 15000 });
      assert.equal(result.status, 23, result.stdout + result.stderr);
      const observed = fs.readFileSync(trace, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
      for (const phase of ['npm', 'expo-config', 'expo-prebuild', platform === 'android' ? 'native-gradle' : 'native-xcode']) {
        assert.ok(observed.some((entry) => entry.phase === phase), `Missing ${phase}`);
      }
      for (const entry of observed) {
        assert.equal(entry.present, Boolean(optional?.trim()), `${platform}: ${entry.phase}`);
        assert.equal(entry.resolved, optional?.trim() ? optional : 'https://native-default.invalid/api');
        if (optional?.trim()) assert.equal(entry.value, optional);
      }
    }
  }));
}
