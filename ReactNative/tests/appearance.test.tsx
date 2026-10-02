import {useColorScheme} from 'react-native';
import {renderHook} from '@testing-library/react-native';
import type {PropsWithChildren} from 'react';
import {LavaAppearanceContext, useLavaColorScheme, type LavaColorScheme} from '../src/appearance';

jest.mock('react-native/Libraries/Utilities/useColorScheme',()=>({__esModule:true,default:jest.fn(()=> 'light')}));

afterEach(()=>{jest.mocked(useColorScheme).mockReturnValue('light');});

test.each(['light','dark'] as const)('resolved %s app appearance wins over opposite raw native scheme',scheme=>{
  const opposite:LavaColorScheme=scheme==='light'?'dark':'light';
  jest.mocked(useColorScheme).mockReturnValue(opposite);
  const wrapper=({children}:PropsWithChildren)=><LavaAppearanceContext.Provider value={scheme}>{children}</LavaAppearanceContext.Provider>;
  const {result,rerender}=renderHook(()=>useLavaColorScheme(),{wrapper});
  expect(result.current).toBe(scheme);
  // A transient native appearance notification must not override the resolved
  // preference used by the navigation theme and its explicit header colors.
  jest.mocked(useColorScheme).mockReturnValue(null);
  rerender(undefined);
  expect(result.current).toBe(scheme);
  jest.mocked(useColorScheme).mockReturnValue(opposite);
  rerender(undefined);
  expect(result.current).toBe(scheme);
});
