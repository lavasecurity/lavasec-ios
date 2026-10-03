import {useMascotTapInteraction,useMascotDownwardScroll} from './mascot-interaction';
import type {PropsWithChildren} from 'react';
import {useRef,useState} from 'react';
import {useNavigation} from '@react-navigation/native';
import {ActivityIndicator, StyleSheet, View, useWindowDimensions} from 'react-native';
import {localized} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {guardAccent} from '../src/guard-accent.ios';
import {LavaControlContent} from '../src';
import Slider from '../specs/LavaSliderNativeComponent';
import {Copy, DisclosureRow, Guardian, Row, RowAccessory, RowContent, Section, Symbol} from './primitives';
import {AddAction, SwapOrderAction, Group, ListRow, Quiet, toolbarButton, useToolbar} from './scaffold';

// DNS and WireGuard share native item ownership in both modes. A custom Back
// and Cancel occupy the same slot, avoiding a system-back/custom-item handoff.
export function useSettingsEditToolbar({editing,busy,canEdit=true,saveDisabled=false,onEdit,onCancel,onSave}:{
  editing:boolean;busy:boolean;canEdit?:boolean;saveDisabled?:boolean;onEdit:()=>void;onCancel:()=>void;onSave:()=>void;
}) {
  const navigation=useNavigation();
  const actions=useRef({onEdit,onCancel,onSave});actions.current={onEdit,onCancel,onSave};
  useToolbar({headerBackVisible:false,gestureEnabled:!editing,
    unstable_headerLeftItems:()=>[toolbarButton(editing?'Cancel editing':'Back',editing?'xmark':'chevron.left',
      ()=>editing?actions.current.onCancel():navigation.goBack(),busy,'lava.settings.leading')],
    unstable_headerRightItems:()=>editing?[toolbarButton('Save','checkmark',()=>actions.current.onSave(),busy||saveDisabled,'lava.settings.edit')]
      :canEdit?[toolbarButton('Edit','square.and.pencil',()=>actions.current.onEdit(),busy,'lava.settings.edit')]:[],
  },[editing,busy,canEdit,saveDisabled]);
}

// Settings has one quiet grouping language: shared rows/controls inside a neutral
// surface, with the same inset dividers as every repeated utility group. Helpers
// stay outside that surface, flush with section headings; row metadata stays inside.
export function SettingsSurface({children,testID,footer,tone='neutral'}:PropsWithChildren<{testID?:string;footer?:string;tone?:'neutral'|'green'}>) {
  const surface=<Group testID={testID} tone={tone}>{children}</Group>;
  return footer?<View style={settingsStyles.section}>{surface}<Quiet>{footer}</Quiet></View>:surface;
}
export function SettingsGroup({title,children,footer,testID}:PropsWithChildren<{title:string;footer?:string;testID?:string}>) {
  return <Section title={title} footer={footer}><SettingsSurface testID={testID}>{children}</SettingsSurface></Section>;
}
export function SettingsInset({children}:PropsWithChildren) { return <View style={settingsStyles.inset}>{children}</View>; }
// The ordered DNS/VPN panel has one footer slot: Add until full, then Swap.
export function OrderedListAction({count,addTitle,onAdd,onSwap,disabled=false}:{count:number;addTitle:string;onAdd:()=>void;onSwap:()=>void;disabled?:boolean}) {
  return <SettingsInset>{count===2?<SwapOrderAction disabled={disabled} onPress={onSwap}/>
    :<AddAction title={addTitle} disabled={disabled} onPress={onAdd}/>}</SettingsInset>;
}
export function SettingsStack({children}:PropsWithChildren) { return <View style={settingsStyles.stack}>{children}</View>; }
export function SettingsControl({children,title}:PropsWithChildren<{title?:string}>) {
  return <LavaControlContent title={title}>{children}</LavaControlContent>;
}
// The navigation title names the page. Its introduction supplies one useful
// body paragraph; callers cannot add another title or decorative glyph tier.
export function SettingsIntro({summary,action}: {summary:string;action?:{title:string;onPress:()=>void}}) {
  return <View style={{borderRadius:foundation.radius.surface,borderCurve:'continuous',backgroundColor:colors.softGreen}}><View style={{padding:foundation.space.lg}}><Copy role="supporting">{summary}</Copy></View>{action&&<Row title={action.title} intent="page" onPress={action.onPress}/>}</View>;
}
export function SettingsStatus({title,description,icon,busy=false}: {title:string;description?:string;icon:string;busy?:boolean}) {
  return <RowContent title={title} summary={description!==title?description:undefined}
    leading={<SettingsGlyph name={icon} busy={busy}/>} intent="task"/>;
}
export function SettingsMessage({children,warning=false}:PropsWithChildren<{warning?:boolean}>) {
  return <View accessibilityLiveRegion="polite" style={settingsStyles.message}>{warning&&<Symbol name="exclamationmark.circle" tone="orange"/>}<View style={settingsStyles.flex}><Copy role="supporting" color={warning?colors.errorText:colors.secondaryText}>{children}</Copy></View></View>;
}
export function SettingsGlyph({name,busy=false}: {name:string;busy?:boolean}) {
  return <View style={settingsStyles.glyph}>{busy?<ActivityIndicator/>:<Symbol name={name} tone="primary" size={foundation.control.glyphSlot} pointSize={foundation.control.glyph}/>}</View>;
}
export function SettingsDisclosure({title,icon,expanded,onChange,children,testID}:PropsWithChildren<{title:string;icon?:string;expanded:boolean;onChange:(expanded:boolean)=>void;testID?:string}>) {
  return <View style={settingsStyles.section}><SettingsSurface testID={testID}><DisclosureRow title={title} icon={icon} expanded={expanded} onChange={onChange}/></SettingsSurface>
    {expanded&&<SettingsStack>{children}</SettingsStack>}
  </View>;
}

