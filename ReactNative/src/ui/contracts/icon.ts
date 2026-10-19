/** Semantic icon actions; each platform supplies its native glyph and target size. */
export type LavaIconAction = 'remove' | 'delete' | 'undo' | 'reset' | 'back' | 'close' | 'notes' | 'assist' | 'hide' | 'refresh' | 'erase' | 'confirm' | 'edit' | 'add' | 'share' | 'import' | 'automatic' | 'play' | 'pause' | 'previous' | 'next' | 'calendar' | 'swap' | 'twoPeople' | 'browse' | 'passkey' | 'restoreBackup';
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
  /** Optional long-press gesture (e.g. the hidden Sudoku challenge); never announced. */
  onLongPress?: () => void;
  /** Delay before `onLongPress` fires; defaults to the platform long-press threshold. */
  longPressDelayMs?: number;
  testID?: string;
}
