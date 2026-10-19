import type {CodegenTypes,HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {
  ownerID:string;
  mode:string;
  onSizeChange?:CodegenTypes.DirectEventHandler<Readonly<{height:CodegenTypes.Float}>>;
}
/** A credential atom; no phrase, passkey, keystrokes or secret event crosses JS. */
export default codegenNativeComponent<NativeProps>('LavaBackupCredentials') as HostComponent<NativeProps>;
