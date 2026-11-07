export type LogLevel = 'debug' | 'info' | 'warning' | 'error';
export type LogScalar = string | number | boolean | null;
export type LogAttributes = Readonly<Record<string, LogScalar>>;
export interface Configuration {
  baseUrl: string;
  ingestToken: string;
  appVersion: string;
  build: string;
  /** A private native child directory; paths and URLs are never accepted. */
  spoolName?: string;
  debugSessionId?: string;
  installationId?: string;
  maxQueueEvents?: number;
  maxQueueBytes?: number;
}
export interface DeliveryStats {
  queued: number;
  accepted: number;
  duplicate: number;
  dropped: number;
  expired: number;
  failures: number;
  storageFailures: number;
  authenticationStopped: boolean;
  disabled: boolean;
  /** JavaScript admission counters, separate from native durable delivery counters. */
  admissionDropped: number;
  invalid: number;
  bridgeRejected: number;
  bridgeFailures: number;
}
/** Native JSON strings prevent architecture-dependent dictionary/number conversion. */
export interface NativeLoggingModule {
  configure(configurationJSON: string): Promise<void>;
  log(eventJSON: string): Promise<boolean>;
  flush(): Promise<void>;
  deliveryStats(): Promise<string>;
  reconfigure(ingestToken: string): Promise<void>;
  setForegroundActive(active: boolean): void;
  disable(): Promise<void>;
  close(): Promise<void>;
}
export interface Lifecycle {
  currentState: string | null;
  addEventListener(event: 'change', listener: (state: string) => void): {remove(): void};
}
