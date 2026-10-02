import type {CodegenTypes, ColorValue, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {
  label: string;
  value: boolean;
  optimistic: boolean;
  disabled: boolean;
  pending: boolean;
  resetRevision: CodegenTypes.Int32;
  tintColor?: ColorValue;
  onValueChange?: CodegenTypes.DirectEventHandler<Readonly<{value: boolean}>>;
  onSizeChange?: CodegenTypes.DirectEventHandler<Readonly<{width: CodegenTypes.Double; height: CodegenTypes.Double}>>;
}
export default codegenNativeComponent<NativeProps>('LavaSwitch') as HostComponent<NativeProps>;
