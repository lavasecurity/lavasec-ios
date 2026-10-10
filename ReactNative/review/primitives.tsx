import {mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useOptionalReview,useRouteBodyConcealed} from './ReviewContext';
import {LavaDiscoveryDot} from '../src/LavaDiscoveryDot';
import {GuardianDrawing} from '../src/GuardianDrawing';
import {Alert, localized} from '../app/presentation';
import {Text} from '../app/presentation';
import {createContext,useCallback,useContext,useEffect,useRef, useState,useSyncExternalStore, type PropsWithChildren, type ReactNode} from 'react';
import {AppState, Dimensions, Pressable, RefreshControl, ScrollView, StyleSheet, View, type ScrollViewInstance, type ColorValue, type TextProps, type TextStyle} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {colors} from '../src/colors.ios';
import {lavaTokens} from '../src/generated/tokens';
import {LavaChoice,LavaRowLabel} from '../src';
import {foundation, type CopyRole} from '../src/foundation';
import {ScrollInteractionContext,useScrollInteractionController,useScrollInteractionLock} from '../src/interaction-lock';

export function Copy({children, role='supporting', size, weight, color = colors.primaryText, center = false, testID, lineHeight, mono = false, verbatim=false,strike=false,accessibilityRole,numberOfLines}: PropsWithChildren<{
  role?:CopyRole; size?: number; weight?: TextStyle['fontWeight']; color?: ColorValue; center?: boolean; testID?: string; lineHeight?: number; mono?: boolean; verbatim?:boolean;strike?:boolean;accessibilityRole?:TextProps['accessibilityRole'];numberOfLines?:number;
}>) {
  const token=foundation.type[role];
  const fontSize=size===undefined?token.fontSize:Math.max(foundation.type.caption.fontSize,size);
  return <Text verbatim={verbatim} testID={testID} accessibilityRole={accessibilityRole} numberOfLines={numberOfLines} allowFontScaling dynamicTypeRamp={size===undefined?token.dynamicTypeRamp:fontSize===13?'footnote':fontSize===15?'subheadline':'body'} style={{textDecorationLine:strike?'line-through':undefined,fontSize, fontWeight: weight??token.fontWeight, color, lineHeight:lineHeight===undefined?undefined:Math.max(lineHeight,fontSize*1.25), fontFamily: mono ? "Menlo" : undefined, textAlign: center ? 'center' : 'left'}}>{children}</Text>;
}

export function Symbol({name, size = foundation.control.glyph, tone = 'green', pointSize = 0, weight = 'regular'}: {name: string; size?: number; tone?: string; pointSize?: number; weight?: 'regular' | 'semibold' | 'bold'}) {
  return <Decoration symbol={name} tone={tone} fontPointSize={pointSize} fontWeight={weight} style={{width: size, height: size}} accessible={false} accessibilityElementsHidden />;
}

export type GuardianGesture = 'start' | 'end' | 'tap' | 'reveal';
export function Guardian({size = lavaTokens.guard.mascotSize, mood = 'sleeping', look = 'original', testID, gesturesEnabled=false, onGesture}: {size?: number; mood?: string; look?: string;testID?:string;gesturesEnabled?:boolean;onGesture?:(gesture:GuardianGesture)=>void}) {
  const concealed=useRouteBodyConcealed();
  if(mood==='locked')return <Decoration mood="locked" look={look} style={{width:size,height:size}} accessible={false} accessibilityElementsHidden/>;
  const drawing=<View style={{width:size,height:size}} accessible={false}><GuardianDrawing size={size} mood={mood} look={look} active={!concealed}/><Decoration symbol="guardian.gestures" testID={testID?`${testID}.gesture`:undefined} mood={mood} look={look} guardianGestures={gesturesEnabled} onGuardianGesture={event=>{
    const value=event.nativeEvent.gesture;
    if(value==='start'||value==='end'||value==='tap'||value==='reveal')onGesture?.(value);
  }} style={{position:'absolute',width: size,height:size}} accessible={false} accessibilityElementsHidden /></View>;
  // Keep the existing non-VoiceOver layout anchor while the native leaf owns
  // contact recognition. The visible mascot is still one decorative drawing.
  return testID?<View testID={testID} accessible={false}>{drawing}</View>:drawing;
}

