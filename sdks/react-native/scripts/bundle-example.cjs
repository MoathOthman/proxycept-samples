const path = require('node:path');
const Metro = require('metro');
const root = path.resolve(__dirname, '..');
(async () => {
  const config = await Metro.loadConfig({cwd: root, config: path.join(root, 'metro.config.cjs')});
  await Metro.runBuild(config, {entry: 'example/runtime-entry.js', platform: 'ios', dev: false,
    minify: false, bundleOut: path.join(root, 'example/ios/main.jsbundle')});
  console.log('PASS bundled runtime example; configuration is fetched at runtime');
})().catch(() => { console.error('FAIL bundling runtime example'); process.exitCode = 1; });
