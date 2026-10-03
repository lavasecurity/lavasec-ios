import type {CodegenTypes, TurboModule} from 'react-native';
import {TurboModuleRegistry} from 'react-native';

export type AppearanceSnapshot = {
  preference: string;
  revision: CodegenTypes.Double;
};

export interface Spec extends TurboModule {
  getSnapshot(): Promise<AppearanceSnapshot>;
  setPreference(preference: string): Promise<AppearanceSnapshot>;
  readonly onSnapshot: CodegenTypes.EventEmitter<AppearanceSnapshot>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NativeLavaAppearance');
