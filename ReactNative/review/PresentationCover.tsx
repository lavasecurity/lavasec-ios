import type {ReactNode} from 'react';
import {View,type ColorValue} from 'react-native';
import {Text} from '../app/presentation';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';

/** The same opaque frame covers root chrome and separately presented UIKit routes. */
export function PresentationCover({background=colors.groupedBackground,testID='lava-privacy-cover',children}: {
  background?:ColorValue;testID?:string;children?:ReactNode;
}) {
  return <View testID={testID} accessibilityViewIsModal
    style={{flex:1,backgroundColor:background,justifyContent:'center',alignItems:'center',gap:foundation.space.md}}>
    <Decoration testID={`${testID}.symbol`} symbol="lock.shield.fill" tone="green" fontPointSize={0} fontWeight="semibold"
      style={{width:foundation.control.target,height:foundation.control.target}} accessible={false} accessibilityElementsHidden/>
    <Text allowFontScaling dynamicTypeRamp={foundation.type.heading.dynamicTypeRamp}
      style={{fontSize:foundation.type.heading.fontSize,fontWeight:foundation.type.heading.fontWeight,color:colors.primaryText,textAlign:'center'}}>Lava Security</Text>
    {children}
  </View>;
}
