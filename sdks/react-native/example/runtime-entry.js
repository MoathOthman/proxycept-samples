/* Test host only: configuration is fetched from the operator's loopback no-store
 * server at runtime. No key or actual session ID is built into this JS bundle. */
const React = require('react');
const {AppRegistry, Text, View} = require('react-native');
const {createLogger} = require('../lib/index');

function RuntimeExample({configURL}) {
  const [status, setStatus] = React.useState('Starting runtime smoke');
  React.useEffect(() => {
    let disposed = false;
    let logger;
    (async () => {
      if (configURL !== 'http://127.0.0.1:18881/sdk-test-config') throw new Error('Local config endpoint required');
      const response = await fetch(configURL, {credentials: 'omit', headers: {'Cache-Control': 'no-store'}});
      if (!response.ok) throw new Error('Configuration unavailable');
      const input = await response.json();
      if (input.base_url !== 'http://127.0.0.1:18880') throw new Error('Local ingest required');
      logger = await createLogger({baseUrl: input.base_url, ingestToken: input.ingest_key,
        appVersion: 'rn-runtime', build: '1', debugSessionId: input.debug_session_id,
        spoolName: `rn-${input.debug_session_id.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40)}`});
      if (disposed) { await logger.close(); return; }
      if (!logger.log('info', 'rn-integration', 'Cross-platform SDK smoke', {password: 'must-be-redacted'})) {
        throw new Error('Admission rejected');
      }
      await logger.flush();
      const stats = await logger.deliveryStats();
      await logger.close();
      if (stats.queued !== 0 || stats.accepted + stats.duplicate !== 1 || stats.dropped !== 0 || stats.bridgeFailures !== 0) {
        throw new Error('Delivery incomplete');
      }
      const result = `PASS rn-js-native committed=1 queued=0 hermes=${!!global.HermesInternal} bridgeless=${!!global.RN$Bridgeless}`;
      console.log(result); // Nonsecret runtime/ack evidence only.
      if (!disposed) setStatus(result);
    })().catch(() => {
      console.log('FAIL rn-js-native smoke');
      if (!disposed) setStatus('FAIL rn-js-native smoke');
    });
    return () => { disposed = true; if (logger) void logger.close(); };
  }, [configURL]);
  return React.createElement(View, {style: {padding: 32, marginTop: 80}},
    React.createElement(Text, {testID: 'logging-status', accessibilityLabel: 'logging-status'}, status));
}
AppRegistry.registerComponent('ProxyceptRNExample', () => RuntimeExample);
