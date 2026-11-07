const path = require('node:path');
const fs = require('node:fs');
const Metro = require('metro');
const root = path.resolve(__dirname, '../../..');
(async () => {
  const config = await Metro.loadConfig({cwd: root, config: path.join(root, 'metro.config.cjs')});
  const output = process.argv[2];
  fs.mkdirSync(path.dirname(output), {recursive: true});
  await Metro.runBuild(config, {entry: 'example/runtime-entry.js', platform: 'android',
    dev: false, minify: false, bundleOut: output});
  console.log('Bundled credential-free Android runtime entry');
})().catch(() => { console.error('Android bundle failed'); process.exitCode = 1; });
