import type {CodegenTypes, TurboModule} from 'react-native';
import {TurboModuleRegistry} from 'react-native';

// JSON is the transport envelope only. app/contract.ts owns the discriminated
// commands and snapshots. Native validates every command before accessing state.
export interface Spec extends TurboModule {
  getSnapshot(): Promise<string>;
  command(request: string): Promise<string>;
  readonly onSnapshot: CodegenTypes.EventEmitter<string>;
}
export default TurboModuleRegistry.get<Spec>('NativeLavaApp');
