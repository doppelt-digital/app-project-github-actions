const fs = require('node:fs');
const { buildNumber } = require('./prepare.cjs');
const config = JSON.parse(fs.readFileSync(`${process.env.MAINPATH_SIGNING_DIR}/expo-public.json`, 'utf8'));
const platform = process.env.MAINPATH_NATIVE_OPERATION;
const expected = process.env[platform === 'ios' ? 'IOS_APP_IDENTIFIER' : 'ANDROID_APP_IDENTIFIER'];
const actual = platform === 'ios' ? config.ios?.bundleIdentifier : config.android?.package;
if (actual !== expected) throw new Error('Expo native identifier does not match the selected MainPath app');
const version = platform === 'ios' ? config.ios?.buildNumber : config.android?.versionCode;
if (String(version) !== String(buildNumber(process.env))) throw new Error('Dynamic Expo config must retain the generated native build number');
