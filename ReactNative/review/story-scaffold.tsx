import {Fragment,useState,useEffect,useLayoutEffect,useRef,type PropsWithChildren,type ReactNode,type ComponentRef} from 'react';
import {Animated,AppState,Image,Pressable,ScrollView,StyleSheet,View,useWindowDimensions,type AccessibilityActionEvent,type AccessibilityActionInfo,type LayoutRectangle,type GestureResponderEvent,type ScrollViewInstance} from 'react-native';
import {localized} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {colors,colorForScheme} from '../src/colors.ios';
import {useLavaColorScheme} from '../src/appearance';
import {foundation} from '../src/foundation';
import {Copy, Section, Row, RowContent, RowAccessory, Symbol,usePageInspectionLock} from './primitives';
import {LavaActionButton,LavaCard,LavaIconButton,LavaIconButtonGroup} from '../src';
import {LavaDiscoveryDot} from '../src/LavaDiscoveryDot';
import {CatalogControlMaterial,Group,Quiet,StableVariants,Sheet,Search} from './scaffold';
import {SettingsControl} from './settings-scaffold';
import NativeTextField from '../specs/LavaTextFieldNativeComponent';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {connectionParts,type ConnectionPart,type ConnectionStage} from './connection-model';
import {connectionAttention,connectionAperture,type GlyphCenter} from './connection-reveal';
import {CountLegend,ProportionBar} from './detail-scaffold';
import {GuardMaterial,type GuardMaterialIntent} from './guard-material';
import {useReducedMotionPreference} from './navigation-scaffold';

import {lavaTokens} from '../src/generated/tokens';
const space=foundation.space;
// Connection rails and their selection outline describe the same path; keep
// their stroke equal in both orientations.
const connectionStrokeWidth=1.5;

