import {TurboModuleRegistry, type TurboModule, type CodegenTypes} from 'react-native';

export type ActivityDates = {
  start: CodegenTypes.Double;
  end: CodegenTypes.Double;
  label: string;
  includesToday: boolean;
};

export interface Spec extends TurboModule {
  close(): void;
  chooseFilterAction(name: string, canSwitch: boolean, canShare: boolean): Promise<string | null>;
  speakDemo(text: string, locale: string): Promise<boolean>;
  stopDemo(): void;
  getLegalNotices(): string;
  getGuardAccents(): string;
  getBlocklistCatalog(): string;
  getSharePreview(filter: string): string;
  copySharePreview(filter: string): void;
  normalizeDomain(input: string): string | null;
  getActivityDates(): Promise<ActivityDates>;
  getActivityDatePreset(preset: string): Promise<ActivityDates | null>;
  pickActivityDates(start: CodegenTypes.Double, end: CodegenTypes.Double): Promise<ActivityDates | null>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('NativeLavaReview');
