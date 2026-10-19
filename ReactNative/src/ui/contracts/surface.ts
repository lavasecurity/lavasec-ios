import type {ReactNode} from 'react';

export interface LavaCardProps {
  children: ReactNode;
  /** Decorative content fills and clips to the entire rounded card. */
  background?: ReactNode;
  role?: 'card' | 'panel';
  testID?: string;
}
