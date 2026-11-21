const fs = require('node:fs');
const path = require('node:path');

function escapeProperty(value) {
  return String(value).replace(/[\\:=#! ]|[^\x20-\x7e]/g, (c) => {
    if (c === '\n') return '\\n';
    if (c === '\r') return '\\r';
    if (c === '\t') return '\\t';
    const code = c.charCodeAt(0);
    return code < 0x20 || code > 0x7e ? `\\u${code.toString(16).padStart(4, '0')}` : `\\${c}`;
  });
}
function writeSigning(root, directory, env) {
  const keystore = path.join(directory, 'upload.jks');
  const encoded = env.ANDROID_KEYSTORE_BASE64 || '';
  if (!/^[A-Za-z0-9+/=\s]+$/.test(encoded)) throw new Error('Invalid upload keystore encoding');
  const bytes = Buffer.from(encoded, 'base64');
  if (!bytes.length) throw new Error('Upload keystore is empty');
  fs.writeFileSync(keystore, bytes, { mode: 0o600 });
  const fields = {
    releaseStoreFile: keystore,
    releaseStorePassword: env.ANDROID_KEYSTORE_PASSWORD,
    releaseKeyAlias: env.ANDROID_KEYSTORE_ALIAS || 'upload',
    releaseKeyPassword: env.ANDROID_KEYSTORE_PASSWORD,
  };
  fs.writeFileSync(path.join(root, 'android/key.properties'),
    Object.entries(fields).map(([key, value]) => `${key}=${escapeProperty(value)}`).join('\n') + '\n', { mode: 0o600 });
}
if (require.main === module) writeSigning(process.cwd(), process.env.MAINPATH_SIGNING_DIR, process.env);
module.exports = { escapeProperty, writeSigning };
