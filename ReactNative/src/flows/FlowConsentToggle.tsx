import {Pressable,View,type ColorValue} from 'react-native';
import {Text} from '../../app/presentation';
import {LavaToggleControl} from '../index';
import {foundation} from '../foundation';
import {useToggleRequest} from '../ui/behavior/toggle';

/** A plain form Toggle owns only its label and the measured platform switch.
 * It deliberately has no list-row target floor or content insets. */
export function FlowConsentToggle({title,value,onChange,disabled=false,labelColor,testID}:{
  title:string;value:boolean;onChange:(value:boolean)=>void|Promise<unknown>;disabled?:boolean;labelColor:ColorValue;testID?:string;
}){
  const {intent,change}=useToggleRequest({onValueChange:onChange,disabled});
  const pending=intent!==undefined;
  return <View testID={testID===undefined?undefined:`${testID}.row`} style={{flexDirection:'row',alignItems:'center',gap:foundation.space.sm}}>
    <Pressable testID={testID===undefined?undefined:`${testID}.label`} accessible={false} disabled={disabled||pending} onPress={()=>change(!value)} style={{flex:1}}>
      <Text testID={testID===undefined?undefined:`${testID}.title`} accessible={false} allowFontScaling dynamicTypeRamp="body" style={{fontSize:17,fontWeight:'400',color:labelColor}}>{title}</Text>
    </Pressable>
    <LavaToggleControl title={title} value={value} onValueChange={change} disabled={disabled} pending={pending} optimistic={false} testID={testID}/>
  </View>;
}