const PageInspectionResetContext=createContext<(reset:()=>void)=>()=>void>(()=>()=>{});
export function usePageInspectionReset(reset:()=>void){
  const register=useContext(PageInspectionResetContext);
  useEffect(()=>register(reset),[register,reset]);
}
// Gesture owners release their lock on cancellation/unmount as well as touch-up.
export function usePageInspectionLock(){
  return useScrollInteractionLock();
}
export function MetricValue({value}:{value:string}) {
  return <Text verbatim allowFontScaling dynamicTypeRamp="largeTitle" style={styles.metric}>{value}</Text>;
}

export type PageScrollSample={offset:number;windowHeight:number};
const PageScrollObservationContext=createContext<(observe:(sample?:PageScrollSample)=>void)=>()=>void>(()=>()=>{});
export function usePageScrollObservation(observe:(sample?:PageScrollSample)=>void){
  const register=useContext(PageScrollObservationContext);
  useEffect(()=>register(observe),[register,observe]);
}

// Only pages with their own text inputs participate in keyboard avoidance. RN
// listens to window-wide keyboard frames, including keyboards in native sheets;
// a read-only page must never retain extra scroll space from those notifications.
export function Screen({children, onEndReached,onRefresh, keyboard = false, wide=false}: PropsWithChildren<{wide?:boolean;keyboard?: boolean;onEndReached?:()=>void;onRefresh?:()=>Promise<unknown>}>) {
  const nativeLayout=usePresentationNativeLayout();
  const review=useOptionalReview();const concealed=useRouteBodyConcealed();
  const insets=useContext(SafeAreaInsetsContext);
  const horizontalContentInsets=insets&&(insets.left!==0||insets.right!==0)?{
    maxWidth:(wide?foundation.layout.wideWidth:foundation.layout.readingWidth)+insets.left+insets.right,
    paddingLeft:lavaTokens.spacing.screenHorizontal+insets.left,paddingRight:lavaTokens.spacing.screenHorizontal+insets.right,
  }:undefined;
  const canInteract=()=>!concealed&&mayInteractWithPresentation(review?.app);
  const interactive=useSyncExternalStore(review?.app?.subscribe??(()=>()=>{}),canInteract);
  const scroll = useRef<ScrollViewInstance>(null);
  const focused = useIsFocused();
  const lockPage=useScrollInteractionController(scroll,true,focused);
  const inspectionResets=useRef(new Set<()=>void>());
  const registerReset=useCallback((reset:()=>void)=>{inspectionResets.current.add(reset);return()=>{inspectionResets.current.delete(reset);};},[]);
  const observingScrollGesture=useRef(false);
  const observers=useRef(new Set<(sample?:PageScrollSample)=>void>());
  const registerObserver=useCallback((observer:(sample?:PageScrollSample)=>void)=>{observers.current.add(observer);return()=>{observers.current.delete(observer);observer();};},[]);
  const resetObservers=()=>{observingScrollGesture.current=false;observers.current.forEach(observer=>observer());};
  const observationActive=useRef(focused&&AppState.currentState==='active');
  useEffect(()=>{
    observationActive.current=focused&&AppState.currentState==='active';resetObservers();
    const lifecycle=AppState.addEventListener('change',state=>{observationActive.current=focused&&state==='active';resetObservers();});
    const geometry=Dimensions.addEventListener('change',resetObservers);
    return()=>{observationActive.current=false;lifecycle.remove();geometry.remove();resetObservers();};
  },[focused]);
  const refreshingRef=useRef(false);const [refreshing,setRefreshing]=useState(false);
  const refresh=()=>{if(!canInteract()||!onRefresh||refreshingRef.current)return;refreshingRef.current=true;setRefreshing(true);void onRefresh().catch(error=>{if(canInteract()&&error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{refreshingRef.current=false;setRefreshing(false);});};
  // The page owns one native scroll view in every orientation. Story columns
  // only arrange content; UIKit adjusts for the actual bars and safe area.
  //
  // The scroll view is the screen's DIRECT child, with no wrapping view. UIKit
  // drives `headerLargeTitle` from the scroll view it finds there: wrap it and the
  // navigation item loses the scroll view it tracks, so the large title fails to
  // lay out and is missing through a push (PR #724 follow-up). `Sheet` in
  // scaffold.tsx keeps the same rule for form-sheet sizing and states the
  // RNScreens behaviour behind it. Safe-area insets come from the one provider at
  // the navigation root; a provider per page also re-measures on mount and
  // foreground, which moved content under a stationary bar.
  // UIKit's scroll-edge material follows the scroll viewport, so it must span
  // the physical width. Only Yoga content receives horizontal safe padding.
  // Include that padding in the width cap to retain the same reading envelope;
  // automatic adjustment still owns vertical bars and the keyboard.
  return <ScrollView ref={scroll} testID="screen.scroll" pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'} refreshControl={onRefresh?<RefreshControl refreshing={refreshing} onRefresh={refresh}/>:undefined} style={[styles.screen,concealed&&{opacity:0}]}
      onLayout={event=>{nativeLayout(event);resetObservers();}} onContentSizeChange={resetObservers}
      onScrollBeginDrag={()=>{observingScrollGesture.current=true;}} onScrollEndDrag={()=>{observingScrollGesture.current=false;}}
      onMomentumScrollBegin={()=>{observingScrollGesture.current=true;}} onMomentumScrollEnd={()=>{observingScrollGesture.current=false;}}
      onTouchStart={()=>{if(canInteract())inspectionResets.current.forEach(reset=>reset());}} scrollEventThrottle={100} onScroll={event=>{const {contentOffset,contentSize,layoutMeasurement}=event.nativeEvent;
        if(observationActive.current&&observingScrollGesture.current)observers.current.forEach(observer=>observer({offset:contentOffset.y,windowHeight:Dimensions.get('window').height}));
        if(canInteract()&&onEndReached&&contentOffset.y+layoutMeasurement.height>=contentSize.height-140)onEndReached();}}
      contentInsetAdjustmentBehavior="automatic"
      automaticallyAdjustKeyboardInsets={keyboard && focused} keyboardDismissMode="interactive" keyboardShouldPersistTaps="handled" contentContainerStyle={[styles.content,wide&&{maxWidth:foundation.layout.wideWidth},horizontalContentInsets]}>
    <PageScrollObservationContext.Provider value={registerObserver}><ScrollInteractionContext.Provider value={lockPage}><PageInspectionResetContext.Provider value={registerReset}>{children}</PageInspectionResetContext.Provider></ScrollInteractionContext.Provider></PageScrollObservationContext.Provider>
  </ScrollView>;
}

export function Section({title, children, footer}: PropsWithChildren<{title: string; footer?: string}>) {
  return <View style={styles.section}>
    <Copy role="section" accessibilityRole="header" color={colors.secondaryText}>{title}</Copy>
    {children}
    {footer && <Copy role="caption" color={colors.secondaryText}>{footer}</Copy>}
  </View>;
}

// Choose the action's meaning explicitly. Sheets, pickers and commands use the
// same leading glyph/title anatomy as page links, without a forward indicator.
type RowIntent = 'page' | 'task' | 'external' | 'disclosure';
type RowContentProps = {
  title: string; summary?: string; icon?: string; intent: RowIntent; testID?: string; verbatimSummary?:boolean;
  leading?:ReactNode; trailing?:ReactNode; expanded?:boolean; attention?:boolean;
};

// Content and its activation target have separate owners so illustrated panels
// can reuse the actual row anatomy without nesting a second button. A missing
// leading glyph consumes no space; every destination keeps the accessory axis.
export function RowAccessory({intent,testID,children,expanded=false,attention=false,attentionTestID}: PropsWithChildren<{intent:RowIntent;testID?:string;expanded?:boolean;attention?:boolean;attentionTestID?:string}>) {
  const symbol=intent==='external'?'arrow.up.right':intent==='disclosure'&&expanded?'chevron.down':'chevron.right';
  const accessoryWidth=attention?foundation.discovery.dotSize+foundation.space.xs+foundation.control.accessoryGlyph:foundation.row.disclosureWidth;
  return <View testID={testID} style={[styles.accessory,{width:accessoryWidth}]}>
    {attention&&<LavaDiscoveryDot testID={attentionTestID}/>}
    {children===undefined?intent !== 'task' && <Symbol name={symbol} size={foundation.control.accessoryGlyph} tone="secondary" />:children}
  </View>;
}
export function RowContent({title,summary,icon,intent,testID,verbatimSummary=false,leading,trailing,expanded,attention}:RowContentProps) {
  const glyph=leading??(icon?<Symbol name={icon} size={foundation.control.glyphSlot} pointSize={foundation.control.glyph} tone="primary" weight="regular" />:null);
  return <View style={styles.row}>
    {glyph&&<View testID={`${testID ?? `row.${title}`}.glyph`} style={styles.badge}>{glyph}</View>}
    <View style={styles.rowText}>
      <LavaRowLabel title={title} summary={summary} verbatimSummary={verbatimSummary}/>
    </View>
    <RowAccessory testID={`${testID ?? `row.${title}`}.accessory`} attentionTestID={`${testID ?? `row.${title}`}.new`} intent={intent} expanded={expanded} attention={attention}>{trailing}</RowAccessory>
  </View>;
}
export function Row({title, summary, icon, onPress, intent, testID, verbatimSummary=false,expanded,attention}: {
  title: string; summary?: string; icon?: string; onPress: () => void; intent: RowIntent; testID?: string; verbatimSummary?:boolean; expanded?:boolean; attention?:boolean;
}) {
  return <Pressable testID={testID ?? `row.${title}`} accessibilityRole="button" accessibilityLabel={[localized(title),summary&&(verbatimSummary?summary:localized(summary))].filter(Boolean).join(', ')}
    accessibilityHint={attention?localized("New"):undefined}
    accessibilityState={intent==='disclosure'?{expanded:expanded??false}:undefined}
    onPress={onPress} style={({pressed}) => pressed && {opacity:foundation.interaction.pressedOpacity}}>
    <RowContent title={title} summary={summary} icon={icon} intent={intent} testID={testID} verbatimSummary={verbatimSummary} expanded={expanded} attention={attention}/>
  </Pressable>;
}
// A disclosure remains in place. The caller owns expanded content/state; the
// shared row owns its button semantics, text anatomy and right-to-down accessory.
export function DisclosureRow({title,icon,expanded,onChange,testID}:{title:string;icon?:string;expanded:boolean;onChange:(expanded:boolean)=>void;testID?:string}) {
  return <Row title={title} icon={icon} intent="disclosure" expanded={expanded} onPress={()=>onChange(!expanded)} testID={testID}/>;
}

export function Choice<T extends string>({options, value, onChange, label, disabled=false}: {options: readonly T[]; value: T; onChange: (value: T) => void | Promise<unknown>; label: string; disabled?:boolean}) {
  return <LavaChoice label={localized(label)} testID={label} options={options.map(option => ({value: option, label: localized(option)}))} value={value} disabled={disabled} onValueChange={onChange} />;
}

export function Metric({value, label}: {value: string; label: string}) {
  return <View style={{alignItems: 'center', gap: 2, minHeight: 74}}>
    <Text allowFontScaling={false} style={styles.metric}>{value}</Text>
    <Text allowFontScaling dynamicTypeRamp="subheadline" style={{fontSize: 15, fontWeight: '600', minHeight: 20, color: colors.secondaryText, textAlign: 'center'}}>{label}</Text>
  </View>;
}

export const styles = StyleSheet.create({
  screen: {flex: 1, backgroundColor: colors.groupedBackground},
  content: {width:'100%',alignSelf:'center',maxWidth:foundation.layout.readingWidth,paddingHorizontal: lavaTokens.spacing.screenHorizontal, paddingTop: lavaTokens.spacing.screenTop, paddingBottom: lavaTokens.spacing.screenBottom, gap: lavaTokens.spacing.xl},
  section: {gap: 10},
  row: {flexDirection: 'row', alignItems: 'center', gap: foundation.row.gap, paddingHorizontal: foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset, minHeight: foundation.row.standard},
  rowText: {flex: 1},
  badge: {width: foundation.control.glyphSlot, alignItems: 'center', justifyContent: 'center'},
  accessory: {alignItems:'center',justifyContent:'center',flexDirection:'row',gap:foundation.space.xs},
  metric: {minHeight: 52, fontSize: 42, fontFamily: 'ui-rounded', fontWeight: '700', fontVariant: ['tabular-nums'], color: colors.ink},
});
