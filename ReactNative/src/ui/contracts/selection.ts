/** Decorative state of a selectable row. The containing row owns its action and accessibility. */
export interface LavaSelectionAccessoryProps {
  state: 'selected' | 'unselected' | 'locked';
  disabled?: boolean;
}