// Story compositions are a scaffold family, not screen-owned decorations. A
// single surface, text hierarchy, connector axis and target slot serve Guard,
// Settings and Explore while their arrangements differ by available space.
export function StorySurface({children,tone='neutral',testID,footer}:PropsWithChildren<{tone?:'green'|'neutral';testID?:string;footer?:ReactNode}>){
  return <View testID={testID} style={[s.surface,tone==='green'&&s.green]}><StoryInset>{children}</StoryInset>{footer}</View>;
}
// A panel paints its surface; only its illustration/text region is inset. A
// navigation footer remains a sibling and supplies its own canonical row inset.
export function StoryInset({children}:PropsWithChildren){return <View style={s.inset}>{children}</View>;}
// A destination's content keeps its semantic text role; the trailing navigation
// accessory is the same atom as a utility row, with one fixed accessory axis.
// Discovery replaces the chevron in that slot without shifting the heading.
export function StoryNavigationLine({children,testID,attention=false}:PropsWithChildren<{testID?:string;attention?:boolean}>){
  return <View style={s.summaryHeading}><View style={s.flex}>{children}</View><RowAccessory intent="page" testID={testID}>{attention?<LavaDiscoveryDot testID={testID?`${testID}.new`:undefined}/>:undefined}</RowAccessory></View>;
}
export function StoryStack({children}:PropsWithChildren){return <View style={s.stack}>{children}</View>;}
export function StoryColumns({primary,secondary}: {primary:ReactNode;secondary:ReactNode}){
  const scale=useTextScale();
  // Native geometry can resize before RN delivers window dimensions after
  // phone unlock. Keep both lanes mounted and let Yoga wrap on that first pass.
  const column={flexBasis:(foundation.layout.compactThreshold-space.screenHorizontal)*scale};
  return <View testID="story.columns" style={[s.stack,s.columns]}>
    <View testID="story.column.primary" style={[s.stack,s.column,column]}>{primary}</View>
    <View testID="story.column.secondary" style={[s.stack,s.column,column]}>{secondary}</View>
  </View>;
}
// The route owns the green surface. Explanation and controls remain together
// below it in a separate shared neutral group.
export function ExplorePlayground({scene,transport,children,footer}:PropsWithChildren<{scene:ReactNode;transport?:ReactNode;footer?:ReactNode}>){
  return <StoryStack><StorySurface tone="green" testID="explore.diagram.panel">{scene}</StorySurface>
    <Group separators={false} testID="explore.detail.panel"><StoryInset>{children}</StoryInset>{transport}{footer}</Group>
  </StoryStack>;
}
export function ExploreDescriptions({selected,descriptions}:{selected:number;descriptions:readonly {id:string;title:string;caption:string}[]}){
  return <View testID="explore.detail.region"><StableVariants selectedKey={descriptions[selected]?.id??''} variants={descriptions.map((description,index)=>({key:description.id,
    content:<View style={s.stack}><Copy role="section">{description.title}</Copy><Copy testID={selected===index?`explore.demo.caption.${description.id}`:undefined} role="supporting" color={colors.secondaryText}>{description.caption}</Copy></View>,
  }))}/></View>;
}
export function DemoTransport({frame,total,playing,onPrevious,onPlay,onNext}:{frame:number;total:number;playing:boolean;onPrevious:()=>void;onPlay:()=>void;onNext:()=>void}) {
  return <View testID="explore.transport"><SettingsControl>
    <View style={[s.centeredRow,s.flex,{gap:foundation.row.gap}]}>
      <LavaIconButton testID="explore.transport.play" title={playing?'Pause demo':'Resume demo'} icon={playing?'pause':'play'} onPress={onPlay}/>
      <Copy role="row" verbatim>{`${frame+1}/${total}`}</Copy>
    </View>
    <LavaIconButtonGroup>
      <LavaIconButton testID="explore.previous" title="Previous" icon="previous" surface="plain" disabled={frame===0} onPress={onPrevious}/>
      <LavaIconButton testID="explore.next" title="Next" icon="next" surface="plain" onPress={onNext}/>
    </LavaIconButtonGroup>
  </SettingsControl></View>;
}
export function ProtectionHero({ready=false,title,description,mascot,children,action,materialIntent,active,onAccessibilityAction,accessibilityActions}:PropsWithChildren<{
  ready?:boolean;action?:ReactNode;materialIntent?:GuardMaterialIntent;active?:boolean;
  title:string;description:string;mascot:ReactNode;
  onAccessibilityAction:(event:AccessibilityActionEvent)=>void;accessibilityActions:readonly AccessibilityActionInfo[];
}>){
  const scale=useTextScale();
  const [actionFrame,setActionFrame]=useState<LayoutRectangle>();
  const reveal=useRef(new Animated.Value(ready?1:0)).current;
  useEffect(()=>{const animation=Animated.timing(reveal,{toValue:ready?1:0,duration:450,useNativeDriver:true});animation.start();return()=>animation.stop();},[ready,reveal]);
  // Off/Ready share the same intrinsic slots. The canonical off panel reserves
  // both strings, so localization and Dynamic Type cannot shift the handoff.
  const copy=(normal:string,final:string,role:'heading'|'body')=>materialIntent==='rest'||materialIntent===undefined
    ? <View style={{flexDirection:'row',alignItems:'flex-start'}}>{[{text:normal,opacity:reveal.interpolate({inputRange:[0,1],outputRange:[1,0]}),visible:!ready},{text:final,opacity:reveal,visible:ready}].map((item,index)=><Animated.View key={index} pointerEvents="none" accessibilityElementsHidden={!item.visible} importantForAccessibility={item.visible?'auto':'no-hide-descendants'} style={{width:'100%',flexShrink:0,marginLeft:index===0?0:'-100%',opacity:item.opacity}}><Copy role={role} color={role==='body'?colors.secondaryText:colors.primaryText}>{item.text}</Copy></Animated.View>)}</View>
    : <Copy role={role} color={role==='body'?colors.secondaryText:colors.primaryText}>{normal}</Copy>;
  return <GuardMaterial intent={materialIntent} active={active} action={actionFrame}><View style={[s.heroHeading,scale>1.5&&s.heroHeadingStacked]}>
    <View style={scale>1.5?undefined:s.heroText} accessible accessibilityLabel={localized('Protection status')}
      accessibilityValue={{text:`${localized(ready?'Ready':title)}. ${localized(ready?'Your next step to a safer internet.':description)}`}}
      accessibilityActions={accessibilityActions} onAccessibilityAction={onAccessibilityAction}>
      <View style={s.heroCopy}>
        <View style={s.titleStack}><Copy role="supporting" weight="600" color={colors.lavaOrangeText}>Lava Security</Copy>{copy(title,'Ready','heading')}</View>
        <View style={s.description}><View style={s.flex}>{copy(description,'Your next step to a safer internet.','body')}</View></View>
      </View>
    </View><View style={s.mascotSlot}>{mascot}</View>
  </View>{children}{action&&<View onLayout={event=>setActionFrame(event.nativeEvent.layout)}>{action}</View>}</GuardMaterial>;
}
export function GuardSummaries({today,filter,onActivity,onFilters}:{
  today:{value:string;emphasis?:string;allowed?:number;blocked?:number};filter:{name:string;emoji?:string;count?:string};onActivity:()=>void;onFilters:()=>void;
}){
  const {width}=useWindowDimensions();const scale=useTextScale();
  const stacked=width<foundation.layout.compactThreshold||scale>1.25;
  return <View style={[s.summaryPair,stacked&&s.summaryStacked]}>
    <StorySummary stacked={stacked} title="Today" value={today.value} emphasis={today.emphasis} visual={today.allowed!==undefined&&today.blocked!==undefined?<ProportionBar allowed={today.allowed} blocked={today.blocked}/>:undefined} onPress={onActivity} testID="guard.today"/>
    <StorySummary stacked={stacked} title="Now filtering" value={`${filter.emoji??'🌿'} ${filter.name}`} metric={<Copy role="heading" verbatim><FilterEmoji emoji={filter.emoji} context="identity"/>{` ${filter.name}`}</Copy>} verbatim detail={filter.count} onPress={onFilters} testID="guard.filter"/>
  </View>;
}
function StorySummary({title,value,emphasis,detail,visual,metric,onPress,testID,verbatim=false,stacked}:{title:string;value:string;emphasis?:string;detail?:string;visual?:ReactNode;metric?:ReactNode;onPress:()=>void;testID:string;verbatim?:boolean;stacked:boolean}){
  return <Pressable testID={testID} accessibilityRole="button" accessibilityLabel={[localized(title),verbatim?value:localized(value),detail].filter(Boolean).join(', ')}
    onPress={onPress} style={({pressed})=>[s.summary,!stacked&&s.summaryPart,pressed&&s.dim]}>
    <StoryNavigationLine testID={`${testID}.accessory`}><Copy role="caption" color={colors.secondaryText}>{title}</Copy></StoryNavigationLine>
    {metric??<StoryMetric value={verbatim?value:localized(value)} emphasis={emphasis}/>}{(detail||visual)&&<View testID={`${testID}.detail`} style={s.summaryFooter}>{visual??<Copy verbatim role="supporting" color={colors.secondaryText}>{detail}</Copy>}</View>}
  </Pressable>;
}
// Keep localized supporting words in their original order while the measured
// value retains emphasis. All text uses the shared heading ramp at one size.
function StoryMetric({value,emphasis}:{value:string;emphasis?:string}) {
  const start=emphasis?value.indexOf(emphasis):-1;
  if(start<0||!emphasis)return <Copy verbatim role="heading">{value}</Copy>;
  return <Copy verbatim role="heading" weight={foundation.type.supporting.fontWeight}>{value.slice(0,start)}<Copy verbatim role="heading">{emphasis}</Copy>{value.slice(start+emphasis.length)}</Copy>;
}
// A filter is one saved object: its identity, rule total and composition travel
// together. The independent share action never nests inside its navigation hit area.
export function FilterOverview({name,emoji,rules,counts,onOpen,disabled=false}:{
  emoji?:string;name:string;rules?:string;counts:readonly {label:string;value?:number}[];
  onOpen:()=>void;disabled?:boolean;
}){
  return <Pressable testID="row.Now filtering" accessibilityRole="button" accessibilityLabel={[localized('Now filtering'),name,rules,...counts.map(item=>`${localized(item.label)}, ${item.value??'—'}`)].filter(Boolean).join(', ')}
    accessibilityState={{disabled}} disabled={disabled} onPress={onOpen} style={({pressed})=>[s.surface,s.green,s.tileInset,pressed&&s.dim]}>
    <StoryNavigationLine testID="filters.current.accessory"><Copy role="caption" color={colors.secondaryText}>Now filtering</Copy></StoryNavigationLine>
    <View style={s.titleStack}><Copy verbatim role="heading"><FilterEmoji emoji={emoji} context="identity"/>{` ${name}`}</Copy>{rules&&<Copy verbatim role="body" color={colors.secondaryText}>{rules}</Copy>}</View>
    <View style={s.heroCopy}>{counts.map((item,index)=><CountLegend key={item.label} label={item.label} count={item.value} tone={index===0?'blocked':index===1?'personal':'allowed'}/>)}</View>
  </Pressable>;
}
export function FilterEmoji({emoji,context='list'}:{emoji?:string;context?:'list'|'identity'}) {
  return <Copy role={context==='identity'?'identityEmoji':'heading'} verbatim>{emoji??'🌿'}</Copy>;
}
export function FilterIdentity({name,emoji,rules,status,icon,warning=false,inactive=false,onRename}:{name:string;emoji?:string;rules:string;status:string;icon:string;warning?:boolean;inactive?:boolean;onRename?:()=>void}) {
  return <StorySurface><Pressable testID="filter.identity.rename" accessibilityRole={onRename?'button':undefined} accessible={!!onRename} accessibilityLabel={onRename?localized('Rename filter'):undefined} disabled={!onRename} onPress={onRename} style={s.centeredRow}>
    <FilterEmoji emoji={emoji} context="identity"/>
    <View style={s.flex}><Copy testID="filter.identity.name" role="heading" accessibilityRole={onRename?undefined:'header'} verbatim>{name}</Copy></View>
    <View style={s.identityAccessory}>{onRename&&<Symbol name="square.and.pencil" size={foundation.control.glyph} tone="secondary"/>}</View>
    </Pressable>
    <Copy role="body" verbatim color={colors.secondaryText}>{rules}</Copy>
    <View style={s.description}><Symbol name={inactive?'minus.circle.fill':icon} size={foundation.control.glyph} tone={inactive?'secondary':warning?'orange':'green'}/><Copy role="supporting" color={inactive?colors.secondaryText:warning?colors.lavaOrangeText:colors.safeGreen}>{inactive?'Not in effect':status}</Copy></View>
  </StorySurface>;
}
export function ExploreInvitation({onPress,attention=false}: {onPress:()=>void;attention?:boolean}){
  return <Pressable testID="guard.explore" accessibilityRole="button" accessibilityLabel={localized('Explore')}
    accessibilityHint={attention?`${localized('New')}. ${localized('Learn more about how Lava works')}`:localized('Learn more about how Lava works')} onPress={onPress} style={({pressed})=>[s.surface,s.tileInset,s.invitationInset,pressed&&s.dim]}>
    <StoryNavigationLine testID="guard.explore.accessory" attention={attention}><Copy role="caption" color={colors.secondaryText}>Explore</Copy></StoryNavigationLine>
    <View style={s.invitationPath} accessible={false} accessibilityElementsHidden>
      <Symbol name="iphone" size={30} tone="secondary"/><View style={s.invitationLine}/><Symbol name="lava.shield.fill" size={36}/><View style={s.invitationLine}/><Symbol name={connectionParts.dns.symbol} size={30} tone="secondary"/>
    </View>
    <Copy role="supporting" color={colors.secondaryText}>Learn more about how Lava works</Copy>
  </Pressable>;
}
export function ConnectionPanel({stages,onSelect,onExplore}:{stages:readonly ConnectionStage[];onSelect:(stage:ConnectionStage)=>void;onExplore:()=>void}){
  const {width,height}=useWindowDimensions();const scale=useTextScale();const expanded=width/scale>=foundation.layout.wideThreshold;
  const visible=expanded&&width>height?stages:stages.filter(stage=>stage.id!=='phone');
  return <StoryStack><Copy role="section" color={colors.secondaryText}>Your connection</Copy><Group tone="green">
    {visible.map(stage=>{
      const title=stage.id==='dns'?'DNS settings':stage.title;
      const summary=expanded?[stage.value,stage.detail].filter(Boolean).join('\n'):undefined;
      return stage.destination?<Row key={stage.id} testID={`connection.${stage.id}`} intent="page" icon={stage.symbol} title={title} summary={summary} verbatimSummary onPress={()=>onSelect(stage)}/>
        :<View key={stage.id} testID={`connection.${stage.id}`}><RowContent title={title} summary={summary} icon={stage.symbol} intent="task" verbatimSummary/></View>;
    })}
    <StoryLink key="explore" title="Explore this connection" onPress={onExplore}/>
  </Group></StoryStack>;
}

