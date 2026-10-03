import type {PropsWithChildren} from 'react';
import {StyleSheet, View, type ColorValue, type StyleProp, type ViewStyle} from 'react-native';
import {colors} from './colors.ios';
import {lavaTokens} from './generated/tokens';

/** Continuous fill/clip and a sibling outline share bounds without clipping the outline twice. */
export function LavaSurface({children, role='card', borderColor, plain=false, style, contentStyle, testID}: PropsWithChildren<{
  role?:'card'|'panel'; borderColor?:ColorValue; plain?:boolean; style?:StyleProp<ViewStyle>; contentStyle?:StyleProp<ViewStyle>; testID?:string;
}>) {
  const fill=plain?'transparent':colors[role==='panel'?lavaTokens.surface.panelBackground:lavaTokens.surface.cardBackground];
  const stroke=borderColor??(role==='panel'?colors[lavaTokens.surface.panelStroke]:undefined);
  return <View testID={testID} style={style}>
    <View testID={testID?`${testID}.content`:undefined} style={[shape,{overflow:'hidden',backgroundColor:fill},contentStyle]}>{children}</View>
    {/* Fabric uses Core Animation's continuous border only on a clipping layer.
        Its nonclipping border-image fallback is circular, so combining that path
        with a continuous parent clip shaved the corner arcs (infra #241 F241-03). */}
    {stroke!==undefined&&<View testID={testID?`${testID}.surface`:undefined} pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
      style={[StyleSheet.absoluteFill,shape,{overflow:'hidden',borderColor:stroke,borderWidth:lavaTokens.surface.outlineWidth}]} />}
  </View>;
}
const shape:ViewStyle={borderRadius:lavaTokens.surface.cardCornerRadius,borderCurve:'continuous'};
