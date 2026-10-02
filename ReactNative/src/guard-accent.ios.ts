import {DynamicColorIOS, type ColorValue} from 'react-native';
import NativeReview from '../specs/NativeLavaReview';
import {colors} from './colors.ios';

const accents: Record<string,{light:string;dark:string}> = JSON.parse(NativeReview.getGuardAccents());
export function guardAccent(look:string):ColorValue {
  const accent=accents[look];
  return accent?DynamicColorIOS(accent):colors.lavaOrangeText;
}
