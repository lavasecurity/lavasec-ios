import type {AccessibilityActionEvent, AccessibilityActionInfo} from 'react-native';
import type {LavaIconAction} from './icon';

export interface LavaActionButtonProps {
  /** Semantic fill for filled actions; geometry and spinner ownership stay shared. */
  tone?: 'affirmative' | 'quiet' | 'recovery';
  /** A protection control reserves two lines at the current text scale. */
  stablePill?: boolean;
  whiteOutline?: boolean;
  /** Duration of the onboarding outline-to-fill material transition. */
  outlineTransitionDuration?: number;
  labelRole?: 'actionLabel' | 'rowTitle';
  title: string;
  role?: 'primary' | 'panel' | 'secondary';
  onPress: () => void;
  disabled?: boolean;
  accessibilityHint?: string;
  subtitle?: string;
  icon?: LavaIconAction;
  /** Supply false while idle to reserve progress space. Pending actions keep their paint and block taps. */
  busy?: boolean;
  onLongPress?: () => void;
  accessibilityActions?: readonly AccessibilityActionInfo[];
  onAccessibilityAction?: (event: AccessibilityActionEvent) => void;
  testID?: string;
}
