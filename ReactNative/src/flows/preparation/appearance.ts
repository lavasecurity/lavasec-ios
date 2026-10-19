import {StyleSheet,type TextStyle} from 'react-native';
import {colors} from '../../colors';
import {foundation} from '../../foundation';
import type {PreparationTextProps} from './PreparationScreen';

export const preparationFlowStyles=StyleSheet.create({root:{flex:1}});
export function preparationTextAppearance(kind:PreparationTextProps['kind']){
  const token=kind==='title'?foundation.type.setupHeading:kind==='supporting'?foundation.type.body:foundation.type.supporting;
  return {ramp:token.dynamicTypeRamp,style:{...token,textAlign:'center',color:kind==='title'?colors.primaryText:colors.secondaryText,
    fontWeight:kind==='previous'||kind==='quiet'?'600':token.fontWeight} as TextStyle};
}
