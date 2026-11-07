import {test} from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
test('native source copies require explicit upstream and adaptation hash review', () => {
  const result = spawnSync(process.execPath, [new URL('../scripts/check-native-source.mjs', import.meta.url).pathname], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
});
