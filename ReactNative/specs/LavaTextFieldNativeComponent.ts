import type {CodegenTypes, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

type TextEvent = Readonly<{text: string}>;
interface NativeProps extends ViewProps {
  inputLabel: string;
  autoFocus?: boolean;
  placeholder: string;
  kind?: string;
  resetRevision: CodegenTypes.Int32;
  fontPointSize?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  onSizeChange?: CodegenTypes.DirectEventHandler<Readonly<{height: CodegenTypes.Float}>>;
  onChange?: CodegenTypes.DirectEventHandler<TextEvent>;
  onSubmit?: CodegenTypes.DirectEventHandler<TextEvent>;
}

// The platform editor owns its text buffer. JS receives changes/submissions and
// requests an explicit reset after accepting a preview edit.
export default codegenNativeComponent<NativeProps>('LavaTextField') as HostComponent<NativeProps>;
