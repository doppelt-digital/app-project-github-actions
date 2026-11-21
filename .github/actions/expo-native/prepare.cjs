const fs = require('node:fs');

function buildNumber(env) {
  const run = Number(env.GITHUB_RUN_NUMBER);
  const attempt = Number(env.GITHUB_RUN_ATTEMPT || 1);
  const offset = Number(env.BUILD_NUMBER_OFFSET || 0);
  if (!Number.isSafeInteger(run) || run < 1 || !Number.isSafeInteger(attempt) || attempt < 1 || attempt > 99 || !Number.isSafeInteger(offset) || offset < 0) {
    throw new Error('Invalid native build number configuration');
  }
  const number = offset + run * 100 + attempt;
  if (!Number.isSafeInteger(number) || number > 2100000000) throw new Error('Android versionCode limit exceeded');
  return number;
}

function prepare(root, env) {
  const pkg = JSON.parse(fs.readFileSync(`${root}/package.json`, 'utf8'));
  const version = env.APP_VERSION || pkg.version;
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Native APP_VERSION must use major.minor.patch');
  const number = buildNumber(env);
  const app = JSON.parse(fs.readFileSync(`${root}/app.json`, 'utf8'));
  if (!app.expo) throw new Error('app.json must contain an Expo configuration');
  pkg.version = version;
  app.expo.version = version;
  app.expo.android = { ...app.expo.android, versionCode: number };
  app.expo.ios = { ...app.expo.ios, buildNumber: String(number) };
  fs.writeFileSync(`${root}/package.json`, JSON.stringify(pkg, null, 2) + '\n');
  fs.writeFileSync(`${root}/app.json`, JSON.stringify(app, null, 2) + '\n');
  return { version, number };
}

if (require.main === module) {
  const result = prepare(process.cwd(), process.env);
  console.log(`Native version ${result.version} build ${result.number}`);
}
module.exports = { buildNumber, prepare };
