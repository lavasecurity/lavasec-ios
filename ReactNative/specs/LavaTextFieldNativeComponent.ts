import type {CodegenTypes, ColorValue, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

type TextEvent = Readonly<{text: string}>;
interface NativeProps extends ViewProps {
  inputLabel: string;
  autoFocus?: boolean;
  placeholder: string;
  kind?: string;
  value?: string;
  ownerID?: string;
  resetRevision: CodegenTypes.Int32;
  fontPointSize?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  lineHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  editable?: CodegenTypes.WithDefault<boolean, true>;
  keyboardType?: string;
  autoCapitalize?: string;
  autoCorrect?: CodegenTypes.WithDefault<boolean, false>;
  spellCheck?: CodegenTypes.WithDefault<boolean, false>;
  smartInsertDelete?: CodegenTypes.WithDefault<boolean, false>;
  clearButtonMode?: string;
  characterLimit?: CodegenTypes.WithDefault<CodegenTypes.Int32, 0>;
  selectionColor?: ColorValue;
  textColor?: ColorValue;
  placeholderTextColor?: ColorValue;
  onSizeChange?: CodegenTypes.DirectEventHandler<Readonly<{height: CodegenTypes.Float}>>;
  onFocusChange?: CodegenTypes.DirectEventHandler<Readonly<{focused: boolean}>>;
  onChange?: CodegenTypes.DirectEventHandler<TextEvent>;
  onSubmit?: CodegenTypes.DirectEventHandler<TextEvent>;
}

// The platform editor owns its text buffer. JS receives changes/submissions and
// requests an explicit reset after accepting a preview edit.
export default codegenNativeComponent<NativeProps>('LavaTextField') as HostComponent<NativeProps>;
