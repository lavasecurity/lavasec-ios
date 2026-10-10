import {useHeldActionScrollLock} from './interaction-lock';
import {localized} from '../app/presentation';
import {Text} from '../app/presentation';
import {ActivityIndicator,Animated,Easing, Pressable, StyleSheet, View, type ColorValue} from 'react-native';
import {useLayoutEffect,useRef,useState} from 'react';
import type {LavaActionButtonProps, LavaCardProps, LavaTextProps, LavaIconButtonProps, LavaIconAction, LavaSelectionAccessoryProps} from './contracts';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {colors, colorForScheme} from './colors.ios';
import {useLavaColorScheme} from './appearance';
import {lavaTokens} from './generated/tokens';
import {foundation} from './foundation';
import {LavaSurface} from './surface.ios';
import {useTextScale} from '../app/text-metrics';
import type {PropsWithChildren} from 'react';
export {LavaToggleRow,LavaToggleControl} from './toggle-row.ios';

// Matches native LavaSelectionAccessory. A blank slot keeps row content stable;
// the full row is the target, so this mark never becomes another AX control.
export function LavaSelectionAccessory({state,disabled=false}:LavaSelectionAccessoryProps) {
  return <View accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" pointerEvents="none"
    style={{width:foundation.control.accessory,height:foundation.control.glyphSlot,flexShrink:0,alignItems:'center',justifyContent:'center'}}>
    {state!=='unselected'&&<Decoration symbol={state==='locked'?'lock.fill':'checkmark.circle.fill'}
      tone={state==='locked'||disabled?'secondary':'green'} fontPointSize={foundation.control.glyph} fontWeight="regular"
      accessible={false} accessibilityElementsHidden style={{width:foundation.control.glyphSlot,height:foundation.control.glyphSlot}}/>}
  </View>;
}

const toneColors = {
  primary: colors.primaryText,
  secondary: colors.secondaryText,
  warning: colors.lavaOrangeText,
  danger: colors.errorText,
};

export function LavaText({children, role = 'rowTitle', tone, testID}: LavaTextProps) {
  const token = lavaTokens.typography[role];
  const foreground = tone === undefined
    ? (role === 'metricNumeral' ? colors.ink : colors.primaryText)
    : toneColors[tone];
  return <Text
    testID={testID}
    allowFontScaling={token.allowFontScaling}
    dynamicTypeRamp={'dynamicTypeRamp' in token ? token.dynamicTypeRamp : undefined}
    style={{fontSize: token.fontSize, fontWeight: token.fontWeight, color: foreground,
      ...('fontFamily' in token ? {fontFamily: token.fontFamily} : {}),
      ...(role === 'metricNumeral' ? {fontVariant: ['tabular-nums' as const]} : {})}}
  >{children}</Text>;
}

export function LavaCard({children, background, role = 'card', testID, borderColor}: LavaCardProps & {borderColor?:ColorValue}) {
  return <LavaSurface testID={testID} role={role} borderColor={borderColor} style={{alignSelf:'stretch'}}
    contentStyle={role==='panel'?{paddingHorizontal:lavaTokens.spacing.infoPanelHorizontalInset,paddingVertical:lavaTokens.spacing.infoPanelVerticalInset}:{padding:lavaTokens.spacing.lg}}>
    {background&&<View pointerEvents="none" accessible={false} accessibilityElementsHidden style={StyleSheet.absoluteFill}>{background}</View>}
    {children}
  </LavaSurface>;
}

