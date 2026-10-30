import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {Logger, validAttributes} from '../src/client.ts';
import type {Configuration, Lifecycle, NativeLoggingModule} from '../src/types.ts';
const fixture = JSON.parse(readFileSync(new URL('../../conformance/attribute-vectors.json', import.meta.url), 'utf8'));
const configuration: Configuration = {baseUrl: 'http://127.0.0.1:18880', ingestToken: 'plog_ingest_fixture', appVersion: '1', build: '1'};
function backend() {
  const events: any[] = []; let active = false, disabled = false, accepted = 0;
  const native: NativeLoggingModule = {
    async configure(_) {},
    async log(json) { events.push(JSON.parse(json)); return !disabled; },
    async flush() { accepted += events.length; events.length = 0; },
    async deliveryStats() { return JSON.stringify({queued: events.length, accepted, duplicate: 0, dropped: 0,
      expired: 0, failures: 0, storageFailures: 0, authenticationStopped: false, disabled}); },
    async reconfigure(_) {}, setForegroundActive(value) { active = value; },
    async disable() { disabled = true; events.length = 0; }, async close() { disabled = true; },
  };
  return {native, events, active: () => active};
}
for (const vector of fixture.cases) {
  test(`shared attribute conformance: ${vector.name}`, () => {
    assert.equal(validAttributes(vector.attributes), vector.accepted);
  });
}
test('mixed invalid events never poison valid neighbors', async () => {
  const fake = backend(), client = await Logger.create(fake.native, configuration);
  assert.equal(client.log('info', 'test', 'before'), true);
  let valid = 2, invalid = 0;
  for (const vector of fixture.cases) {
    assert.equal(client.log('info', 'test', vector.name, vector.attributes), vector.accepted);
    if (vector.accepted) valid++; else invalid++;
  }
  assert.equal(client.log('info', 'test', 'after'), true);
  await client.flush();
  const stats = await client.deliveryStats();
  assert.equal(stats.accepted, valid); assert.equal(stats.invalid, invalid); assert.equal(stats.queued, 0);
  await client.close();
});
test('blocked bridge keeps admissions bounded and snapshots caller values', async () => {
  const fake = backend(); let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  fake.native.log = async json => { await gate; fake.events.push(JSON.parse(json)); return true; };
  const client = await Logger.create(fake.native, configuration);
  const attributes = {screen: 'original'};
  assert.equal(client.log('info', 'test', 'snapshot', attributes), true); attributes.screen = 'changed';
  let admitted = 1;
  for (let i = 0; i < 100; i++) if (client.log('info', 'test', 'bounded')) admitted++;
  assert.equal(admitted, 32);
  release(); await client.deliveryStats();
  assert.equal(fake.events[0].attributes.screen, 'original');
  await client.flush();
  const stats = await client.deliveryStats(); assert.equal(stats.admissionDropped, 69);
  assert.equal(stats.accepted, 32); await client.close();
});
test('getter and custom objects never execute during attribute validation', () => {
  let touched = false;
  const attrs = Object.defineProperty({}, 'secret', {get() { touched = true; throw Error(); }, enumerable: true});
  assert.equal(validAttributes(attrs), false); assert.equal(touched, false);
  assert.equal(validAttributes(new Date()), false);
  assert.equal(validAttributes({value: undefined}), false);
  assert.equal(validAttributes({value: Infinity}), false);
  assert.equal(validAttributes({value: NaN}), false);
  assert.equal(validAttributes({value: '\ud800'}), false);
});
test('lifecycle, disable ordering, and removal', async () => {
  const fake = backend(); let listener!: (state: string) => void, removed = false;
  const lifecycle: Lifecycle = {currentState: null, addEventListener(_, callback) {
    listener = callback; return {remove() { removed = true; }};
  }};
  const client = await Logger.create(fake.native, configuration, lifecycle);
  assert.equal(fake.active(), false); listener('active'); assert.equal(fake.active(), true);
  client.log('info', 'test', 'pending'); await client.disable();
  assert.equal(removed, true); assert.equal(client.log('info', 'test', 'late'), false);
  const stats = await client.deliveryStats(); assert.equal(stats.disabled, true); assert.equal(stats.queued, 0);
  await client.close();
});
test('bridge failures do not create unhandled promise rejections', async () => {
  const fake = backend(); fake.native.log = async () => { throw new Error('secret never forwarded'); };
  const client = await Logger.create(fake.native, configuration);
  client.log('info', 'test', 'one'); await client.flush();
  assert.equal((await client.deliveryStats()).bridgeFailures, 1); await client.close();
});
test('reject bad configuration without native credential output', async () => {
  const fake = backend();
  await assert.rejects(Logger.create(fake.native, {...configuration, spoolName: '../escape'}), /Invalid/);
  await assert.rejects(Logger.create(fake.native, {...configuration, ingestToken: 'secret\nheader'}), /Invalid/);
  await assert.rejects(Logger.create(fake.native, {...configuration, maxQueueEvents: 2001}), /Invalid/);
});
test('concurrent disable and close await purge and share lifecycle barriers', async () => {
  const fake = backend(); let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const calls: string[] = [];
  fake.native.disable = async () => { calls.push('disable-start'); await gate; calls.push('purged'); };
  fake.native.close = async () => { calls.push('closed'); };
  const client = await Logger.create(fake.native, configuration);
  const first = client.disable(), second = client.disable();
  assert.equal(first, second);
  const close = client.close(); assert.equal(client.close(), close);
  await new Promise(resolve => setTimeout(resolve, 0));
  assert.deepEqual(calls, ['disable-start']); release();
  await Promise.all([first, second, close]);
  assert.deepEqual(calls, ['disable-start', 'purged', 'closed']);
});
test('empty correlation is rejected without poisoning valid neighbors', async () => {
  const fake = backend();
  fake.native.flush = async () => {
    assert.ok(fake.events.every(event => event.correlationId === null ||
      (typeof event.correlationId === 'string' && event.correlationId.length > 0)));
  };
  const client = await Logger.create(fake.native, configuration);
  assert.equal(client.log('info', 'correlation', 'before'), true);
  assert.equal(client.log('info', 'correlation', 'invalid', {}, ''), false);
  assert.equal(client.log('info', 'correlation', 'after', {}, 'request-1'), true);
  await client.flush();
  assert.deepEqual(fake.events.map(event => event.message), ['before', 'after']);
  assert.deepEqual(fake.events.map(event => event.correlationId), [null, 'request-1']);
  assert.equal((await client.deliveryStats()).invalid, 1);
  await client.close();
});