export function ConnectionPath({stages,onSelect,onInspect,expanded=false,selected,details=true,selectablePhone=false,attention,discoveryAttention,conceptual=false}: {
  stages:readonly ConnectionStage[];onSelect:(stage:ConnectionStage)=>void;onInspect?:(stage:ConnectionStage)=>void;expanded?:boolean;selected?:ConnectionPart;details?:boolean;selectablePhone?:boolean;attention?:readonly ConnectionPart[];discoveryAttention?:readonly ConnectionPart[];conceptual?:boolean;
}){
  const scale=useTextScale();const vertical=expanded||scale>1.3;
  const lock=usePageInspectionLock();
  const bounds=useRef<Partial<Record<ConnectionPart,LayoutRectangle>>>({});
  const controls=useRef<Partial<Record<ConnectionPart,LayoutRectangle>>>({});
  const path=useRef<ComponentRef<typeof View>>(null);
  const glyphs=useRef<Partial<Record<ConnectionPart,ComponentRef<typeof View>|null>>>({});
  const [centers,setCenters]=useState<Partial<Record<ConnectionPart,GlyphCenter>>>({});
  const active=connectionAttention(stages,attention);const aperture=connectionAperture(centers,active);
  const measureGlyphs=()=>{const parent=path.current;if(!parent)return;
    for(const stage of stages)glyphs.current[stage.id]?.measureLayout(parent,(x,y,width,height)=>{
      const center={x:x+width/2,y:y+height/2};
      setCenters(previous=>previous[stage.id]?.x===center.x&&previous[stage.id]?.y===center.y?previous:{...previous,[stage.id]:center});
    },()=>{});
  };
  type Tracking={origin:{x:number;y:number};localOrigin:{x:number;y:number};point:{x:number;y:number};dragging:boolean;last?:ConnectionPart};
  const tracking=useRef<Tracking|undefined>(undefined);
  const current=useRef({stages,onSelect,onInspect});current.current={stages,onSelect,onInspect};
  const cancel=()=>{tracking.current=undefined;lock(false);};
  useEffect(()=>{cancel();},[conceptual,vertical]);
  useEffect(()=>{const listener=AppState.addEventListener('change',state=>{if(state!=='active')cancel();});return()=>listener.remove();},[]);
  useEffect(()=>()=>{tracking.current=undefined;},[]);
  const inspect=(session:Tracking)=>{
    const stage=current.current.stages.find(stage=>{
      const rect=bounds.current[stage.id];return rect&&session.point.x>=rect.x&&session.point.x<=rect.x+rect.width&&session.point.y>=rect.y&&session.point.y<=rect.y+rect.height;
    });
    if(stage&&session.dragging&&session.last!==stage.id){session.last=stage.id;(current.current.onInspect??current.current.onSelect)(stage);}
  };
  const begin=(stage:ConnectionStage,event:GestureResponderEvent)=>{
    if(!conceptual)return;
    // The Pressable is the native hit target: its decorative descendants do
    // not receive touches. Seed local layout from that known target, then use
    // only UIKit page-coordinate *deltas*. Never compare UIKit page positions
    // with Fabric global measurements (native header/inset origins may differ).
    const rect=bounds.current[stage.id],control=controls.current[stage.id];
    if(!rect||!control)return;
    const localOrigin={x:rect.x+control.x+event.nativeEvent.locationX,y:rect.y+control.y+event.nativeEvent.locationY};
    tracking.current={origin:{x:event.nativeEvent.pageX,y:event.nativeEvent.pageY},localOrigin,point:localOrigin,dragging:false};
    lock(true);
  };
  const move=(event:GestureResponderEvent)=>{
    const session=tracking.current;if(!session)return;
    const dx=event.nativeEvent.pageX-session.origin.x,dy=event.nativeEvent.pageY-session.origin.y;
    session.point={x:session.localOrigin.x+dx,y:session.localOrigin.y+dy};
    session.dragging ||= Math.hypot(dx,dy)>=foundation.space.sm;
    if(session.dragging)inspect(session);
  };
  const finish=(event:GestureResponderEvent)=>{
    if(tracking.current?.dragging)move(event);
    cancel();
  };
  // Taps stay with Pressability. A drag transfers responder ownership, which
  // terminates the child's pending press and prevents a second release tap.
  const gestures={
    onStartShouldSetResponderCapture:()=>false,
    onMoveShouldSetResponderCapture:(event:GestureResponderEvent)=>{
      if(!conceptual||!tracking.current)return false;
      move(event);return !!tracking.current?.dragging;
    },
    onTouchEnd:finish,onTouchCancel:cancel,
    onResponderGrant:move,onResponderMove:move,onResponderRelease:finish,
    onResponderTerminate:cancel,onResponderTerminationRequest:()=>false,
  };
  const stageLayout=(stage:ConnectionStage,rect:LayoutRectangle)=>{
    const previous=bounds.current[stage.id];
    if(previous&&(previous.x!==rect.x||previous.y!==rect.y||previous.width!==rect.width||previous.height!==rect.height))cancel();
    bounds.current[stage.id]=rect;measureGlyphs();
  };
  const step=(stage:ConnectionStage)=>{
    const focus=conceptual&&!!attention&&stage.id===active;
    // A caption can describe several parts of the route, but only its focus
    // gets selected styling. Every other part stays subdued.
    const dimmed=conceptual&&!!attention&&stage.id!==active;
    return <ConnectionStep stage={stage} expanded={vertical} details={details} conceptual={conceptual} focus={focus}
      discoveryAttention={discoveryAttention?.includes(stage.id)}
      interactive={stage.id!=='phone'||selectablePhone} onPress={()=>onSelect(stage)}
      onTouchStart={conceptual?event=>begin(stage,event):undefined} onControlLayout={rect=>{controls.current[stage.id]=rect;}} selected={!attention&&selected===stage.id}
      dimmed={dimmed}
      glyphRef={node=>{glyphs.current[stage.id]=node;}} onGlyphLayout={measureGlyphs}
      reveal={attention?{enabled:true,x:aperture&&centers[stage.id]?aperture.x-centers[stage.id]!.x+13:13,
        y:aperture&&centers[stage.id]?aperture.y-centers[stage.id]!.y+13:13,radius:aperture?.radius??22,
        visible:focus||(!stage.muted&&!!aperture)}:undefined}/>;
  };
  if(vertical)return <View ref={path} onLayout={measureGlyphs} {...gestures} testID="connection.path.vertical" style={s.pathVertical}>{stages.map((stage,index)=><View onLayout={event=>stageLayout(stage,event.nativeEvent.layout)} collapsable={false} key={stage.id} testID={`connection.stage.${stage.id}`} style={s.pathStep}>
    <View pointerEvents="none" style={s.pathRail}>{index>0&&<View style={s.lineAbove}/>}<View style={s.lineBelow}/>{index===stages.length-1&&<View style={s.lastLineCover}/>}</View>{step(stage)}
  </View>)}</View>;
  return <View ref={path} onLayout={measureGlyphs} {...gestures} testID="connection.path.horizontal" style={s.pathHorizontal}>{stages.map((stage,index)=><Fragment key={stage.id}>
    {index>0&&<View style={s.horizontalLine}/>}<View onLayout={event=>stageLayout(stage,event.nativeEvent.layout)} collapsable={false} testID={`connection.stage.${stage.id}`} style={s.compactStep}>{step(stage)}</View>
  </Fragment>)}</View>;
}
export function ConnectionScene(props:Omit<Parameters<typeof ConnectionPath>[0],'expanded'|'details'|'conceptual'>){
  return <ConnectionPath {...props} expanded={false} details={false} selectablePhone conceptual/>;
}
function ConnectionStep({stage,expanded=false,onPress,onTouchStart,selected,focus=false,dimmed=false,details=true,interactive=true,conceptual=false,onControlLayout,onGlyphLayout,glyphRef,reveal,discoveryAttention=false}:{stage:ConnectionStage;expanded?:boolean;onPress:()=>void;onTouchStart?:(event:GestureResponderEvent)=>void;selected?:boolean;focus?:boolean;dimmed?:boolean;details?:boolean;interactive?:boolean;conceptual?:boolean;onControlLayout?:(layout:LayoutRectangle)=>void;onGlyphLayout?:(layout:LayoutRectangle)=>void;glyphRef?:(node:ComponentRef<typeof View>|null)=>void;reveal?:{enabled:boolean;x:number;y:number;radius:number;visible:boolean};discoveryAttention?:boolean}){
  const selectionColor=colorForScheme('navigationForeground',useLavaColorScheme());
  const shortTitle=conceptual&&stage.id==='vpn'?'VPN':stage.shortTitle;
  const subdued=dimmed||(stage.muted&&!focus);
  const content=<><View ref={glyphRef} collapsable={false} testID={`connection.glyph.${stage.id}`} onLayout={onGlyphLayout?event=>onGlyphLayout(event.nativeEvent.layout):undefined} style={s.node}>
    <Decoration symbol={stage.symbol} fontWeight="regular" tone={subdued?'secondary':'green'} revealEnabled={!!reveal} revealVisible={reveal?.visible??true}
      revealX={reveal?.x??13} revealY={reveal?.y??13} revealRadius={reveal?.radius??22} style={{width:26,height:26}} accessible={false} accessibilityElementsHidden/>
    {discoveryAttention&&<View pointerEvents="none" testID={`connection.${stage.id}.discovery-dot`} style={s.nodeDiscovery}><LavaDiscoveryDot/></View>}
    </View>
    {expanded&&!conceptual?<View style={s.nodeDetails}><Copy role="caption" color={colors.secondaryText}>{stage.title}</Copy><Copy verbatim role="section">{stage.value}</Copy>{details&&stage.detail&&<Copy verbatim role="supporting" color={colors.secondaryText}>{stage.detail}</Copy>}</View>:<Copy role="caption" center={!expanded} color={subdued?colors.secondaryText:colors.primaryText}>{shortTitle}</Copy>}
    {expanded&&!conceptual&&stage.destination&&<RowAccessory intent="page"/>}</>;
  // In Settings Phone is orientation, while Explore makes each part selectable.
  const label=conceptual?localized(shortTitle):`${localized(stage.title)}, ${stage.value}`;
  if(!interactive)return <View testID={`connection.${stage.id}`} accessible accessibilityRole="text" accessibilityLabel={label} onLayout={onControlLayout?event=>onControlLayout(event.nativeEvent.layout):undefined} style={[expanded?s.expandedNode:s.compactNode,dimmed&&s.dimmed]}>{content}</View>;
  return <Pressable testID={`connection.${stage.id}`} accessibilityRole="button" accessibilityLabel={label} accessibilityHint={discoveryAttention?localized('New'):undefined}
    accessibilityState={{selected:!!selected||focus}} onTouchStart={onTouchStart} onLayout={onControlLayout?event=>onControlLayout(event.nativeEvent.layout):undefined} onPress={onPress} style={({pressed})=>[expanded?s.expandedNode:s.compactNode,selected&&{borderColor:selectionColor},dimmed&&s.dimmed,pressed&&s.dim]}><View pointerEvents="none" style={{display:'contents'}}>{content}</View></Pressable>;
}
export function StoryLink({title,onPress,testID,attention=false}:{title:string;onPress:()=>void;testID?:string;attention?:boolean}){
  return <Row title={title} intent="page" onPress={onPress} testID={testID} attention={attention}/>;
}
export function CategoryLinks({titles,onSelect}:{titles:readonly string[];onSelect:(title:string)=>void}){
  return <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{minHeight:foundation.control.target}} contentContainerStyle={s.categoryLinks}>{titles.map(title=><Pressable key={title} accessibilityRole="button" accessibilityLabel={localized(title)} onPress={()=>onSelect(title)} style={({pressed})=>[s.category,pressed&&s.dim]}><CatalogControlMaterial/><Copy role="supporting" weight="600">{title}</Copy></Pressable>)}</ScrollView>;
}
// Blocklist and DNS catalogs share the same sheet, category navigation, search,
// section positioning and confirmation footer. Callers supply rows and selection semantics.
export function CatalogSheet<T>({sections,categoryTitles=sections.map(section=>section.title),search,onSearch,searchLabel,renderRow,footer,empty}: {
  sections:{title:string;items:T[]}[];categoryTitles?:readonly string[];search:string;onSearch:(value:string)=>void;searchLabel:string;
  renderRow:(item:T,section:string)=>ReactNode;footer?:ReactNode;empty?:ReactNode;
}) {
  const scroll=useRef<ScrollViewInstance>(null);const positions=useRef<Record<string,number>>({});
  const previousSearch=useRef(search);
  useLayoutEffect(()=>{
    if(previousSearch.current===search)return;
    previousSearch.current=search;
    // New results begin below the pinned controls, including the empty state.
    // Ordinary selection updates and returning from a child retain their offset.
    scroll.current?.scrollTo({y:0,animated:false});
  },[search]);
  return <Sheet scrollMode="list" scrollRef={scroll} headerMaterial={false} header={<View testID="catalog.controls" style={{gap:12}}>
    <CategoryLinks titles={categoryTitles} onSelect={title=>{if(sections.some(section=>section.title===title))scroll.current?.scrollTo({y:positions.current[title]??0,animated:true});}}/>
    <Search surface="catalog" value={search} onChange={onSearch} label={searchLabel}/>
  </View>} footer={footer}>
    {sections.map(section=><View key={section.title} onLayout={event=>{positions.current[section.title]=event.nativeEvent.layout.y;}}>
      <Section title={section.title}><Group plain>{section.items.map(item=>renderRow(item,section.title))}</Group></Section>
    </View>)}
    {!sections.length&&empty}
  </Sheet>;
}

