import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {resolve, dirname} from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repository = resolve(root, '../..');
const manifest = JSON.parse(readFileSync(resolve(root, 'native-source-provenance.json'), 'utf8'));
const digest = path => createHash('sha256').update(readFileSync(path)).digest('hex');
let errors = 0;
for (const [path, expected] of Object.entries(manifest.upstreamSHA256)) {
  if (digest(resolve(repository, path)) !== expected) { console.error(`Upstream native source changed: ${path}; review and port fixes explicitly`); errors++; }
}
for (const [path, expected] of Object.entries(manifest.bundledSHA256 ?? {})) {
  if (digest(resolve(root, path)) !== expected) { console.error(`Bundled native source changed without provenance update: ${path}`); errors++; }
}
if (!manifest.bundledSHA256 || errors) process.exitCode = 1;
else console.log('PASS pinned upstream and adapted native source hashes');
