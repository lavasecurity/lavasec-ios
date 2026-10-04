import type {CodegenTypes, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  symbol?: string;
  mood?: string;
  look?: string;
  tone?: string;
  // Shared controls pin this to app appearance; other decoration inherits traits.
  colorScheme?: string;
  staticExport?: CodegenTypes.WithDefault<boolean, false>;
  fontPointSize?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  fontWeight?: string;
  guardianGestures?: CodegenTypes.WithDefault<boolean, false>;
  revealEnabled?: CodegenTypes.WithDefault<boolean, false>;
  revealVisible?: CodegenTypes.WithDefault<boolean, true>;
  revealX?: CodegenTypes.WithDefault<CodegenTypes.Float, 13>;
  revealY?: CodegenTypes.WithDefault<CodegenTypes.Float, 13>;
  revealRadius?: CodegenTypes.WithDefault<CodegenTypes.Float, 22>;
  onGuardianGesture?: CodegenTypes.DirectEventHandler<Readonly<{gesture: string}>>;
}

// A focused decoration primitive. Layout, text, navigation and screen behavior
// remain React Native; iOS draws SF Symbols and the existing Lava guardian.
export default codegenNativeComponent<NativeProps>('LavaDecoration') as HostComponent<NativeProps>;