export function BudgetBar({fraction,indeterminate,warning,available=true}:{fraction:number;indeterminate:boolean;warning?:boolean;available?:boolean}){
  const reduced=useReducedMotionPreference();
  const fill=useRef(new Animated.Value(available&&!indeterminate?Math.max(0,Math.min(1,fraction)):0)).current;
  useEffect(()=>{
    // A current foreground recalculation keeps the last accepted paint. Losing
    // the authorized query clears it immediately; this is no reusable data cache.
    if(!available){fill.stopAnimation();fill.setValue(0);return;}
    if(indeterminate)return;
    const target=Math.max(0,Math.min(1,fraction));
    if(reduced){fill.stopAnimation();fill.setValue(target);return;}
    const animation=Animated.timing(fill,{toValue:target,duration:250,useNativeDriver:true});
    animation.start();return()=>animation.stop();
  },[fraction,indeterminate,available,reduced,fill]);
  return <View accessible accessibilityRole="progressbar" accessibilityLabel={localized('Filter rule budget')} accessibilityValue={indeterminate?{text:localized('calculating')}:{min:0,max:100,now:Math.round(fraction*100)}} style={s.budgetTrack}>
    <Animated.View testID="budget.fill" style={[s.budgetFill,warning&&s.budgetWarning,{width:'100%',transformOrigin:'left center',transform:[{scaleX:fill}]}]}/>
  </View>;
}
export function PrivateQRCode({image,revealed,onReveal,available,loadingMessage}:{image?:string|null;revealed:boolean;onReveal:()=>void;available:boolean;loadingMessage:string}){
  const [privacyHeight,setPrivacyHeight]=useState(0);
  return <LavaCard testID="share-qr-card" background={image&&!revealed?<Image source={{uri:image}} blurRadius={24} resizeMode="cover" style={s.qrBackground}/>:undefined}>
    <View testID="share-qr-region" style={[s.qrRegion,{minHeight:Math.max(272,privacyHeight)}]}>
      {image?<>
        <View pointerEvents="none" accessibilityElementsHidden={!revealed} importantForAccessibility={revealed?'auto':'no-hide-descendants'} style={[s.qrContent,!revealed&&s.hidden]}>
          <View style={s.qrFrame}>{revealed&&<Image source={{uri:image}} accessible accessibilityLabel={localized('Filter QR code')} style={s.qrImage}/>}</View>
          <Copy role="caption" center color={colors.secondaryText}>Point another phone's camera here to import.</Copy>
        </View>
        <View pointerEvents={revealed?'none':'auto'} accessibilityElementsHidden={revealed} importantForAccessibility={revealed?'no-hide-descendants':'auto'} style={[s.qrCover,revealed&&s.hidden]}>
          <View onLayout={event=>setPrivacyHeight(event.nativeEvent.layout.height)} style={s.qrPrivacy}>
            <Symbol name="eye.slash.fill" size={foundation.control.glyphSlot} tone="primary"/>
            <View style={s.stretch}><LavaActionButton title="Show the QR Code" role="panel" onPress={onReveal}/></View>
          </View>
        </View>
      </>:available?<><Symbol name="qrcode" size={foundation.control.glyphSlot} tone="secondary"/><Copy role="section" center>This setup is too large for a QR code</Copy><Quiet>Share the setup code below instead.</Quiet></>:<Quiet>{loadingMessage}</Quiet>}
    </View>
  </LavaCard>;
}
export function SetupCodeField({onChange}:{onChange:(code:string)=>void}){
  return <NativeTextField inputLabel={localized('Setup code')} placeholder="LF1-…" kind="multiline" resetRevision={0} onChange={event=>onChange(event.nativeEvent.text)} style={s.setupCode}/>;
}

