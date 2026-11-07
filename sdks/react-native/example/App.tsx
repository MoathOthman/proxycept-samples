import React, {useEffect, useState} from 'react';
import {Text, View} from 'react-native';
import {createLogger} from '../src';
import type {Configuration} from '../src';

/** Obtain a short-lived ingest-only credential at runtime; never embed it in a JS bundle. */
export default function LoggingExample({configuration}: {configuration: Configuration}) {
  const [status, setStatus] = useState('Starting');
  useEffect(() => {
    let disposed = false;
    let client: Awaited<ReturnType<typeof createLogger>> | undefined;
    void (async () => {
      client = await createLogger(configuration);
      if (disposed) { await client.close(); return; }
      client.log('info', 'rn-integration', 'Cross-platform SDK smoke', {password: 'must-be-redacted'});
      await client.flush();
      const stats = await client.deliveryStats();
      if (!disposed) setStatus(stats.queued === 0 && stats.dropped === 0 && stats.accepted + stats.duplicate > 0 ? 'PASS' : 'Queued / retry pending');
    })().catch(() => { if (!disposed) setStatus('Logging unavailable'); });
    return () => { disposed = true; void client?.close(); };
  }, [configuration]);
  return <View><Text accessibilityLabel="logging-status">{status}</Text></View>;
}
