export interface LavaChoiceOption<Value extends string = string> {
  /** Stable value, independent of the resolved localized label and display order. */
  value: Value;
  label: string;
}

export interface LavaChoiceProps<Value extends string = string> {
  label: string;
  presentation?: 'segments' | 'stepper' | 'pages';
  options: readonly LavaChoiceOption<Value>[];
  value: Value;
  /** Return the owner's mutation promise to retain native selection until it settles. */
  onValueChange: (value: Value) => void | Promise<unknown>;
  /** A segment that opens an editor can be activated again while selected. */
  reselectValue?: Value;
  disabled?: boolean;
  testID?: string;
}

/** Purpose-specific entry points select the platform presentation themselves. */
export type LavaPurposeChoiceProps<Value extends string = string> = Omit<LavaChoiceProps<Value>,'presentation'>;
