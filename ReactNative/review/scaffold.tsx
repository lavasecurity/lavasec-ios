import {useHeldActionScrollLock} from '../src/interaction-lock';
import NativeTextField from '../specs/LavaTextFieldNativeComponent';
import {useTextScale} from '../app/text-metrics';
import {localized, Text} from '../app/presentation';
import {Children, createContext, isValidElement, useContext, useLayoutEffect,useSyncExternalStore,useRef, useState, type PropsWithChildren, type Ref, type ReactNode} from 'react';
import {KeyboardAvoidingView, Pressable, SafeAreaView, ScrollView, StyleSheet, TextInput, View, useWindowDimensions, type ScrollViewInstance, type ColorValue} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import type {NativeStackNavigationOptions, NativeStackHeaderItem} from '@react-navigation/native-stack';
import {colors} from '../src/colors.ios';
import {LavaActionButton, LavaCard, LavaControlContent, LavaIconButton, LavaRowLabel, LavaSelectionAccessory, LavaToggleRow, type LavaIconAction} from '../src';
import {foundation} from '../src/foundation';
import {Copy, Symbol} from './primitives';
import {lavaTokens} from '../src/generated/tokens';
import {symbolPresentation} from '../src/icon-presentation.ios';
import {mayInteractWithPresentation} from '../app/read-cache';
import {useOptionalReview} from './ReviewContext';
import type {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';

const ExplanationLinkContext=createContext(false);

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
export function InputRow({title, children}: PropsWithChildren<{title: string}>) {
  return <View style={{gap:6}}><Copy role="fieldLabel" color={colors.secondaryText}>{title}</Copy>{children}</View>;
}
export function DomainInput({label,placeholder,onChange,onSubmit}: {label:string;placeholder:string;onChange:(value:string)=>void;onSubmit:(value:string)=>void}) {
  const scale=useTextScale();
  const [measured,setMeasured]=useState({scale:0,height:0});
  return <NativeTextField autoFocus inputLabel={localized(label)} placeholder={localized(placeholder)} resetRevision={0} fontPointSize={17*scale}
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
export function Toggle({title, summary, value, onChange, disabled = false, standalone = false, optimistic = true, accessibilityHint,testID}: {
  title: string; summary?:string; accessibilityHint?:string; value: boolean; onChange: (next: boolean) => void | Promise<unknown>; disabled?: boolean; standalone?: boolean; optimistic?:boolean;testID?:string;
}) {
  return <View style={standalone?s.group:undefined}><LavaToggleRow testID={testID} title={title} summary={summary} accessibilityHint={accessibilityHint?localized(accessibilityHint):undefined} value={value} onValueChange={onChange} disabled={disabled} optimistic={optimistic}/></View>;
}
export function Search({value, onChange, label = 'Search domains'}: {value: string; onChange: (value: string) => void; label?: string}) {
  const scale=useTextScale();
  return <View style={s.search}><Symbol name="magnifyingglass" size={18} tone="secondary" /><TextInput allowFontScaling={false} accessibilityLabel={localized(label)} placeholder={localized(label)} value={value} onChangeText={onChange} autoCapitalize="none" autoCorrect={false} clearButtonMode="while-editing" style={[s.searchInput,{fontSize:17*scale,minHeight:Math.max(48,26*scale+16)}]} placeholderTextColor={colors.secondaryText} /></View>;
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
  headerLargeTitleEnabled:false,headerStyle:{backgroundColor:'transparent'},
};
// The navigation stack owns every full-sheet bar. Content retains the same
// direct ScrollView structure required by react-native-screens form sheets.
export const fullSheetPresentation:NativeStackNavigationOptions = {
  ...nativeInlineHeader,presentation:'formSheet',headerShown:true,headerTransparent:false,
  sheetAllowedDetents:[1],sheetGrabberVisible:false,
};
// Full-screen modals keep the same native-bar ownership without a grabber. The
// consuming screen adds the scaffold Close action as its only left item; its
// immersive content owns the screen and may clear the bar title.
export const fullScreenModalPresentation:NativeStackNavigationOptions = {
  presentation:'fullScreenModal',headerShown:true,headerLargeTitleEnabled:false,headerTransparent:false,headerBackVisible:false,
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
export function Sheet({children, footer, header, scrollRef}: PropsWithChildren<{footer?: ReactNode; header?: ReactNode; scrollRef?: Ref<ScrollViewInstance>}>) {
  const navigation = useNavigation();
  const owner=useRef<SheetOwner>({mounted:true,listeners:new Set()});
  useLayoutEffect(()=>{owner.current.mounted=true;return()=>{
    owner.current.mounted=false;for(const listener of owner.current.listeners)listener();
    navigation.setOptions({unstable_sheetFooter:undefined});
  };},[navigation]);
  const review=useOptionalReview();
  const canInteract=()=>mayInteractWithPresentation(review?.app);
  const interactive=useSyncExternalStore(review?.app?.subscribe??(()=>()=>{}),canInteract);
  useLayoutEffect(() => {
    navigation.setOptions({unstable_sheetFooter: footer ? () => owner.current.mounted?<NativeSheetFooter app={review?.app} live={review?.live} owner={owner.current}>{footer}</NativeSheetFooter>:null : undefined});
  }, [navigation, footer, review?.app,review?.live, interactive]);
  // RNScreens 4.27 sizes form-sheet scroll views only when they are direct
  // children of its content wrapper (optionally after one non-collapsing header).
  // A wrapping View triggers its legacy frame correction and doubles the sheet
  // origin. Its native footer slot also keeps controls pinned above the safe area.
  return <>
    {header&&<View collapsable={false} testID="sheet.pinned-header" pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'}>
      {header&&<View style={s.sheetHeader}>{header}</View>}
    </View>}
    <ScrollView ref={scrollRef} pointerEvents={interactive?'auto':'none'} accessibilityElementsHidden={!interactive} importantForAccessibility={interactive?'auto':'no-hide-descendants'} style={{flex:1,backgroundColor:colors.groupedBackground}} automaticallyAdjustKeyboardInsets contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive" contentContainerStyle={[s.sheetContent,!!header&&{paddingTop:8}]}>{children}</ScrollView>
  </>;
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
  useLayoutEffect(() => {
    // UIKit owns these controls outside the retained React content view. Check
    // authority when a queued callback arrives, while keeping its visual state.
    const guardCallback=<Arguments extends unknown[]>(callback:((...args:Arguments)=>void)|undefined)=>
      callback?(...args:Arguments)=>{if(owner.current.mounted&&canInteract())callback(...args);}:undefined;
    const guardContent=(content:ReactNode)=><View pointerEvents={canInteract()?'auto':'none'} accessibilityElementsHidden={!canInteract()} importantForAccessibility={canInteract()?'auto':'no-hide-descendants'}>{content}</View>;
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
  }, [navigation, verbatimTitle, review?.app, interactive, ...dependencies]);
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
  searchInput: {flex: 1, minHeight: 48, fontSize: 17, color: colors.primaryText},
  sheetContent: {width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.xl, paddingBottom: foundation.control.target, gap: foundation.space.xl},
  sheetHeader: {paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.md, paddingBottom: foundation.row.verticalInset},
  sheetFooter: {width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal: foundation.space.screenHorizontal, paddingTop: foundation.space.md, paddingBottom: foundation.space.md, backgroundColor: colors.groupedBackground},
});
