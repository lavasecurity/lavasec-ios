import type {HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {ownerID:string;kind:string;}
// The input buffer, confirmation and validation stay inside the native credential owner.
export default codegenNativeComponent<NativeProps>('LavaPasscodeInput') as HostComponent<NativeProps>;
