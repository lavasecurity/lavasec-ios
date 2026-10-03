import type {CodegenTypes,HostComponent,ViewProps,ColorValue} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {
  contextID:string;
  blockedTintColor?:ColorValue;
  actions: ReadonlyArray<Readonly<{id:string;title:string;symbol:string}>>;
  onAction?: CodegenTypes.DirectEventHandler<Readonly<{id:string}>>;
}
export default codegenNativeComponent<NativeProps>('LavaContextMenu') as HostComponent<NativeProps>;