const s=StyleSheet.create({
  centeredRow:{flexDirection:'row',alignItems:'center',gap:space.sm},identityAccessory:{width:foundation.control.glyph,minHeight:foundation.control.glyph},
  stack:{gap:foundation.story.gap},flex:{flex:1,minWidth:0},columns:{flexDirection:'row',flexWrap:'wrap',alignItems:'flex-start',columnGap:space.lg*2},column:foundation.layout.horizontalPart,
  surface:{borderRadius:foundation.radius.surface,borderCurve:'continuous',backgroundColor:colors.cardBackground},
  inset:{padding:space.lg+space.xs,gap:space.lg},
  tileInset:{padding:foundation.story.tileInset,gap:foundation.story.gap},
  green:{backgroundColor:colors.softGreen},dim:{opacity:foundation.interaction.pressedOpacity},dimmed:{opacity:foundation.interaction.dimmedOpacity},
  // Copy and artwork begin together. Content determines the height; this hero
  // does not reserve another full-width description band or a tallest-state box.
  heroHeading:{flexDirection:'row',alignItems:'flex-start',gap:space.md},heroHeadingStacked:{flexDirection:'column-reverse',alignItems:'flex-start'},
  heroCopy:{gap:space.sm},
  heroText:foundation.layout.horizontalPart,
  titleStack:{gap:space.xs},mascotSlot:{width:lavaTokens.guard.mascotSize,height:lavaTokens.guard.mascotSlotHeight,alignItems:'center',justifyContent:'center'},
  description:{flexDirection:'row',alignItems:'flex-start',gap:space.sm},
  filterOverview:{gap:space.lg},filterCounts:{flexDirection:'row',gap:space.lg},filterCountsStacked:{flexDirection:'column'},
  summaryPair:{flexDirection:'row',gap:foundation.story.gap},summaryStacked:{flexDirection:'column'},
  summaryPart:foundation.layout.horizontalPart,
  summary:{minHeight:foundation.story.summaryMinHeight,padding:foundation.story.tileInset,gap:space.sm,backgroundColor:colors.softGreen,borderRadius:foundation.radius.surface,borderCurve:'continuous'},
  // Metadata belongs to the bottom edge, even when the adjacent summary or
  // a wrapping filter name makes the shared row taller. No text height is fixed.
  summaryFooter:{marginTop:'auto'},
  summaryHeading:{flexDirection:'row',alignItems:'flex-start',gap:space.sm},
  invitationInset:{gap:space.sm},
  nodeDiscovery:{position:'absolute',top:2,right:2},
  invitationPath:{alignSelf:'center',width:'100%',maxWidth:320,paddingHorizontal:space.lg,flexDirection:'row',alignItems:'center',gap:space.md,minHeight:40},invitationLine:{flex:1,height:1,backgroundColor:colors.safeGreen,opacity:0.35},
  pathHorizontal:{flexDirection:'row',alignItems:'flex-start'},compactStep:{flex:1,minWidth:44},compactNode:{minHeight:80,gap:space.xs,alignItems:'center',paddingVertical:space.xs,paddingHorizontal:space.xs,borderWidth:connectionStrokeWidth,borderColor:'transparent',borderRadius:foundation.radius.control},
  horizontalLine:{height:connectionStrokeWidth,backgroundColor:colors.safeGreen,flex:0.25,marginTop:28},
  node:{width:44,height:44,borderRadius:22,alignItems:'center',justifyContent:'center'},
  pathVertical:{gap:0},pathStep:{position:'relative'},pathRail:{position:'absolute',left:22,top:0,bottom:0,width:connectionStrokeWidth},lineAbove:{position:'absolute',top:0,height:12,width:connectionStrokeWidth,backgroundColor:colors.safeGreen},lineBelow:{position:'absolute',top:52,bottom:0,width:connectionStrokeWidth,backgroundColor:colors.safeGreen},lastLineCover:{position:'absolute',top:44,bottom:0,width:connectionStrokeWidth,backgroundColor:colors.softGreen},
  expandedNode:{borderWidth:connectionStrokeWidth,borderColor:'transparent',borderRadius:foundation.radius.control,flexDirection:'row',alignItems:'center',gap:space.md,paddingVertical:space.sm,minHeight:88},nodeDetails:{flex:1,minWidth:0,gap:space.xs,paddingBottom:space.md},
  categoryLinks:{gap:space.sm},category:{minHeight:foundation.control.target,paddingHorizontal:space.md,paddingVertical:space.sm,justifyContent:'center',borderRadius:foundation.radius.circle,overflow:'hidden'},
  budgetTrack:{height:6,borderRadius:foundation.radius.circle,overflow:'hidden',backgroundColor:colors.disabledSurface},budgetFill:{height:6,backgroundColor:colors.safeGreen},budgetWarning:{backgroundColor:colors.lavaOrange},
  qrBackground:{position:'absolute',top:0,bottom:0,left:0,right:0,opacity:0.25},qrRegion:{alignItems:'center',justifyContent:'center'},qrContent:{alignItems:'center',gap:space.md},
  // A QR needs a white quiet zone for reliable scanning in either appearance.
  qrFrame:{width:240,height:240,padding:10,borderRadius:foundation.radius.compact,backgroundColor:'white'},qrImage:{width:220,height:220},
  qrCover:{position:'absolute',left:0,right:0,alignItems:'center'},qrPrivacy:{alignSelf:'stretch',alignItems:'center',gap:space.md,paddingVertical:space.md},hidden:{opacity:0},stretch:{alignSelf:'stretch'},
  setupCode:{height:180,backgroundColor:colors.cardBackground,borderRadius:foundation.radius.control},
});
