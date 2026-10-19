import type {CodegenTypes,ColorValue,HostComponent,ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  title:string;
  symbol:string;
  tintColor:ColorValue;
  textColor:ColorValue;
  fontSize:CodegenTypes.Double;
  fontWeight:string;
  colorScheme:string;
  measurementID:string;
  /** Empty/omitted values preserve the original headline and leading layout. */
  textStyle?:string;
  contentAlignment?:string;
  multilineAlignment?:string;
  onSizeChange?:CodegenTypes.DirectEventHandler<Readonly<{measurementID:string;width:CodegenTypes.Double;height:CodegenTypes.Double}>>;
}
/** Only the inline SF Symbol/text run stays native. RN owns its containing UI. */
export default codegenNativeComponent<NativeProps>('LavaInlineSymbolText') as HostComponent<NativeProps>;
