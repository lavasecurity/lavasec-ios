import type {HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  token: string;
  payload: string;
  ready: boolean;
}

// A normal Fabric child container. React Native owns every card layout/text row.
export default codegenNativeComponent<NativeProps>('LavaShareCardSurface') as HostComponent<NativeProps>;
