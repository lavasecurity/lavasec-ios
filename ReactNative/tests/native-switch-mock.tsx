import {Switch} from 'react-native';
export default function NativeSwitch({label,onValueChange,accessible: _accessible,disabled,pending,value,...props}:{label:string;value:boolean;disabled:boolean;pending:boolean;accessible?:boolean;onValueChange?:(event:{nativeEvent:{value:boolean}})=>void}) {
  return <Switch {...props} value={value} disabled={disabled||pending} accessibilityLabel={label} accessibilityState={{checked:value,disabled:disabled||pending}} onValueChange={value=>onValueChange?.({nativeEvent:{value}})}/>;
}
