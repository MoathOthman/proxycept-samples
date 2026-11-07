import {AppState, NativeModules} from 'react-native';
import {Logger} from './client';
import type {Configuration, NativeLoggingModule} from './types';
export {Logger} from './client';
export type {Configuration, DeliveryStats, LogAttributes, LogLevel, LogScalar} from './types';

/** Requires the native module in a rebuilt iOS/Android app; Expo Go is unsupported. */
export function createLogger(configuration: Configuration): Promise<Logger> {
  const native = NativeModules.ProxyceptLogging as NativeLoggingModule | undefined;
  if (!native) throw new Error('ProxyceptLogging native module is missing; link it and rebuild the app');
  return Logger.create(native, configuration, AppState);
}
