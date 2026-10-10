import {useContext,type ReactNode} from 'react';
import {View,type ColorValue} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {Text} from '../app/presentation';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';

/** Only content follows safe sides; the enclosing background keeps its extent. */
export function PresentationContent({children,testID,centered=false}:{children?:ReactNode;testID?:string;centered?:boolean}) {
  const insets=useContext(SafeAreaInsetsContext);
  return <View testID={testID} style={{alignSelf:'stretch',paddingLeft:insets?.left??0,paddingRight:insets?.right??0,
    ...(centered?{alignItems:'center' as const,gap:foundation.space.md}: {})}}>{children}</View>;
}

/** The same opaque frame covers root chrome and separately presented UIKit routes. */
export function PresentationCover({background=colors.groupedBackground,testID='lava-privacy-cover',children}: {
  background?:ColorValue;testID?:string;children?:ReactNode;
}) {
  return <View testID={testID} accessibilityViewIsModal
    style={{flex:1,backgroundColor:background,justifyContent:'center',alignItems:'center',gap:foundation.space.md}}>
    <PresentationContent testID={`${testID}.content`} centered>
    <Decoration testID={`${testID}.symbol`} symbol="lock.shield.fill" tone="green" fontPointSize={0} fontWeight="semibold"
      style={{width:foundation.control.target,height:foundation.control.target}} accessible={false} accessibilityElementsHidden/>
    <Text allowFontScaling dynamicTypeRamp={foundation.type.heading.dynamicTypeRamp}
      style={{fontSize:foundation.type.heading.fontSize,fontWeight:foundation.type.heading.fontWeight,color:colors.primaryText,textAlign:'center'}}>Lava Security</Text>
    {children}
    </PresentationContent>
  </View>;
}
