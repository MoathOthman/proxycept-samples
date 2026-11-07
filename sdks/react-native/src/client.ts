import type {Configuration, DeliveryStats, Lifecycle, LogAttributes, LogLevel, NativeLoggingModule} from './types';

function string(value: unknown, maximum: number, nonempty = false): value is string {
  if (typeof value !== 'string' || value.length > maximum * 2 || (nonempty && !value)) return false;
  let count = 0;
  for (const scalar of value) {
    if (++count > maximum) return false;
    const point = scalar.codePointAt(0)!;
    if (point >= 0xd800 && point <= 0xdfff) return false;
  }
  return true;
}
export function validAttributes(value: unknown): value is LogAttributes {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return false;
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const keys = Object.keys(descriptors);
  if (keys.length > 16 || Object.getOwnPropertySymbols(value).length) return false;
  return keys.every(key => {
    const descriptor = descriptors[key];
    if (!string(key, 64, true) || !('value' in descriptor) || !descriptor.enumerable) return false;
    const item: unknown = descriptor.value;
    return item === null || typeof item === 'boolean' || string(item, 512) ||
      (typeof item === 'number' && Number.isFinite(item) && Math.abs(item) <= 1e308);
  });
}
function validateConfiguration(config: Configuration): Configuration {
  // Native code independently validates the URL origin and numeric loopback exception.
  if (!string(config.baseUrl, 2048, true) || !/^https?:\/\//.test(config.baseUrl) ||
      !/^plog_ingest_[A-Za-z0-9_-]{1,500}$/.test(config.ingestToken) ||
      !string(config.appVersion, 80, true) || !string(config.build, 80, true) ||
      !/^[A-Za-z0-9_-]{1,64}$/.test(config.spoolName ?? 'default') ||
      (config.debugSessionId !== undefined && !string(config.debugSessionId, 128, true)) ||
      (config.installationId !== undefined && !string(config.installationId, 128, true))) {
    throw new Error('Invalid Proxycept logging configuration');
  }
  const maxQueueEvents = config.maxQueueEvents ?? 2000, maxQueueBytes = config.maxQueueBytes ?? 2097152;
  if (!Number.isInteger(maxQueueEvents) || maxQueueEvents < 1 || maxQueueEvents > 2000 ||
      !Number.isInteger(maxQueueBytes) || maxQueueBytes < 8192 || maxQueueBytes > 2097152) {
    throw new Error('Invalid Proxycept queue limits');
  }
  return {baseUrl: config.baseUrl, ingestToken: config.ingestToken, appVersion: config.appVersion,
    build: config.build, spoolName: config.spoolName ?? 'default', maxQueueEvents, maxQueueBytes,
    ...(config.debugSessionId !== undefined ? {debugSessionId: config.debugSessionId} : {}),
    ...(config.installationId !== undefined ? {installationId: config.installationId} : {})};
}
function bytes(value: string): number {
  let count = 0;
  for (const c of value) { const p = c.codePointAt(0)!; count += p < 128 ? 1 : p < 2048 ? 2 : p < 65536 ? 3 : 4; }
  return count;
}

/** One client per native module instance. No JS spool, fetch transport or credential storage. */
export class Logger {
  private readonly native: NativeLoggingModule;
  private readonly pending = new Set<Promise<void>>();
  private pendingBytes = 0;
  private state: 'open' | 'closing' | 'closed' | 'disabled' = 'open';
  private subscription: {remove(): void} | undefined;
  private invalid = 0;
  private admissionDropped = 0;
  private bridgeRejected = 0;
  private bridgeFailures = 0;
  private closing: Promise<void> | undefined;
  private disabling: Promise<void> | undefined;

  private constructor(native: NativeLoggingModule) { this.native = native; }
  static async create(native: NativeLoggingModule, config: Configuration, lifecycle?: Lifecycle): Promise<Logger> {
    const normalized = validateConfiguration(config);
    await native.configure(JSON.stringify(normalized));
    const logger = new Logger(native);
    try {
      if (lifecycle) {
        logger.subscription = lifecycle.addEventListener('change', state => {
          if (logger.state === 'open') native.setForegroundActive(state === 'active');
        });
        native.setForegroundActive(lifecycle.currentState === 'active');
      } else { native.setForegroundActive(false); }
    } catch {
      logger.subscription?.remove();
      await native.close();
      throw new Error('Unable to attach logging lifecycle');
    }
    return logger;
  }
  /** True means bounded JS admission only. Query stats for native admission/delivery. */
  log(level: LogLevel, category: string, message: string, attributes: LogAttributes = {}, correlationId: string | null = null): boolean {
    if (this.state !== 'open') return false;
    try {
      if (!['debug', 'info', 'warning', 'error'].includes(level) || !string(category, 80) ||
          !string(message, 4096) || !validAttributes(attributes) ||
          (correlationId !== null && !string(correlationId, 128, true))) { this.invalid++; return false; }
      const payload = JSON.stringify({level, category, message, attributes, correlationId});
      const size = bytes(payload);
      if (size > 65536) { this.invalid++; return false; }
      if (this.pending.size >= 32 || this.pendingBytes + size > 262144) { this.admissionDropped++; return false; }
      this.pendingBytes += size;
      let work: Promise<void>;
      work = Promise.resolve().then(() => this.native.log(payload)).then(accepted => {
        if (!accepted) this.bridgeRejected++;
      }, () => { this.bridgeFailures++; }).finally(() => {
        this.pending.delete(work); this.pendingBytes -= size;
      });
      this.pending.add(work);
      return true;
    } catch { this.invalid++; return false; }
  }
  private async settle(): Promise<void> { await Promise.all([...this.pending]); }
  async flush(): Promise<void> { await this.settle(); if (this.state === 'open') await this.native.flush(); }
  async deliveryStats(): Promise<DeliveryStats> {
    await this.settle();
    const native = JSON.parse(await this.native.deliveryStats()) as Omit<DeliveryStats, 'admissionDropped' | 'invalid' | 'bridgeRejected' | 'bridgeFailures'>;
    return {...native, admissionDropped: this.admissionDropped, invalid: this.invalid,
      bridgeRejected: this.bridgeRejected, bridgeFailures: this.bridgeFailures};
  }
  async reconfigure(ingestToken: string): Promise<void> {
    if (this.state !== 'open' || !/^plog_ingest_[A-Za-z0-9_-]{1,500}$/.test(ingestToken)) {
      throw new Error('Invalid reconfiguration');
    }
    await this.settle();
    if (this.state !== 'open') throw new Error('Logging client is no longer open');
    await this.native.reconfigure(ingestToken);
  }
  disable(): Promise<void> {
    if (this.disabling) return this.disabling;
    if (this.state !== 'open') return Promise.resolve();
    this.state = 'disabled'; this.subscription?.remove(); this.subscription = undefined;
    // Wait for bounded bridge admissions so no late call can recreate a purged queue.
    this.disabling = (async () => { await this.settle(); await this.native.disable(); })();
    return this.disabling;
  }
  close(): Promise<void> {
    if (this.closing) return this.closing;
    this.state = 'closing'; this.subscription?.remove(); this.subscription = undefined;
    this.closing = (async () => {
      await this.settle();
      // Purge must finish before close releases the native logger; an earlier
      // failed disable still must not prevent closing/releasing its resources.
      await this.disabling?.catch(() => {});
      try { await this.native.close(); } finally { this.state = 'closed'; }
    })();
    return this.closing;
  }
}
