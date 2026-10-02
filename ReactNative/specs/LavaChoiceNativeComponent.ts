import type {CodegenTypes, ColorValue, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  label: string;
  controlID: string;
  options: ReadonlyArray<Readonly<{value: string; label: string}>>;
  value: string;
  reselectValue?: string;
  disabled: boolean;
  selectionRevision?: CodegenTypes.WithDefault<CodegenTypes.Int32, 0>;
  stepper?: CodegenTypes.WithDefault<boolean, false>;
  pageControl?: CodegenTypes.WithDefault<boolean, false>;
  tintColor?: ColorValue;
  onValueChange?: CodegenTypes.DirectEventHandler<Readonly<{value: string}>>;
  onSizeChange?: CodegenTypes.DirectEventHandler<Readonly<{height: CodegenTypes.Double}>>;
}

export default codegenNativeComponent<NativeProps>('LavaChoice') as HostComponent<NativeProps>;
