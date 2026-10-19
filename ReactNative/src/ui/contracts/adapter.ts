import type {ComponentType, PropsWithChildren, ReactElement} from 'react';
import type {LavaTextProps} from './text';
import type {LavaCardProps} from './surface';
import type {LavaToggleRowProps} from './toggle';
import type {LavaActionButtonProps} from './action';
import type {LavaIconButtonProps} from './icon';
import type {LavaChoiceProps} from './choice';
import type {LavaSelectionAccessoryProps} from './selection';

/** Platform-owned renderers. This type installs no runtime registry or fallback. */
export interface LavaUIAdapter {
  Text: ComponentType<LavaTextProps>;
  Card: ComponentType<LavaCardProps>;
  ToggleRow: ComponentType<LavaToggleRowProps>;
  ToggleControl: ComponentType<LavaToggleRowProps>;
  ActionButton: ComponentType<LavaActionButtonProps>;
  IconButton: ComponentType<LavaIconButtonProps>;
  IconButtonGroup: ComponentType<PropsWithChildren>;
  SelectionAccessory: ComponentType<LavaSelectionAccessoryProps>;
  Choice: <Value extends string>(props: LavaChoiceProps<Value>) => ReactElement | null;
}
