import type {HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps { ownerID:string; }

// Camera pixels and parsed QR content remain with the native import session.
export default codegenNativeComponent<NativeProps>('LavaImportScanner') as HostComponent<NativeProps>;
