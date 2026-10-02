import {createContext, useContext} from 'react';
import {useColorScheme} from 'react-native';

export type LavaColorScheme = 'light' | 'dark';

// The app resolves its native preference once. Shared controls use that result
// instead of local UIKit toolbar traits, which can adapt to scrolled content.
export const LavaAppearanceContext = createContext<LavaColorScheme | undefined>(undefined);

export function useLavaColorScheme(): LavaColorScheme {
  const appScheme = useContext(LavaAppearanceContext);
  const systemScheme = useColorScheme();
  return appScheme ?? (systemScheme === 'dark' ? 'dark' : 'light');
}
