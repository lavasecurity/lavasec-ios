import type {CodegenTypes,HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {ownerID:string;fontSize:CodegenTypes.Double;}
export default codegenNativeComponent<NativeProps>('LavaQAConfiguration') as HostComponent<NativeProps>;
