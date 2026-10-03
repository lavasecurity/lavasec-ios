import type {ReactNode} from 'react';
import type {AccessibilityActionEvent, AccessibilityActionInfo} from 'react-native';
import type {lavaTokens} from './generated/tokens';

// These roles describe Lava intent. A later Android implementation owns its native
// visuals; callers do not select UIColor names, glass effects, or UIKit controls.
export type LavaTextRole = keyof typeof lavaTokens.typography;
export type LavaTextTone = 'primary' | 'secondary' | 'warning' | 'danger';

export interface LavaTextProps {
  children: string;
  role?: LavaTextRole;
  /** Defaults to metric ink for numerals and primary text for other roles. */
  tone?: LavaTextTone;
  testID?: string;
}

export interface LavaCardProps {
  children: ReactNode;
  /** Decorative content fills and clips to the entire rounded card. */
  background?: ReactNode;
  role?: 'card' | 'panel';
  testID?: string;
}

export interface LavaToggleRowProps {
  /** Resolved localized text; the host owns locale/catalog selection. */
  title: string;
  summary?: string;
  value: boolean;
  onValueChange: (value: boolean) => void | Promise<unknown>;
  /** Show a requested asynchronous value until it settles; default is controlled. */
  optimistic?: boolean;
  disabled?: boolean;
  accessibilityHint?: string;
  testID?: string;
}

export interface LavaActionButtonProps {
  /** Semantic fill for filled actions; geometry and spinner ownership stay shared. */
  tone?: 'affirmative' | 'quiet' | 'recovery';
  /** A protection control reserves two lines at the current text scale. */
  stablePill?: boolean;
  title: string;
  role?: 'primary' | 'panel' | 'secondary';
  onPress: () => void;
  disabled?: boolean;
  accessibilityHint?: string;
  subtitle?: string;
  icon?: LavaIconAction;
  busy?: boolean;
  onLongPress?: () => void;
  accessibilityActions?: readonly AccessibilityActionInfo[];
  onAccessibilityAction?: (event: AccessibilityActionEvent) => void;
  testID?: string;
}

/** Semantic icon actions; each platform supplies its native glyph and target size. */
export type LavaIconAction = 'remove' | 'delete' | 'undo' | 'reset' | 'back' | 'close' | 'notes' | 'assist' | 'hide' | 'refresh' | 'erase' | 'confirm' | 'edit' | 'add' | 'share' | 'import' | 'automatic' | 'play' | 'pause' | 'previous' | 'next' | 'calendar' | 'swap' | 'twoPeople';
export interface LavaIconButtonProps {
  title: string;
  icon: LavaIconAction;
  onPress: () => void;
  role?: 'neutral' | 'destructive' | 'accent';
  /** Plain transport actions retain their full target without painting a surface. */
  surface?: 'filled' | 'plain';
  shape?: 'circle' | 'rounded';
  selected?: boolean;
  /// Visual-only emphasis for one-shot actions that must not be announced (or
  /// read) as a persistent mode or current choice — the solved Sudoku "New
  /// puzzle" fill. `selected` also publishes selection semantics; this does not.
  prominent?: boolean;
  disabled?: boolean;
  /** An accepted asynchronous action keeps its slot while excluding another tap. */
  busy?: boolean;
  /** Optional item identity, distinct from the localized action name. */
  item?: string;
  testID?: string;
}

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

/** Decorative state of a selectable row. The containing row owns its action and accessibility. */
export interface LavaSelectionAccessoryProps {
  state: 'selected' | 'unselected' | 'locked';
  disabled?: boolean;
}