function useCompactSettingsScene() {
  const {width}=useWindowDimensions();const scale=useTextScale();
  const [available,setAvailable]=useState(Math.min(width,foundation.layout.readingWidth)-foundation.space.screenHorizontal*2);
  return {compact:available/scale<foundation.layout.compactThreshold,onLayout:(event:{nativeEvent:{layout:{width:number}}})=>setAvailable(event.nativeEvent.layout.width)};
}
// The selected real Guard is the visual anchor. Its quote and its details use
// semantic type, and the entire preview remains one clear navigation target.
// A canonical outline belongs to the surface, never to each child. One native
// border keeps a uniform inset stroke through all four corners without clipping.
function GuardOutline({look,children}:{look:string;children:React.ReactNode}) {
  return <View style={{borderWidth:1.5,borderColor:guardAccent(look),borderRadius:foundation.radius.surface,borderCurve:'continuous'}}>{children}</View>;
}
// Catalog choices and the Customization entry delegate to the same row. Only
// the trailing state differs: selection/lock in the catalog, disclosure here.
export function SettingsGuardRow({look,title,subtitle,selected,locked=false,onPress,testID,navigation=false}: {
  look:string;title:string;subtitle?:string;selected?:boolean;locked?:boolean;onPress:()=>void;testID?:string;navigation?:boolean;
}) {
  return <ListRow action verbatimTitle testID={testID} title={title} subtitle={subtitle}
    leading={<SettingsGuardPortrait look={look} locked={locked}/>}
    selected={navigation?undefined:selected} selectionLocked={!navigation&&locked} disabled={!navigation&&locked}
    trailingRole={navigation?'disclosure':'control'} trailing={navigation?<RowAccessory intent="page" testID="customization.guard.accessory"/>:undefined} onPress={onPress}/>;
}
export function SettingsGuardPreview({look,title,subtitle,onPress}: {look:string;title:string;subtitle?:string;onPress:()=>void}) {
  return <GuardOutline look={look}><SettingsGuardRow look={look} title={title} subtitle={subtitle}
    navigation testID="Choose Lava Guard" onPress={onPress}/></GuardOutline>;
}
export function SettingsGuardSpotlight({look,variants}: {look:string;variants:readonly {id:string;title:string;description:string;tip:string}[]}) {
  const {compact,onLayout}=useCompactSettingsScene();
  const guard=variants.find(variant=>variant.id===look)??variants[0];
  if(!guard)return null;
  return <GuardOutline look={look}><View onLayout={onLayout} style={[settingsStyles.guardPreview,compact&&settingsStyles.vertical]}>
    <Guardian mood="awake" look={look} size={foundation.control.target*1.5}/>
    <View style={[!compact&&settingsStyles.horizontalPart,settingsStyles.stack]}>
      <Copy role="heading" verbatim>{guard.title}</Copy><Copy role="body" verbatim>{guard.description}</Copy><Quiet>{guard.tip}</Quiet>
    </View>
  </View></GuardOutline>;
}
export function SettingsGuardPortrait({look='original',locked=false}: {look?:string;locked?:boolean}) {
  return <View style={settingsStyles.portrait}><Guardian look={look} mood={locked?'locked':'awake'} size={foundation.control.target}/></View>;
}
export function SettingsTextPreview() {
  return <View testID="customization.text-preview"><SettingsInset>
    <Copy role="body">This is how your text will look.</Copy>
  </SettingsInset></View>;
}
export function SettingsTextSlider({value,disabled,onChange}:{value:number;disabled:boolean;onChange:(value:number)=>void}) {
  return <View style={[settingsStyles.control,disabled&&settingsStyles.disabled]}>
    <Symbol name="textformat.size.smaller" size={foundation.control.glyph} tone="secondary"/>
    <Slider label={localized('Text Size')} value={value} maximum={6} disabled={disabled} tintColor={colors.safeGreen}
      onValueChange={event=>onChange(event.nativeEvent.value)} style={settingsStyles.slider}/>
    <Symbol name="textformat.size.larger" size={foundation.control.glyph} tone="secondary"/>
  </View>;
}
export function SettingsSubscriptionStatus({look,expiration}: {look:string;expiration?:string}) {
  const interaction=useMascotTapInteraction();
  const downwardScroll=useMascotDownwardScroll(interaction.active,interaction.scrollDown);
  return <SettingsSurface><View style={settingsStyles.subscription}>
    <View onLayout={downwardScroll.onLayout} collapsable={false} accessible accessibilityRole="button" accessibilityLabel={localized('Thank you for your support')} onAccessibilityTap={interaction.tap}><Guardian testID="plus.thank-you.mascot" mood={interaction.grateful?'grateful':'awake'} look={look} size={foundation.control.target*2} gesturesEnabled={interaction.active} onGesture={gesture=>{if(gesture==='tap')interaction.tap();}}/></View><Copy role="heading" center>Thank you for your support</Copy>
    <Copy role="body" center color={colors.secondaryText}>Lava Security Plus is active</Copy>{!!expiration&&<Quiet>{expiration}</Quiet>}
  </View></SettingsSurface>;
}
export function SettingsLoading({title}: {title:string}) {
  return <SettingsSurface><View style={settingsStyles.subscription}><ActivityIndicator size="large"/><Copy role="body" center>{title}</Copy></View></SettingsSurface>;
}
export function SettingsPrice({price,commitment}: {price:string;commitment?:string}) {
  return <View style={settingsStyles.price}><Copy role="row" color={colors.safeGreen}>{price}</Copy>{!!commitment&&<Copy role="caption" color={colors.secondaryText}>{commitment}</Copy>}</View>;
}
export const settingsStyles=StyleSheet.create({
  section:{gap:foundation.space.sm},
  surface:{backgroundColor:colors.cardBackground,borderRadius:foundation.radius.surface,borderCurve:'continuous',overflow:'hidden'},
  inset:{paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,gap:foundation.space.sm},
  stack:{gap:foundation.space.md},
  copyStack:{gap:foundation.row.metadataGap},
  message:{flexDirection:'row',alignItems:'flex-start',gap:foundation.space.sm},
  flex:{flex:1},
  horizontalPart:foundation.layout.horizontalPart,
  glyph:{width:foundation.control.glyphSlot,alignItems:'center',justifyContent:'center'},
  control:{minHeight:foundation.row.standard,paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,flexDirection:'row',alignItems:'center',gap:foundation.row.gap},
  guardPreview:{padding:foundation.space.xl,flexDirection:'row',alignItems:'flex-start',gap:foundation.space.lg},
  guardContent:{...foundation.layout.horizontalPart,flexDirection:'row',alignItems:'center',gap:foundation.space.lg},
  vertical:{flexDirection:'column',alignItems:'flex-start'},
  portrait:{width:foundation.control.target+foundation.space.sm,minHeight:foundation.control.target,alignItems:'center',justifyContent:'center'},
  slider:{flex:1,height:foundation.control.target},
  subscription:{alignItems:'center',padding:foundation.space.xl,gap:foundation.space.md},
  price:{alignItems:'flex-end',gap:foundation.space.xs},
  pressed:{opacity:foundation.interaction.pressedOpacity},
  disabled:{opacity:0.45},
});
