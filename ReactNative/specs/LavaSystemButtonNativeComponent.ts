import type {CodegenTypes,HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';
interface NativeProps extends ViewProps {
  title:string;
  fontSize:CodegenTypes.Double;
  prominent:boolean;
  disabled:boolean;
  destructive:boolean;
  eventID:string;
  onPress?:CodegenTypes.DirectEventHandler<Readonly<{eventID:string}>>;
  onSizeChange?:CodegenTypes.DirectEventHandler<Readonly<{width:CodegenTypes.Double;height:CodegenTypes.Double}>>;
}
export default codegenNativeComponent<NativeProps>('LavaSystemButton') as HostComponent<NativeProps>;
