// Semantic roles stay independent of the iOS-generated token representation.
export type LavaTextRole = 'primaryValue' | 'rowTitle' | 'rowMetadata' | 'cardTitle' | 'actionLabel' | 'sectionLabel' | 'fieldLabel' | 'metricNumeral';
export type LavaTextTone = 'primary' | 'secondary' | 'warning' | 'danger';

export interface LavaTextProps {
  children: string;
  role?: LavaTextRole;
  /** Defaults to metric ink for numerals and primary text for other roles. */
  tone?: LavaTextTone;
  testID?: string;
}
