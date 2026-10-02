import type {CodegenTypes, ColorValue, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {
  label: string;
  value: CodegenTypes.Double;
  maximum: CodegenTypes.Double;
  disabled: boolean;
  tintColor?: ColorValue;
  onTrackingChange?: CodegenTypes.DirectEventHandler<Readonly<{tracking: boolean}>>;
  onValueChange?: CodegenTypes.DirectEventHandler<Readonly<{value: CodegenTypes.Double}>>;
}
export default codegenNativeComponent<NativeProps>('LavaSlider') as HostComponent<NativeProps>;
