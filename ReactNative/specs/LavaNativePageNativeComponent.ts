import type {CodegenTypes, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  page: string;
  focused: boolean;
  onBack?: CodegenTypes.DirectEventHandler<Readonly<{}>>;
  onNavigate?: CodegenTypes.DirectEventHandler<Readonly<{destination: string}>>;
}

// A native feature page participates in the React navigation stack. Its native
// controls, private drafts and system sheets stay with their native owner;
// page destinations use the enclosing stack's navigation and authentication.
export default codegenNativeComponent<NativeProps>('LavaNativePage') as HostComponent<NativeProps>;
