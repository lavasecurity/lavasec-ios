import type {CodegenTypes, HostComponent, ViewProps} from 'react-native';
import codegenNativeComponent from 'react-native/Libraries/Utilities/codegenNativeComponent';

interface NativeProps extends ViewProps {
  payload: string;
  moduleCount: CodegenTypes.Int32;
}

// moduleCount is the symbol only; native pixels include four quiet modules/side.
export default codegenNativeComponent<NativeProps>('LavaShareQr') as HostComponent<NativeProps>;
