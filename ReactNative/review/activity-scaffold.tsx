import {useCallback,useContext,useEffect,useRef,useState} from 'react';
import {Pressable,StyleSheet,View} from 'react-native';
import {localized,localizedFormat,localizedNumber,PresentationContext} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {colors,colorForScheme} from '../src/colors.ios';
import {useLavaColorScheme} from '../src/appearance';
import {foundation} from '../src/foundation';
import {useFeedback} from '../src/feedback';
import {Copy,Symbol,MetricValue,usePageInspectionLock,usePageInspectionReset} from './primitives';
import {CountLegend,ActivityFlowBar} from './detail-scaffold';
import {StableVariants} from './scaffold';
import {activityRate,activityLegendValue,activityOutcomeAt,activityInspectionFeedback,type ActivityBucket,type ActivityOutcome} from './activity-model';

const chartTitles=['Total requests','Requests by time','Blocked rate by time'] as const;
const lineWidth=3;
const pointDiameter=5;
// The whole chart frame and its caption stay fixed. Every visual ends on the same
// baseline; a small shared top inset gives the title more breathing room.
function chartFrame(scale:number){
  const height=120*scale;
  const captionHeight=Math.ceil(foundation.type.caption.fontSize*1.4*scale)+foundation.space.sm;
  const top=foundation.space.sm*scale;
  return {height,captionHeight,top,drawable:Math.max(height/2,height-captionHeight-top)};
}
export function ActivityCharts({buckets,rangeKey,allowed,blocked,loaded,pending=false,uptime,onInspect}:{buckets:readonly ActivityBucket[];rangeKey:string;allowed:number;blocked:number;loaded:boolean;pending?:boolean;uptime:string;onInspect?:(availability:'populated'|'empty')=>void}) {
  const feedback=useFeedback();
  const {locale}=useContext(PresentationContext);
  const [page,setPage]=useState(0);const [selected,setSelected]=useState<number|ActivityOutcome>();
  const selection=useRef<number|ActivityOutcome|undefined>(undefined);
  const clear=useCallback(()=>{selection.current=undefined;setSelected(undefined);},[]);
  useEffect(clear,[rangeKey,pending,clear]);usePageInspectionReset(clear);
  const inspect=(target:number|ActivityOutcome)=>{
    if(pending||selection.current===target)return;
    selection.current=target;setSelected(target);
    feedback.emit({semantic:typeof target==='number'&&activityInspectionFeedback(buckets[target]!)==='empty'?'inspectionEmpty':'selected',controlID:'activity.inspection',value:`${rangeKey}:${target}`});
    onInspect?.(typeof target==='number'?activityInspectionFeedback(buckets[target]!):'populated');
  };
  const bucket=typeof selected==='number'?buckets[selected]:undefined;
  const displayed=bucket??{allowed,blocked,available:loaded};
  const total=displayed.allowed+displayed.blocked;
  const value=(count:number)=>activityLegendValue(count,total,displayed.available,locale);
  const frame=chartFrame(useTextScale());
  return <View testID="activity.charts" style={s.stack}>
    <Pressable testID="activity.chart.next" accessibilityRole="button" accessibilityLabel={localized(chartTitles[page]!)} accessibilityHint={localized('Show next chart')}
      onPress={()=>{clear();setPage(current=>(current+1)%chartTitles.length);}} style={({pressed})=>[s.titlePill,pressed&&s.pressed]}>
      <View style={{flexShrink:1}}><StableVariants selectedKey={chartTitles[page]!} variants={chartTitles.map(title=>({key:title,content:<Copy role="row">{title}</Copy>}))}/></View><Symbol name="arrow.triangle.2.circlepath" size={16} tone="secondary"/>
    </Pressable>
    {page===0?<TotalChart allowed={allowed} blocked={blocked} loaded={loaded} pending={pending} uptime={uptime} frame={frame} selected={typeof selected==='string'?selected:undefined} onSelect={inspect}/>
      :<TimeChart kind={page===1?'counts':'rate'} title={chartTitles[page]!} pending={pending} frame={frame} buckets={buckets} selected={typeof selected==='number'?selected:undefined} onSelect={inspect}/>}
    <CountLegend label="Allowed" count={displayed.available?displayed.allowed:undefined} value={value(displayed.allowed)} tone="allowed" dimmed={selected==='blocked'}/>
    <CountLegend label="Blocked" count={displayed.available?displayed.blocked:undefined} value={value(displayed.blocked)} tone="blocked" dimmed={selected==='allowed'}/>
  </View>;
}
function TotalChart({allowed,blocked,loaded,pending,uptime,frame,selected,onSelect}:{allowed:number;blocked:number;loaded:boolean;pending:boolean;uptime:string;frame:ReturnType<typeof chartFrame>;selected?:ActivityOutcome;onSelect:(outcome:ActivityOutcome)=>void}){
  const lockPage=usePageInspectionLock();const [width,setWidth]=useState(0);
  const pick=(x:number)=>{const outcome=loaded?activityOutcomeAt(x,width,allowed,blocked):undefined;if(outcome)onSelect(outcome);};
  const options:ActivityOutcome[]=[...(loaded&&blocked>0?['blocked' as const]:[]),...(loaded&&allowed>0?['allowed' as const]:[])];
  return <View testID="activity.plot.total" style={{height:frame.height}}>
    <View testID="activity.total.content" style={{height:frame.top+frame.drawable}}>
      <View testID="activity.total.value" style={s.totalValue}><MetricValue value={loaded?localizedNumber(allowed+blocked):'—'}/></View>
      <View testID="activity.total.inspect" onLayout={event=>setWidth(event.nativeEvent.layout.width)} accessible accessibilityRole="adjustable" accessibilityLabel={localized('Total requests')}
        accessibilityState={{busy:pending}} accessibilityValue={{text:pending?localized('Loading Activity…'):selected?`${localized(selected==='allowed'?'Allowed':'Blocked')}, ${localizedNumber(selected==='allowed'?allowed:blocked)}`:loaded?localizedNumber(allowed+blocked):localized('No data')}}
        accessibilityActions={pending?[]:[{name:'increment',label:localized('Next')},{name:'decrement',label:localized('Previous')}]}
        onAccessibilityAction={event=>{const index=selected?options.indexOf(selected):-1;const next=options[Math.max(0,Math.min(options.length-1,index+(event.nativeEvent.actionName==='increment'?1:-1)))];if(next)onSelect(next);}}
        hitSlop={{top:(foundation.control.target-14)/2,bottom:(foundation.control.target-14)/2}}
        onTouchStart={event=>event.stopPropagation()} onStartShouldSetResponder={()=>!pending}
        onResponderGrant={event=>{if(!pending){lockPage(true);pick(event.nativeEvent.locationX);}}} onResponderMove={event=>pick(event.nativeEvent.locationX)}
        onResponderRelease={()=>lockPage(false)} onResponderTerminate={()=>lockPage(false)} onResponderTerminationRequest={()=>false}>
        <View pointerEvents="none"><ActivityFlowBar allowed={allowed} blocked={blocked}/></View>
      </View>
    </View>
    <View testID="activity.caption" style={s.axis}><Copy testID="activity.caption.text" role="caption" numberOfLines={1} color={colors.secondaryText} verbatim>{pending?localized('Loading Activity…'):loaded?localizedFormat('%@ protected locally',uptime):'—'}</Copy></View>
  </View>;
}
function TimeChart({kind,title,pending,frame,buckets,selected,onSelect}:{kind:'counts'|'rate';title:string;pending:boolean;frame:ReturnType<typeof chartFrame>;buckets:readonly ActivityBucket[];selected?:number;onSelect:(index:number)=>void}) {
  const lockPage=usePageInspectionLock();const [width,setWidth]=useState(0);
  const selectionColor=colorForScheme('primaryText',useLavaColorScheme());
  const max=Math.max(1,...buckets.filter(bucket=>bucket.available).map(bucket=>bucket.allowed+bucket.blocked));
  const slot=width/Math.max(1,buckets.length);
  const pick=(x:number)=>{if(width&&buckets.length)onSelect(Math.min(buckets.length-1,Math.max(0,Math.floor(x/slot))));};
  const bucket=selected===undefined?undefined:buckets[selected];
  const detail=pending?localized('Loading Activity…'):!bucket?localized('Drag to inspect'):!bucket.available?localized('No data'):
    `${bucket.label}, ${kind==='counts'?`${localizedNumber(bucket.allowed)} ${localized('Allowed')}, ${localizedNumber(bucket.blocked)} ${localized('Blocked')}`:activityRate(bucket)===undefined?localized('No requests'):localizedFormat('%@%% blocked',localizedNumber(activityRate(bucket)!))}`;
  const yFor=(rate:number)=>frame.top+pointDiameter/2+(frame.drawable-pointDiameter)*(1-rate/100);
  return <View testID={`activity.plot.${kind}`} accessible accessibilityRole="adjustable" accessibilityLabel={localized(title)} accessibilityState={{busy:pending}} accessibilityValue={{text:detail}}
    accessibilityActions={pending?[]:[{name:'increment',label:localized('Next')},{name:'decrement',label:localized('Previous')}]}
    onAccessibilityAction={event=>{if(buckets.length)onSelect(Math.max(0,Math.min(buckets.length-1,(selected??-1)+(event.nativeEvent.actionName==='increment'?1:-1))));}}
    onTouchStart={event=>event.stopPropagation()} onStartShouldSetResponder={()=>!pending} onResponderGrant={event=>{if(!pending){lockPage(true);pick(event.nativeEvent.locationX);}}} onResponderRelease={()=>lockPage(false)} onResponderTerminate={()=>lockPage(false)} onResponderMove={event=>pick(event.nativeEvent.locationX)}
    onResponderTerminationRequest={()=>false} onLayout={event=>setWidth(event.nativeEvent.layout.width)} style={{height:frame.height}}>
    {kind==='counts'?<View pointerEvents="none" style={[s.bars,{marginTop:frame.top,height:frame.drawable}]}>{buckets.map((item,index)=><View testID={`activity.bucket.${index}`} key={item.start} style={[s.barSlot,{width:slot}]}>
      {item.available&&<><View testID={`activity.bucket.${index}.blocked`} style={[s.blocked,{height:frame.drawable*item.blocked/max}]}/><View testID={`activity.bucket.${index}.allowed`} style={[s.allowed,{height:frame.drawable*item.allowed/max}]}/></>}
      {selected===index&&item.available&&item.allowed+item.blocked>0&&<View testID={`activity.bucket.${index}.selection`} style={[s.selection,{height:frame.drawable*(item.allowed+item.blocked)/max,borderColor:selectionColor}]}/>}</View>)}</View>:
      <View testID="activity.rate.marks" pointerEvents="none" style={StyleSheet.absoluteFill}>
        {/* Paint all connections below every marker so an outgoing line cannot cover its selection border. */}
        <View testID="activity.rate.lines" style={StyleSheet.absoluteFill}>{buckets.map((item,index)=>{
        const rate=activityRate(item);if(rate===undefined)return null;
        const x=slot*(index+0.5);const y=yFor(rate);
        const previous=index>0?activityRate(buckets[index-1]!):undefined;
        if(previous===undefined)return null;
        const dy=y-yFor(previous);
        return <View key={item.start} testID={`activity.line.${index}`} style={[s.line,{left:x-slot,top:y-dy-lineWidth/2,width:Math.hypot(slot,dy),transformOrigin:'left center',transform:[{rotate:`${Math.atan2(dy,slot)}rad`}]}]}/>;
      })}</View>
        <View testID="activity.rate.points" style={StyleSheet.absoluteFill}>{buckets.map((item,index)=>{
          const rate=activityRate(item);if(rate===undefined)return null;
          return <View key={item.start} testID={`activity.point.${index}`} style={[s.point,{left:slot*(index+0.5)-pointDiameter/2,top:yFor(rate)-pointDiameter/2},selected===index&&[s.selectedPoint,{borderColor:selectionColor,backgroundColor:selectionColor}]]}/>;
        })}</View>
      </View>}
    <View testID="activity.baseline" pointerEvents="none" style={[s.baseline,{bottom:frame.captionHeight}]}/>
    <View testID="activity.caption" pointerEvents="none" style={s.axis}>
      <View style={{flex:1}}><Copy testID="activity.caption.text" role="caption" numberOfLines={1} color={colors.secondaryText} verbatim>{pending?localized('Loading Activity…'):bucket?bucket.label:localized('Drag to inspect')}</Copy></View>
      {!pending&&bucket&&(!bucket.available||!bucket.allowed&&!bucket.blocked)&&<Copy role="caption" color={colors.secondaryText}>{bucket.available?'No requests':'No data'}</Copy>}
    </View>
  </View>;
}
const s=StyleSheet.create({
  stack:{gap:foundation.space.md},titlePill:{alignSelf:'flex-start',maxWidth:'100%',minHeight:foundation.control.target,paddingHorizontal:foundation.space.md,flexDirection:'row',alignItems:'center',gap:foundation.space.sm,borderRadius:foundation.radius.circle,borderWidth:1,borderColor:colors.secondaryText},pressed:{opacity:foundation.interaction.pressedOpacity},
  totalValue:{flex:1,marginTop:-foundation.space.md,alignItems:'center',justifyContent:'center'},bars:{flexDirection:'row',alignItems:'flex-end'},
  // Inspection keeps the full plot target; its outline follows only the painted stack.
  barSlot:{paddingHorizontal:1,justifyContent:'flex-end',height:'100%'},blocked:{backgroundColor:colors.lavaOrange},allowed:{backgroundColor:colors.safeGreen},selection:{position:'absolute',left:1,right:1,bottom:0,borderWidth:1},
  axis:{position:'absolute',left:0,right:0,bottom:0,flexDirection:'row',gap:foundation.space.sm,justifyContent:'space-between'},baseline:{position:'absolute',left:0,right:0,height:StyleSheet.hairlineWidth,backgroundColor:colors.secondaryText},line:{position:'absolute',height:lineWidth,backgroundColor:colors.lavaOrange},
  point:{position:'absolute',width:pointDiameter,height:pointDiameter,borderRadius:foundation.radius.circle,backgroundColor:colors.lavaOrange},selectedPoint:{borderWidth:1,zIndex:1},
});