export function LavaActionButton({title, role = 'primary', tone='affirmative', onPress, disabled = false, accessibilityHint, subtitle, icon, busy=false, onLongPress, accessibilityActions, onAccessibilityAction, testID,stablePill=false,whiteOutline=false,outlineTransitionDuration=0,labelRole='actionLabel'}: LavaActionButtonProps) {
  const hold=useHeldActionScrollLock(!!onLongPress&&!disabled);
  const fill=useRef(new Animated.Value(whiteOutline?0:1)).current;
  const [outlineAnimating,setOutlineAnimating]=useState(false);
  useLayoutEffect(()=>{
    let current=true;const target=whiteOutline?0:1;
    if(!outlineTransitionDuration){fill.setValue(target);setOutlineAnimating(false);return;}
    setOutlineAnimating(true);
    const animation=Animated.timing(fill,{toValue:target,duration:outlineTransitionDuration,easing:Easing.bezier(.42,0,.58,1),useNativeDriver:true});
    animation.start(()=>{
      if(!current)return;
      // Completed or detached paint is static. Disabling removes the native
      // layers and can cancel their animation; re-enabling must not reconnect
      // opacity nodes whose JS value predates the current target.
      fill.setValue(target);setOutlineAnimating(false);
    });
    return()=>{current=false;animation.stop();};
  },[whiteOutline,outlineTransitionDuration,fill]);
  const scale=useTextScale('headline');
  const foreground: ColorValue = disabled ? colors.secondaryText : whiteOutline?'white':role === 'primary' ? colors.actionForeground
    : role === 'panel' ? colors.panelActionGreen : colors.primaryText;
  return <Pressable
    testID={testID}
    accessibilityRole="button"
    accessibilityLabel={localized(title)}
    accessibilityHint={accessibilityHint?localized(accessibilityHint):undefined}
    accessibilityState={{disabled, busy}}
    accessibilityActions={accessibilityActions}
    onAccessibilityAction={onAccessibilityAction}
    disabled={disabled}
    onPress={onPress}
    onLongPress={onLongPress}
    {...hold}
    style={({pressed}) => [styles.button, stablePill&&{minHeight:Math.ceil(44*scale)+foundation.row.verticalInset*2,borderRadius:foundation.radius.circle,overflow:'hidden'}, {
      backgroundColor: disabled ? colors.disabledSurface : outlineAnimating||whiteOutline?'transparent':role === 'primary' ? (tone==='quiet'?colors.quietControl:tone==='recovery'?colors.lavaOrangeSelectedFill:colors.safeControlGreen)
        : role === 'panel' ? (pressed ? colors.panelActionPressedFill : colors.panelActionFill)
          : pressed ? colors.pressedSurface : colors.cardBackground,
    }]}
  >{({pressed}) => <>
    {outlineAnimating&&!disabled&&<Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill,{borderRadius:foundation.radius.control,borderCurve:'continuous',backgroundColor:colors.safeControlGreen,opacity:fill}]}/>}
    {outlineAnimating&&!disabled&&<Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill,{borderRadius:foundation.radius.control,borderCurve:'continuous',overflow:'hidden',borderColor:'white',borderWidth:1.5,opacity:fill.interpolate({inputRange:[0,1],outputRange:[1,0]})}]}/>}
    {!outlineAnimating&&whiteOutline&&!disabled&&<View pointerEvents="none" style={[StyleSheet.absoluteFill,{borderRadius:foundation.radius.control,borderCurve:'continuous',overflow:'hidden',borderColor:'white',borderWidth:1.5}]}/>}
    {pressed && <View pointerEvents="none" style={[styles.pressOverlay, {
      backgroundColor: colors.pressedSurface, opacity: 0.15,
    }]} />}
    <View style={[styles.actionContent,labelRole==='rowTitle'&&{gap:7}]}>
      {(busy||icon)&&<View style={[styles.actionAccessory,labelRole==='rowTitle'&&{width:16,height:16}]}>{busy?<ActivityIndicator color={foreground} accessible={false}/>:icon?<Decoration symbol={actionSymbols[icon]} tone={disabled?'secondary':role==='primary'?'white':'green'} fontPointSize={labelRole==='rowTitle'?13:foundation.control.glyph} fontWeight={labelRole==='rowTitle'?'semibold':'regular'} accessible={false} style={[styles.actionAccessory,labelRole==='rowTitle'&&{width:16,height:16}]}/>:null}</View>}
      <Text accessible={false} allowFontScaling dynamicTypeRamp={lavaTokens.typography[labelRole].dynamicTypeRamp}
        style={[styles.actionLabel,{fontSize:lavaTokens.typography[labelRole].fontSize,fontWeight:lavaTokens.typography[labelRole].fontWeight,color: foreground, textAlign: 'center'}]}>{title}</Text>
    </View>
    {subtitle&&<Text accessible={false} allowFontScaling dynamicTypeRamp="footnote" style={{fontSize:foundation.type.caption.fontSize,color:foreground,textAlign:'center'}}>{subtitle}</Text>}
  </>}</Pressable>;
}

