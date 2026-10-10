import {useHeldActionScrollLock} from '../src/interaction-lock';
import NativeTextField from '../specs/LavaTextFieldNativeComponent';
import {BufferedInput,type BufferedInputHandle} from './BufferedInput';
import NativeDecoration from '../specs/LavaDecorationNativeComponent';
import {useLavaColorScheme} from '../src/appearance';
import {useTextScale} from '../app/text-metrics';
import {localized, Text} from '../app/presentation';
import {Children, createContext, isValidElement, useContext, useImperativeHandle, useLayoutEffect,useSyncExternalStore,useRef, useState, type ComponentRef,type PropsWithChildren, type Ref, type ReactNode} from 'react';
import {KeyboardAvoidingView, Platform, Pressable, SafeAreaView, ScrollView, StyleSheet, TextInput, View, useWindowDimensions, type ScrollViewInstance, type ColorValue} from 'react-native';
import {useNavigation,type ParamListBase} from '@react-navigation/native';
import {HeaderHeightContext} from '@react-navigation/elements';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import type {NativeStackNavigationOptions, NativeStackHeaderItem, NativeStackNavigationProp} from '@react-navigation/native-stack';
import {colors} from '../src/colors.ios';
import {LavaActionButton, LavaCard, LavaControlContent, LavaIconButton, LavaRowLabel, LavaSelectionAccessory, LavaToggleRow, type LavaIconAction} from '../src';
import {foundation} from '../src/foundation';
import {Copy, Symbol} from './primitives';
import {lavaTokens} from '../src/generated/tokens';
import {symbolPresentation} from '../src/icon-presentation.ios';
import {mayInteractWithPresentation} from '../app/read-cache';
import {useOptionalReview,useRouteBodyConcealed} from './ReviewContext';
import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import type {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import {ordinaryPageHeader} from './navigation-scaffold';

const ExplanationLinkContext=createContext(false);

export function nativeFlowHeader(dark:boolean){
  const rgb=(color:readonly number[])=>`rgb(${color.map(value=>Math.round(value*255)).join(',')})`;
  return {...nativeInlineHeader,headerShown:true,headerTintColor:rgb(lavaTokens.colors.navigationForeground[dark?'dark':'light']),
    contentStyle:{backgroundColor:rgb(lavaTokens.colors.groupedBackground[dark?'dark':'light'])}};
}

export const onboardingHeaderOptions={headerTransparent:true,headerStyle:{backgroundColor:'transparent'},contentStyle:{backgroundColor:'transparent'},gestureEnabled:false};

// These are the semantic counterparts of LavaInfoPanel, LavaCondensedList,
// lavaRow and LavaSheetScaffold. Screens choose an anatomy instead of inventing
// a card size, row face or presentation for each destination.
export function Panel({children, warning = false, accent}: PropsWithChildren<{warning?: boolean; accent?: ColorValue}>) {
  return <View><LavaCard role="panel">{children}</LavaCard>{(warning || accent) && <View pointerEvents="none" style={{position:'absolute',top:0,bottom:0,left:0,right:0,borderWidth:1,borderRadius:foundation.radius.surface,borderCurve:'continuous',borderColor:accent??colors.lavaOrange}} />}</View>;
}
// Each variant shares one flex slot, whose natural height fits the largest content.
// This is the Yoga counterpart to a SwiftUI ZStack. Hidden variants contribute only
// layout, never accessibility or touches. No measured height or scroll correction.
export function StableVariants({selectedKey, variants, alignment='top'}: {selectedKey:string; variants:readonly {key:string; content:ReactNode}[]; alignment?:'top'|'center'}) {
  const activeKey=variants.some(variant=>variant.key===selectedKey)?selectedKey:variants[0]?.key;
  return <View style={{flexDirection:'row',alignItems:alignment==='center'?'center':'flex-start'}}>{variants.map((variant,index)=>{
    const active=variant.key===activeKey;
    return <View key={variant.key} pointerEvents={active?'auto':'none'} accessibilityElementsHidden={!active} importantForAccessibility={active?'auto':'no-hide-descendants'} style={{width:'100%',flexShrink:0,marginLeft:index===0?0:'-100%',opacity:active?1:0}}>{variant.content}</View>;
  })}</View>;
}
export function Info({title, description, icon, warning = false, children}: PropsWithChildren<{title: string; description?: string; icon?: string; warning?: boolean}>) {
  const scale = useTextScale(foundation.type.section.dynamicTypeRamp);
  return <Panel warning={warning}><View style={{gap: 10}}>
    <View style={{flexDirection: 'row', alignItems: 'flex-start', gap: 6}}>{icon && <View style={{width:28*scale,height:22*scale,alignItems:'center',justifyContent:'center'}}><Symbol name={icon} size={28*scale} pointSize={17*scale} tone={warning?"accentOrange":"green"} /></View>}<View style={{flex: 1}}><Copy role="section" lineHeight={22} color={colors.ink}>{title}</Copy></View></View>
    {description && <Copy role="supporting" color={colors.secondaryText}>{description}</Copy>}
    {children}
  </View></Panel>;
}
export function Group({children, plain = false, separators = true, footer, dividerInset = 16, testID, tone='neutral'}: PropsWithChildren<{tone?:'neutral'|'green';plain?: boolean; separators?: boolean; footer?: ReactNode; dividerInset?: number; testID?: string}>) {
  const rows = Children.toArray(children);
  // Preserve React's child identity when conditional settings insert/remove a
  // row. Position keys remounted surviving native controls and lost local state.
  // Transparent paint does not remove the separators between repeated rows.
  return <View testID={testID} style={[s.group,tone==='green'&&{backgroundColor:colors.softGreen},plain&&{backgroundColor:'transparent'}]}>{rows.map((child, i) => <View key={isValidElement(child)?child.key:i}>{i > 0 && separators && <View style={[s.divider,{marginLeft:dividerInset}]} />}{child}</View>)}{footer}</View>;
}
export function StatusPill({title,symbol,tone='green'}:{title:string;symbol:string;tone?:'green'|'orange'|'secondary'}) {
  const scale=useTextScale(foundation.type.caption.dynamicTypeRamp);
  const color=tone==='orange'?colors.lavaOrangeText:tone==='secondary'?colors.secondaryText:colors.safeGreen;
  const fill=tone==='orange'?colors.lavaOrangeSoft:tone==='secondary'?colors.secondaryText:colors.softGreen;
  return <View style={{minHeight:24,paddingHorizontal:8,paddingVertical:3,borderRadius:999,overflow:'hidden',flexDirection:'row',alignItems:'center',gap:5,flexShrink:1}}>
    <View pointerEvents="none" style={[StyleSheet.absoluteFill,{backgroundColor:fill,opacity:tone==='secondary'?0.12:1}]}/>
    <Symbol name={symbol} tone={tone} size={12*scale} pointSize={11*scale} weight="bold"/>
    <Text allowFontScaling dynamicTypeRamp={foundation.type.caption.dynamicTypeRamp} style={{fontSize:foundation.type.caption.fontSize,fontWeight:'600',color,flexShrink:1}}>{title}</Text>
  </View>;
}
export function AddAction({title, onPress, disabled=false}: {title: string; onPress: () => void; disabled?:boolean}) {
  return <LavaActionButton title={title} role="panel" icon="add" disabled={disabled} onPress={onPress}/>;
}
export function SwapOrderAction({onPress,disabled=false}: {onPress:()=>void;disabled?:boolean}) {
  return <LavaActionButton title="Swap order" role="panel" icon="swap" disabled={disabled} onPress={onPress}/>;
}
export function InputRow({title,labelTestID,children}: PropsWithChildren<{title:string;labelTestID?:string}>) {
  return <View style={{gap:6}}><Copy role="fieldLabel" testID={labelTestID} color={colors.secondaryText}>{title}</Copy>{children}</View>;
}
export function DomainInput({label,placeholder,onChange,onSubmit,editable=true}: {label:string;placeholder:string;onChange:(value:string)=>void;onSubmit:(value:string)=>void;editable?:boolean}) {
  const scale=useTextScale();
  const [measured,setMeasured]=useState({scale:0,height:0});
  return <NativeTextField autoFocus editable={editable} inputLabel={localized(label)} placeholder={localized(placeholder)} resetRevision={0} fontPointSize={17*scale}
    onChange={event=>onChange(event.nativeEvent.text)} onSubmit={event=>onSubmit(event.nativeEvent.text)}
    onSizeChange={event=>setMeasured({scale,height:event.nativeEvent.height})}
    style={{height:measured.scale===scale?Math.max(22,measured.height):22*scale}} />;
}
// Keep the label/value group intact under text-size or width pressure. This is
// the RN counterpart to native fit-or-stack rows; it never shrinks user text.
export function AdaptivePair({label,children,alignment='trailing'}: PropsWithChildren<{label:ReactNode;alignment?:'leading'|'trailing'}>) {
  const window=useWindowDimensions(); const scale=useTextScale();
  const [width,setWidth]=useState(window.width-72);
  const stacked=width/scale<300;
  return <View onLayout={event=>setWidth(event.nativeEvent.layout.width)} style={{flexDirection:stacked?'column':'row',gap:stacked?6:16,alignItems:stacked?'stretch':'center'}}>
    <View style={stacked?undefined:s.pairPart}>{label}</View>
    <View style={[!stacked&&s.pairPart,{alignItems:stacked||alignment==='leading'?'flex-start':'flex-end'}]}>{children}</View>
  </View>;
}
// Switch rows reserve their wider lane even when it contains an edit button or
// nothing. Retain any larger native measurement so mode changes cannot rewrap text.
export function AccessorySlot({children,switchable=false}: PropsWithChildren<{switchable?:boolean}>) {
  const [measuredWidth,setMeasuredWidth]=useState(0);
  const minWidth=switchable?Math.max(foundation.nativeSwitch.width,measuredWidth):foundation.control.accessory;
  return <View onLayout={switchable?event=>{const width=event.nativeEvent.layout.width;if(Number.isFinite(width)&&width>minWidth)setMeasuredWidth(width);}:undefined}
    style={{minWidth,minHeight:foundation.control.target,alignItems:'center',justifyContent:'center'}}>{children}</View>;
}
export function Quiet({children}: PropsWithChildren) { return <Copy size={13} color={colors.secondaryText}>{children}</Copy>; }
export function Link({title, onPress, footer = false, testID}: {title: string; onPress: () => void; footer?: boolean; testID?:string}) {
  const inExplanation=useContext(ExplanationLinkContext);
  return <Pressable testID={testID} accessibilityRole="link" accessibilityLabel={localized(title)} onPress={onPress} style={[footer||inExplanation?s.quietLink:s.inlineLink,footer&&{alignSelf:'stretch'}]}><Copy testID={testID?`${testID}.label`:undefined} size={13} lineHeight={20} color={colors.safeGreen} weight="600">{title}</Copy></Pressable>;
}
export function LinkGroup({children}: PropsWithChildren) {
  return <View style={{flexDirection:'row',flexWrap:'wrap',columnGap:16,alignItems:'center',justifyContent:'center'}}>{children}</View>;
}
// Match LavaQuietFooter: the visible text line, not the expanded target, owns flow.
export function QuietFooter({note, title, onPress}: {note: string; title: string; onPress: () => void}) {
  return <View style={{gap: lavaTokens.spacing.explanationToLink}}><Quiet>{note}</Quiet><Link title={title} onPress={onPress} footer /></View>;
}
// A labeled native control uses the same row-title face as a switch/list row.
// Keep this in the scaffold so steppers cannot fall back to body-copy sizing.
export function Control({children, title}: PropsWithChildren<{title?: string}>) {
  return <View style={s.group}><LavaControlContent title={title}>{children}</LavaControlContent></View>;
}
// Filter-content lists (blocklists, blocked and allowed domains) lead each row
// with the outcome's stroke-only mark. The shape comes from the shared
// `outcomeSymbols` outline pair (generated from `LavaOutcomeSymbol`), so native
// and RN cannot drift; a filled, tinted mark is too heavy inside a dense list,
// so these rows use the outline in the ordinary label color. The glyph is
// decorative — the row's own label carries the meaning for VoiceOver.
const filterOutcomeSymbol = {
  blocked: foundation.outcome.blockedOutline,
  allowed: foundation.outcome.allowedOutline,
} as const;
export function ListRow({title, subtitle, metadata, icon, leading, trailing, trailingRole='control', onPress, disabled = false, action = false, color, testID, selected, selectionLocked=false, metadataPrefix, verbatimTitle=false, pending=false, onLongPress, minHeight, verticalPadding, expanded, separateTrailing=false, accessibilityHint, outcome}: {
  title: string; subtitle?: string; metadata?: string; icon?: string; leading?: ReactNode; trailing?: ReactNode; outcome?: keyof typeof filterOutcomeSymbol;
  accessibilityHint?:string; trailingRole?:'control'|'disclosure'; separateTrailing?:boolean; expanded?:boolean; minHeight?: number; verticalPadding?: number; onPress?: () => void; onLongPress?:()=>void; pending?:boolean; disabled?: boolean; action?: boolean; color?: ColorValue; testID?: string; selected?: boolean; selectionLocked?:boolean; metadataPrefix?: string; verbatimTitle?:boolean;
}) {
  const hold=useHeldActionScrollLock(!!onLongPress&&!disabled);
  // Visible content owns the inset; independent 44pt targets share that space.
  const content = <View style={[s.listRowContent,verticalPadding!==undefined&&{paddingVertical:verticalPadding}]}>
    {leading ?? (outcome ? <Symbol name={filterOutcomeSymbol[outcome]} tone="primary"/> : (icon && <View style={{width: foundation.control.glyphSlot, alignItems: 'center'}}><Symbol name={icon} size={foundation.control.glyphSlot} pointSize={foundation.control.glyph} tone={disabled ? 'secondary' : color === colors.errorText ? 'error' : 'primary'} /></View>))}
    <View style={{flex: 1}}><LavaRowLabel title={title} summary={subtitle} verbatimTitle={verbatimTitle} disabled={disabled} titleColor={color} strike={pending}>
      {metadata && <View style={{minHeight:20,flexDirection:"row",flexWrap:'wrap',gap:foundation.space.xs,alignItems:"center"}}>{metadataPrefix&&<View style={{borderRadius:foundation.radius.compact,paddingHorizontal:foundation.space.sm,paddingVertical:foundation.space.xs,backgroundColor:colors.disabledSurface}}><Copy role="caption" weight="600" color={colors.secondaryText}>{metadataPrefix}</Copy></View>}<Copy role="supporting" color={colors.secondaryText}>{metadata}</Copy></View>}
    </LavaRowLabel></View>
  </View>;
  const selection=selectionLocked||selected!==undefined
    ? <LavaSelectionAccessory state={selectionLocked?'locked':selected?'selected':'unselected'} disabled={disabled}/>:null;
  const accessory=trailing!==undefined&&<View style={{minWidth:trailingRole==='disclosure'&&!separateTrailing?foundation.row.disclosureWidth:foundation.control.accessory,alignItems:'center',justifyContent:'center'}}>{trailing}</View>;
  const style = [s.listRow, minHeight!==undefined&&{minHeight}];
  const accessibility={accessibilityRole:'button' as const,accessibilityLabel:[verbatimTitle?title:localized(title),subtitle&&localized(subtitle)].filter(Boolean).join(', '),
    accessibilityValue:metadata?{text:[metadataPrefix&&localized(metadataPrefix),localized(metadata)].filter(Boolean).join(', ')}:undefined,
    accessibilityState:{disabled,selected,expanded}};
  // Independent row actions cannot be nested inside the navigation/rename
  // target: VoiceOver and responder hit testing must see two sibling controls.
  if(separateTrailing&&(onPress||onLongPress))return <View style={style}>
    <Pressable accessibilityHint={accessibilityHint?localized(accessibilityHint):undefined} testID={testID} {...accessibility} disabled={disabled} onPress={onPress} onLongPress={onLongPress} {...hold}
      style={({pressed})=>[{flex:1,alignSelf:'stretch',minHeight:foundation.control.target,flexDirection:'row',alignItems:'center',gap:foundation.row.gap},pressed&&{opacity:foundation.interaction.pressedOpacity}]}>{content}{selection}</Pressable>{accessory}
  </View>;
  return onPress||onLongPress ? <Pressable accessibilityHint={accessibilityHint?localized(accessibilityHint):undefined} testID={testID} {...accessibility} disabled={disabled} onPress={onPress} onLongPress={onLongPress} {...hold} style={({pressed}) => [...style, pressed && {opacity:foundation.interaction.pressedOpacity}]}>{content}{selection}{accessory}</Pressable>
    : <View testID={testID} style={style}>{content}{selection}{accessory}</View>;
}
export function Toggle({title, summary, titleRole, value, onChange, disabled = false, pending = false, standalone = false, optimistic = true, accessibilityHint,testID}: {
  title: string; summary?:string; titleRole?:'rowTitle'|'cardTitle'; accessibilityHint?:string; value: boolean; onChange: (next: boolean) => void | Promise<unknown>; disabled?: boolean; pending?: boolean; standalone?: boolean; optimistic?:boolean;testID?:string;
}) {
  return <View style={standalone?s.group:undefined}><LavaToggleRow testID={testID} title={title} summary={summary} titleRole={titleRole} accessibilityHint={accessibilityHint?localized(accessibilityHint):undefined} value={value} onValueChange={onChange} disabled={disabled} pending={pending} optimistic={optimistic}/></View>;
}
// Catalog controls own their native capsule material. The shared sticky strip
// stays clear while rows passing beneath each control are diffused by UIKit.
export function CatalogControlMaterial() {
  const scheme=useLavaColorScheme();
  return <NativeDecoration symbol="catalog.control.material" colorScheme={scheme} pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={StyleSheet.absoluteFill}/>;
}
export function Search({ref,value, onChange, label = 'Search domains',resetRevision=0,surface='card'}: {ref?:Ref<BufferedInputHandle>;value: string; onChange: (value: string) => void; label?: string;resetRevision?:number;surface?:'card'|'catalog'}) {
  const scale=useTextScale();
  const catalog=surface==='catalog';
  const target=catalog?foundation.control.target:48;
  // Filtering can be slower than typing. Keep the native edit buffer as the
  // typing owner; only an explicit external reset writes text back into it.
  return <View style={[s.search,catalog&&s.catalogControl]}>{catalog&&<CatalogControlMaterial/>}<Symbol name="magnifyingglass" size={18} tone={catalog?'primary':'secondary'} /><BufferedInput ref={ref} allowFontScaling={false} accessibilityLabel={localized(label)} placeholder={localized(label)} value={value} resetRevision={resetRevision} onChangeText={onChange} autoCapitalize="none" autoCorrect={false} clearButtonMode="while-editing" selectionColor={colors.safeGreen} style={[s.searchInput,{fontSize:17*scale,minHeight:Math.max(target,26*scale+16)}]} placeholderTextColor={colors.secondaryText} /></View>;
}
// The isolated review host uses the same centered credential composition. The
// full app continues to present its native authenticated credential flow.
export function PasscodeEntry({value,onChange,topInset}:{value:string;onChange:(value:string)=>void;topInset:number}){
  return <KeyboardAvoidingView behavior="padding" keyboardVerticalOffset={topInset+foundation.control.target} style={{flex:1,backgroundColor:colors.groupedBackground}}>
    <View style={{flex:1,alignItems:'center',justifyContent:'center',gap:foundation.space.xl,padding:foundation.space.screenHorizontal}}>
      <Symbol name="lock.shield.fill" size={foundation.control.target}/>
      <View style={{gap:foundation.space.sm}}><Copy role="heading" center>Set Passcode</Copy><Copy center color={colors.secondaryText}>Enter a 4-digit code for Lava</Copy></View>
      <View style={{flexDirection:'row',gap:foundation.space.md}}>{[0,1,2,3].map(index=><View key={index} style={{width:foundation.space.lg,height:foundation.space.lg,borderRadius:foundation.radius.circle,backgroundColor:index<value.length?colors.safeGreen:colors.disabledSurface}}/>)}</View>
      <TextInput accessibilityLabel={localized('Passcode')} autoFocus keyboardType="number-pad" secureTextEntry maxLength={4} value={value} onChangeText={onChange} style={{width:1,height:1,color:colors.primaryText,opacity:0.01}}/>
    </View>
  </KeyboardAvoidingView>;
}
// Native inline bars share the domain-list header's clear background. UIKit
// owns the toolbar buttons and material; content controls retain their layout.
export const nativeInlineHeader:NativeStackNavigationOptions = {
  headerStyle:{backgroundColor:'transparent'},...ordinaryPageHeader(),headerLargeTitleEnabled:false,
};
// The navigation stack owns every full-sheet bar. Content retains the same
// direct ScrollView structure required by react-native-screens form sheets.
export const fullSheetPresentation:NativeStackNavigationOptions = {
  ...nativeInlineHeader,headerLargeTitleEnabled:false,
  presentation:'formSheet',headerShown:true,
  sheetAllowedDetents:[1],sheetGrabberVisible:false,
};
// Full-screen modals keep the same native-bar ownership without a grabber. The
// consuming screen adds the scaffold Close action as its only left item; its
// immersive content owns the screen and may clear the bar title.
export const fullScreenModalPresentation:NativeStackNavigationOptions = {
  ...nativeInlineHeader,headerLargeTitleEnabled:false,
  presentation:'fullScreenModal',headerShown:true,headerBackVisible:false,
};
// UIKit mounts its footer outside the screen's React subtree. Subscribe here so
// an already-published native footer follows revocation before its owning body
// has committed a replacement callback or finished retiring.
type SheetOwner={mounted:boolean;listeners:Set<()=>void>};
function NativeSheetFooter({app,live,owner,children}:{app?:AppStore;live?:AppSnapshot;owner:SheetOwner;children:ReactNode}) {
  const subscribe=(listener:()=>void)=>{owner.listeners.add(listener);const unsubscribe=app?.subscribe(listener);return()=>{owner.listeners.delete(listener);unsubscribe?.();};};
  const interactive=useSyncExternalStore(subscribe,()=>owner.mounted&&mayInteractWithPresentation(app));
  const concealed=useSyncExternalStore(subscribe,()=>!owner.mounted||!!app&&(!!app.getPresentationHydration?.().required
    ||(app.getSnapshot?!app.getSnapshot().snapshot&&!app.getSnapshot().displaySnapshot:!live)));
  return <SafeAreaView testID="sheet.native-footer" pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive}
    importantForAccessibility={interactive?'auto':'no-hide-descendants'} style={{backgroundColor:colors.groupedBackground}}>
    <View style={[s.sheetFooter,concealed&&{opacity:0}]}>{children}</View>
  </SafeAreaView>;
}
export function useSheetHeaderInset(){
  const height=useContext(HeaderHeightContext)??0;
  return Platform.OS==='ios'?height:0;
}
export function Sheet({children, footer, header, scrollRef,headerMaterial=true,scrollMode='form'}: PropsWithChildren<{footer?: ReactNode; header?: ReactNode; scrollRef?: Ref<ScrollViewInstance>;headerMaterial?:boolean;scrollMode?:'form'|'list'}>) {
  const nativeLayout=usePresentationNativeLayout();
  const navigation = useNavigation<NativeStackNavigationProp<ParamListBase>>();
  const scheme=useLavaColorScheme();
  const insets=useContext(SafeAreaInsetsContext);
  const horizontalPadding=insets&&(insets.left!==0||insets.right!==0)?{
    paddingLeft:foundation.space.screenHorizontal+insets.left,paddingRight:foundation.space.screenHorizontal+insets.right,
  }:undefined;
  const horizontalReadingInsets=horizontalPadding?{...horizontalPadding,maxWidth:foundation.layout.readingWidth+insets!.left+insets!.right}:undefined;
  const nativeHeaderInset=useSheetHeaderInset();
  const [viewportHeight,setViewportHeight]=useState(0);
  const [controlsHeight,setControlsHeight]=useState(0);
  const nativeScroll=useRef<ScrollViewInstance>(null);
  const initializedOffset=useRef(false);
  useImperativeHandle(scrollRef,()=>nativeScroll.current!,[]);
  const pinnedOffset=useRef({x:0,y:-nativeHeaderInset});
  const latestOffset=useRef(pinnedOffset.current);
  const previousInset=useRef(nativeHeaderInset);
  if(previousInset.current!==nativeHeaderInset){
    const atTop=latestOffset.current.y<=-previousInset.current+1;
    pinnedOffset.current={x:latestOffset.current.x,y:atTop?-nativeHeaderInset:latestOffset.current.y+previousInset.current-nativeHeaderInset};
    previousInset.current=nativeHeaderInset;
  }
  useLayoutEffect(()=>{
    if(scrollMode==='list')return;
    return navigation.addListener('transitionEnd',event=>{
      // UIKit's form-sheet presentation can adjust the initial offset after
      // Fabric lays out the body. Settle it once when that transition finishes.
      if(!event.data.closing&&!initializedOffset.current){
        initializedOffset.current=true;
        nativeScroll.current?.scrollTo({...pinnedOffset.current,animated:false});
      }
    });
  },[navigation,scrollMode]);
  const owner=useRef<SheetOwner>({mounted:true,listeners:new Set()});
  useLayoutEffect(()=>{owner.current.mounted=true;return()=>{
    owner.current.mounted=false;for(const listener of owner.current.listeners)listener();
    navigation.setOptions({unstable_sheetFooter:undefined});
  };},[navigation]);
  const review=useOptionalReview();
  const concealed=useRouteBodyConcealed();
  const canInteract=()=>!concealed&&mayInteractWithPresentation(review?.app);
  const interactive=useSyncExternalStore(review?.app?.subscribe??(()=>()=>{}),canInteract);
  useLayoutEffect(() => {
    navigation.setOptions({unstable_sheetFooter: footer ? () => owner.current.mounted?<NativeSheetFooter app={review?.app} live={review?.live} owner={owner.current}>{footer}</NativeSheetFooter>:null : undefined});
  }, [navigation, footer, review?.app,review?.live, interactive]);
  // Native-stack makes its first scroll descendant use automatic safe-area
  // insets on iOS. Start the list viewport below the bar, so its content starts
  // at zero with no duplicated inset or negative scrollTo correction (RN clamps
  // commands using raw rather than adjusted insets). Fixed controls are siblings,
  // so neither a pan nor keyboard adjustment can move them. Only their measured
  // height is reserved in the natural-sized results; rows still pass underneath
  // the individual glass capsules. Keep the scroll view first for sheet sizing.
  if(scrollMode==='list')return <View onLayout={nativeLayout} pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'} style={{flex:1,backgroundColor:colors.groupedBackground,...(concealed?{opacity:0}:{})}}>
    <ScrollView testID="sheet.results" ref={nativeScroll} style={{flex:1,marginTop:nativeHeaderInset}} bounces={false} alwaysBounceVertical={false} automaticallyAdjustKeyboardInsets contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" scrollIndicatorInsets={{top:controlsHeight}} contentContainerStyle={s.sheetPinnedContent}>
      <View style={{height:controlsHeight}}/>
      <View style={[s.sheetPinnedBody,horizontalReadingInsets]}>{children}</View>
    </ScrollView>
    {header&&<View collapsable={false} testID="sheet.pinned-header" pointerEvents="box-none" onLayout={event=>setControlsHeight(event.nativeEvent.layout.height)} style={{position:'absolute',top:nativeHeaderInset,left:0,right:0}}>
      {headerMaterial&&<NativeDecoration symbol="sheet.header.material" colorScheme={scheme} pointerEvents="none" style={StyleSheet.absoluteFill}/>}
      <View style={[s.sheetHeader,horizontalPadding]}>{header}</View>
    </View>}
  </View>;
  // Keep the direct ScrollView required by native form sheets. A sticky child
  // lets content pass behind the picker controls instead of reserving an opaque
  // strip above the scroll surface. The native footer still owns bottom actions.
  // RN's sticky-header animation only reads the explicit contentInset. Use the
  // navigator's measured bar height so its controls don't slide behind the bar.
  // Keep ordinary editor sheets viewport-sized while their fields resize.
  // Start at the inset's top, then preserve the scrolled position when rotation
  // changes the native bar height. Ordinary scrolling remains owned by UIKit.
  // Keep the material's scroll viewport full-width. Safe edges belong to its
  // content, with the cap expanded by that padding to retain the reading band.
  // The detached native footer already has its own native SafeAreaView.
  return <ScrollView ref={nativeScroll} onLayout={event=>{nativeLayout(event);setViewportHeight(event.nativeEvent.layout.height);}} stickyHeaderIndices={header?[0]:undefined} pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'} style={{flex:1,backgroundColor:colors.groupedBackground,...(concealed?{opacity:0}:{})}} automaticallyAdjustKeyboardInsets automaticallyAdjustContentInsets={false} contentInset={{top:nativeHeaderInset}} contentOffset={pinnedOffset.current} onScroll={event=>{latestOffset.current=event.nativeEvent.contentOffset;}} scrollEventThrottle={16} contentInsetAdjustmentBehavior="never" scrollIndicatorInsets={{top:nativeHeaderInset}} keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentContainerStyle={[header?s.sheetPinnedContent:[s.sheetContent,horizontalReadingInsets],{minHeight:Math.max(0,viewportHeight-nativeHeaderInset)}]}>
    {header&&<View collapsable={false} testID="sheet.pinned-header" pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'}>
      {headerMaterial&&<NativeDecoration symbol="sheet.header.material" colorScheme={scheme} pointerEvents="none" style={StyleSheet.absoluteFill}/>}
      <View style={[s.sheetHeader,horizontalPadding]}>{header}</View>
    </View>}
    {header?<View style={[s.sheetPinnedBody,horizontalReadingInsets]}>{children}</View>:children}
  </ScrollView>;
}
const toolbarSymbols={'chevron.left':'back',xmark:'close',checkmark:'confirm',trash:'delete','square.and.pencil':'edit',moon:'automatic','arrow.clockwise':'refresh','arrow.triangle.2.circlepath':'refresh','arrow.counterclockwise':'reset',plus:'add','square.and.arrow.up':'share','square.and.arrow.down':'import',calendar:'calendar',pencil:'notes',eye:'assist','eye.slash':'hide','arrow.uturn.backward':'undo'} as const satisfies Readonly<Record<string,LavaIconAction>>;
export type ToolbarSymbol = keyof typeof toolbarSymbols;
// All actions use the navigation bar's own item pipeline, including Import.
// Stable semantic identifiers let UIKit match like actions across transitions.
export const toolbarButton = (label: string, symbol: keyof typeof toolbarSymbols, onPress: () => void, disabled = false, testID?:string): NativeStackHeaderItem & {label:string;onPress:()=>void;disabled:boolean} => {
  const action=toolbarSymbols[symbol];
  if(!action)throw new Error(`Unregistered toolbar glyph: ${symbol}`);
  const tintColor=action==='confirm'?colors.safeControlGreen:action==='delete'?colors.errorText:colors.navigationForeground;
  return {type:'button',label:localized(label),accessibilityLabel:localized(label),identifier:action==='import'?'lava.toolbar.labeled.import':testID??`lava.toolbar.${action}`,
    icon:{type:'sfSymbol',name:symbol},tintColor,variant:action==='confirm'?'prominent':'plain',onPress,disabled,sharesBackground:action!=='confirm'};
};
export function toolbarToggle(label:string,symbol:keyof typeof toolbarSymbols,selected:boolean,onPress:()=>void,disabled=false,testID?:string) {
  return {...toolbarButton(label,symbol,onPress,disabled,testID),selected,sharesBackground:false,
    variant:selected?'prominent' as const:'plain' as const,tintColor:selected?colors.safeControlGreen:colors.navigationForeground};
}
// Search in a pushed list belongs to UISearchController. Its native navigation
// and keyboard lifecycle avoids competing with an in-content RN input's scroll.
export function nativeSearchOptions(placeholder:string,onChange:(value:string)=>void):NonNullable<NativeStackNavigationOptions['headerSearchBarOptions']> {
  return {placeholder:localized(placeholder),autoCapitalize:'none',placement:'stacked',hideWhenScrolling:false,
    onChangeText:event=>onChange(event.nativeEvent.text),onCancelButtonPress:()=>onChange('')};
}
export function useToolbar(options: NativeStackNavigationOptions, dependencies: readonly unknown[], verbatimTitle=false) {
  const navigation = useNavigation();
  const owner=useRef({mounted:true});
  const ownedOptions=useRef(new Set<keyof NativeStackNavigationOptions>());
  useLayoutEffect(()=>{
    owner.current.mounted=true;
    return()=>{
      owner.current.mounted=false;
      // Native options outlive an erased React body. Release renderer/search
      // closures as well as denying callbacks from the retired owner.
      navigation.setOptions(Object.fromEntries([...ownedOptions.current].map(key=>[key,undefined])));
    };
  },[navigation]);
  const review=useOptionalReview();
  const canInteract=()=>mayInteractWithPresentation(review?.app);
  const interactive=useSyncExternalStore(review?.app?.subscribe??(()=>()=>{}),canInteract);
  const readEpoch=review?.app?.getReadEpoch?.();
  useLayoutEffect(() => {
    // UIKit owns these controls outside the retained React content view. Check
    // authority when a queued callback arrives, while keeping its visual state.
    const guardCallback=<Arguments extends unknown[]>(callback:((...args:Arguments)=>void)|undefined)=>
      callback?(...args:Arguments)=>{if(owner.current.mounted&&canInteract()&&review?.app?.getReadEpoch?.()===readEpoch)callback(...args);}:undefined;
    const guardContent=(content:ReactNode)=>{const current=canInteract()&&review?.app?.getReadEpoch?.()===readEpoch;return <View pointerEvents={current?'auto':'none'} accessibilityElementsHidden={!current} importantForAccessibility={current?'auto':'no-hide-descendants'} style={!current?{opacity:0}:undefined}>{content}</View>;};
    const guardMenu=(items:import('@react-navigation/native-stack').NativeStackHeaderItemMenu['menu']['items']):typeof items=>items.map(item=>
      item.type==='action'?{...item,onPress:guardCallback(item.onPress)!}:{...item,items:guardMenu(item.items)});
    const guardItems=(items:NativeStackHeaderItem[]):NativeStackHeaderItem[]=>items.map(item=>{
      if(item.type==='button')return {...item,onPress:guardCallback(item.onPress)!};
      if(item.type==='menu')return {...item,menu:{...item.menu,items:guardMenu(item.menu.items)}};
      if(item.type==='custom')return {...item,element:guardContent(item.element)};
      return item;
    });
    const search=options.headerSearchBarOptions;
    const closureOptions={unstable_headerLeftItems:options.unstable_headerLeftItems,unstable_headerRightItems:options.unstable_headerRightItems,
      headerLeft:options.headerLeft,headerRight:options.headerRight,headerSearchBarOptions:options.headerSearchBarOptions,title:options.title};
    for(const key of Object.keys(closureOptions) as (keyof typeof closureOptions)[]) {
      if(Object.prototype.hasOwnProperty.call(options,key))ownedOptions.current.add(key);
    }
    navigation.setOptions({...options,
      ...(options.gestureEnabled!==undefined?{gestureEnabled:interactive&&options.gestureEnabled}:{}),
      ...(options.unstable_headerLeftItems?{unstable_headerLeftItems:(...args:Parameters<NonNullable<NativeStackNavigationOptions['unstable_headerLeftItems']>>)=>owner.current.mounted?guardItems(options.unstable_headerLeftItems!(...args)):[]}:{}),
      ...(options.unstable_headerRightItems?{unstable_headerRightItems:(...args:Parameters<NonNullable<NativeStackNavigationOptions['unstable_headerRightItems']>>)=>owner.current.mounted?guardItems(options.unstable_headerRightItems!(...args)):[]}:{}),
      ...(options.headerLeft?{headerLeft:(...args:Parameters<NonNullable<NativeStackNavigationOptions['headerLeft']>>)=>owner.current.mounted?guardContent(options.headerLeft!(...args)):null}:{}),
      ...(options.headerRight?{headerRight:(...args:Parameters<NonNullable<NativeStackNavigationOptions['headerRight']>>)=>owner.current.mounted?guardContent(options.headerRight!(...args)):null}:{}),
      ...(search?{headerSearchBarOptions:{...search,onChangeText:guardCallback(search.onChangeText),onCancelButtonPress:guardCallback(search.onCancelButtonPress),onSearchButtonPress:guardCallback(search.onSearchButtonPress),onFocus:guardCallback(search.onFocus),onBlur:guardCallback(search.onBlur),onOpen:guardCallback(search.onOpen),onClose:guardCallback(search.onClose)}}:{}),
      ...(options.title&&!verbatimTitle?{title:localized(options.title)}:{})});
  }, [navigation, verbatimTitle, review?.app, interactive, readEpoch, ...dependencies]);
}
const s = StyleSheet.create({
  pairPart:foundation.layout.horizontalPart,
  footerLink: {minHeight: 44, alignItems: 'flex-start', justifyContent: 'flex-start'},
  inlineLink: {minHeight:44,minWidth:44,justifyContent:'center'},
  quietLink: {minHeight:44,minWidth:44,justifyContent:'center',paddingVertical:lavaTokens.spacing.quietLinkInteractionInset,marginVertical:-lavaTokens.spacing.quietLinkInteractionInset},
  group: {backgroundColor: colors.cardBackground, borderRadius: foundation.radius.surface, borderCurve: 'continuous', overflow: 'hidden'},
  divider: {height: StyleSheet.hairlineWidth, backgroundColor: colors.separator, marginHorizontal: foundation.row.horizontalInset},
  listRow: {minHeight: foundation.row.standard, paddingHorizontal: foundation.row.horizontalInset, flexDirection: 'row', alignItems: 'center', gap: foundation.row.gap},
  listRowContent: {flex:1,minWidth:0,paddingVertical:foundation.row.verticalInset,flexDirection:'row',alignItems:'center',gap:foundation.row.gap},
  search: {minHeight: 48, paddingHorizontal: foundation.row.horizontalInset, gap: foundation.space.sm, flexDirection: 'row', alignItems: 'center', borderRadius: foundation.radius.control, backgroundColor: colors.cardBackground},
  catalogControl: {minHeight:foundation.control.target,borderRadius:foundation.radius.circle,overflow:'hidden',backgroundColor:'transparent'},
  searchInput: {flex: 1, minHeight: 48, fontSize: 17, color: colors.primaryText},
  sheetContent: {width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.xl, paddingBottom: foundation.control.target, gap: foundation.space.xl},
  sheetPinnedContent: {paddingBottom:foundation.control.target},
  sheetPinnedBody: {width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal:foundation.space.screenHorizontal,paddingTop:foundation.space.sm,gap:foundation.space.xl},
  sheetHeader: {paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.md, paddingBottom: foundation.row.verticalInset},
  sheetFooter: {width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.md, paddingBottom: foundation.space.md, backgroundColor: colors.groupedBackground},
});
