import type {ColorValue} from 'react-native';

export interface LavaToggleRowProps {
  /** App copy key or resolved text; the host owns locale/catalog selection. */
  title: string;
  /** A native-projected provider/profile identity must never be translated again. */
  verbatimTitle?: boolean;
  /** Standalone feedback controls retain the native headline title. */
  titleRole?: 'rowTitle' | 'cardTitle';
  summary?: string;
  /** Optional platform-authored semantic label paint; ordinary rows keep their palette. */
  titleColor?: ColorValue;
  value: boolean;
  onValueChange: (value: boolean) => void | Promise<unknown>;
  /** Show a requested asynchronous value until it settles; default is controlled. */
  optimistic?: boolean;
  disabled?: boolean;
  /** Temporarily block input without changing the switch or label appearance. */
  pending?: boolean;
  accessibilityHint?: string;
  testID?: string;
}