const actionSymbols: Record<LavaIconAction, string> = {remove:'minus',delete:'trash',undo:'arrow.uturn.backward',reset:'arrow.counterclockwise',back:'chevron.left',close:'xmark',notes:'pencil',assist:'eye',hide:'eye.slash',refresh:'arrow.triangle.2.circlepath',erase:'eraser',confirm:'checkmark',edit:'square.and.pencil',add:'plus',share:'square.and.arrow.up',import:'square.and.arrow.down',automatic:'moon',play:'play.fill',pause:'pause.fill',previous:'backward.end.fill',next:'forward.end.fill',calendar:'calendar',swap:'arrow.up.arrow.down',twoPeople:'person.2'};
/** Related icon actions share one surface; plain children retain individual native-glyph targets. */
export function LavaIconButtonGroup({children}:PropsWithChildren){
  return <View style={{flexDirection:'row',alignItems:'center',backgroundColor:colors.cardBackground,borderRadius:foundation.radius.control,borderCurve:'continuous'}}>{children}</View>;
}
const iconPointSizes: Partial<Record<LavaIconAction,number>> = {
  back:lavaTokens.toolbar.chevronIconPointSize,close:lavaTokens.toolbar.xmarkIconPointSize,
  add:lavaTokens.toolbar.plusIconPointSize,confirm:lavaTokens.toolbar.checkmarkIconPointSize,
  delete:lavaTokens.toolbar.wideIconPointSize,
};
export function LavaIconButton({title, icon, onPress, role='neutral', surface='filled', shape='circle', selected=false, prominent=false, disabled=false, item, onLongPress, longPressDelayMs, testID}: LavaIconButtonProps) {
  const colorScheme = useLavaColorScheme();
  const filled=(selected||prominent)&&!disabled;
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={localized(title)}
    accessibilityValue={item?{text:item}:undefined} accessibilityState={{disabled,selected}} disabled={disabled} onLongPress={disabled?undefined:onLongPress} delayLongPress={longPressDelayMs} onPress={event=>{event?.stopPropagation();onPress();}}
    style={({pressed})=>({width:foundation.control.target,height:foundation.control.target,borderRadius:shape==='rounded'?foundation.radius.control:foundation.radius.circle,alignItems:'center',justifyContent:'center',
      backgroundColor:surface==='plain'?'transparent':colorForScheme(filled?'safeControlGreen':pressed?'pressedSurface':'cardBackground',colorScheme),opacity:surface==='plain'&&pressed?0.55:1})}>
    <Decoration symbol={actionSymbols[icon]} colorScheme={colorScheme} tone={disabled?'tertiary':filled?(surface==='plain'?'green':'white'):role==='destructive'?'error':role==='accent'?'green':'primary'} fontPointSize={iconPointSizes[icon]??lavaTokens.toolbar.framedIconPointSize} fontWeight="semibold"
      accessible={false} accessibilityElementsHidden style={{width:foundation.control.glyphSlot,height:foundation.control.glyphSlot,transform:[{translateY:icon==='edit'?lavaTokens.toolbar.framedIconVerticalOffset:0}]}} />
  </Pressable>;
}

const styles = StyleSheet.create({
  actionContent:{flexDirection:'row',alignItems:'center',justifyContent:'center',alignSelf:'stretch',gap:foundation.space.xs},
  actionAccessory:{width:foundation.control.glyphSlot,height:foundation.control.glyphSlot,alignItems:'center',justifyContent:'center'},
  card: {
    alignSelf: 'stretch', padding: lavaTokens.spacing.lg,
    borderRadius: lavaTokens.surface.cardCornerRadius, borderCurve: 'continuous',
    backgroundColor: colors[lavaTokens.surface.cardBackground],
  },
  panel: {
    backgroundColor: colors[lavaTokens.surface.panelBackground],
  },
  actionLabel: {
    fontSize: lavaTokens.typography.actionLabel.fontSize, fontWeight: lavaTokens.typography.actionLabel.fontWeight,
    color: colors.primaryText, flexShrink: 1,
  },
  button: {
    alignSelf: 'stretch',
    minHeight: lavaTokens.surface.actionButtonHeight, paddingVertical: lavaTokens.row.verticalInset, paddingHorizontal: lavaTokens.row.horizontalInset, gap:lavaTokens.spacing.xs, justifyContent: 'center', alignItems: 'center',
    borderRadius: lavaTokens.surface.controlCornerRadius, borderCurve: 'continuous',
  },
  pressOverlay: {
    position: 'absolute', top: 0, bottom: 0, left: 0, right: 0,
    borderRadius: lavaTokens.surface.controlCornerRadius, borderCurve: 'continuous',
  },
});
