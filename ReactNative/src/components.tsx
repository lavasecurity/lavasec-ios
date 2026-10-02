import type {LavaActionButtonProps, LavaCardProps, LavaTextProps, LavaToggleRowProps, LavaIconButtonProps, LavaSelectionAccessoryProps} from './contracts';

// Metro selects components.ios.tsx on iOS. Deliberately avoid making the iOS
// appearance an accidental Android default before the operator's Android review.
function unavailable(): never {
  throw new Error('Lava UI currently has an iOS implementation only. This platform needs its native component mapping.');
}
export function LavaText(_props: LavaTextProps): never { return unavailable(); }
export function LavaCard(_props: LavaCardProps): never { return unavailable(); }
export function LavaToggleControl(_props: LavaToggleRowProps): never { return unavailable(); }
export function LavaToggleRow(_props: LavaToggleRowProps): never { return unavailable(); }
export function LavaActionButton(_props: LavaActionButtonProps): never { return unavailable(); }
export function LavaIconButton(_props: LavaIconButtonProps): never { return unavailable(); }
export function LavaSelectionAccessory(_props: LavaSelectionAccessoryProps): never { return unavailable(); }
