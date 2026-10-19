import {useContext,useEffect,useState} from 'react';
import {PixelRatio,Text,View} from 'react-native';
import Svg,{Circle,Line,Polyline,Rect,Text as SvgText} from 'react-native-svg';
import {localized,localizedFormat,localizedNumber,PresentationContext} from '../app/presentation';
import Decoration from '../specs/LavaDecorationNativeComponent';
import Surface from '../specs/LavaShareCardSurfaceNativeComponent';
import QR from '../specs/LavaShareQrNativeComponent';
import type {ActivitySummary} from './activity-model';

export type ActivityChartKind='total'|'counts'|'rate';
export type ActivityShareCardContent=ActivitySummary&{
  token:string;payload:string;moduleCount:number;chart:ActivityChartKind;
  period:'today'|'week'|'month'|'custom';dateLabel:string;startLabel:string;endLabel:string;
};

// One 4:5 export composition. Text, chart and QR slots do not depend on data,
// device width, accessibility text size, or the number of wrapped date labels.
export const activityCardFrame={
  header:{x:28.08,y:29.056,width:375.84,height:69.12},
  chart:{x:28.08,y:115.888,width:375.84,height:277.984},
  footer:{x:28.08,y:411.584,width:375.84,height:90.72},
} as const;
const orange='#F2572E',ink='#14120F',secondary='#6B635C',green='#79A991',grid='#D7DFD8';
const plot={width:337.824,height:172.23};
const chartTitles={total:'Total requests',counts:'Requests by time',rate:'Blocked rate by time'} as const;
const summaryFormats={
  one:{today:'Lava helped block %@ request today.',week:'Lava helped block %@ request in the last 7 days.',month:'Lava helped block %@ request this month.',custom:'Lava helped block %@ request between %@ and %@.'},
  other:{today:'Lava helped block %@ requests today.',week:'Lava helped block %@ requests in the last 7 days.',month:'Lava helped block %@ requests this month.',custom:'Lava helped block %@ requests between %@ and %@.'},
} as const;
const compact=(value:number,locale:string)=>new Intl.NumberFormat(locale.replace(/_/g,'-'),{notation:'compact',maximumFractionDigits:2}).format(value);
const ceilingFor=(value:number)=>{
  const power=10**Math.floor(Math.log10(Math.max(1,value)));
  return [1,2,5,10].map(step=>step*power).find(candidate=>candidate>=value)??power*10;
};

function Chart({content,u}:{content:ActivityShareCardContent;u:number}) {
  const {locale}=useContext(PresentationContext);
  const {width:w,height:h}=plot;
  const buckets=content.buckets??[];
  const label=(x:number,y:number,value:string,anchor:'start'|'middle'|'end'='start',size=11,color=secondary)=><SvgText key={`${x}:${y}`} x={x} y={y} fill={color} fontSize={size} fontFamily="Arial" textAnchor={anchor}>{value}</SvgText>;
  const left=40,right=2,top=12,bottom=22,pw=w-left-right,ph=h-top-bottom;
  const rates=buckets.map(b=>b.available&&b.allowed+b.blocked>0?100*b.blocked/(b.allowed+b.blocked):undefined);
  const ceiling=content.chart==='rate'?Math.max(10,Math.ceil(Math.max(0,...rates.map(r=>r??0))/10)*10):ceilingFor(Math.max(1,...buckets.filter(b=>b.available).map(b=>b.allowed+b.blocked)));
  const slot=pw/Math.max(1,buckets.length);
  const segments:number[][][]=[];
  rates.forEach((rate,i)=>{
    if(rate===undefined)return;
    if(i===0||rates[i-1]===undefined)segments.push([]);
    segments[segments.length-1]!.push([left+slot*(i+.5),top+ph*(1-rate/ceiling)]);
  });
  const total=content.allowed+content.blocked;
  const totalLabel=localizedNumber(total);
  const gap=content.allowed>0&&content.blocked>0?3:0;
  const blockedWidth=total>0?(w-gap)*content.blocked/total:0;
  const ticks=Array.from(new Set(content.period==='custom'?[0,buckets.length-1]:[0,Math.floor((buckets.length-1)/2),buckets.length-1])).filter(i=>i>=0&&i<buckets.length);
  return <Svg width={w*u} height={h*u} viewBox={`0 0 ${w} ${h}`}>
    {content.chart==='total'?<>
      <SvgText x={w/2} y={h*.5} textAnchor="middle" fontFamily="Arial" fontWeight="600" fill={ink} fontSize={Math.min(45,(w-4)*1.55/totalLabel.length)}>{totalLabel}</SvgText>
      <Rect x={0} y={h-25} width={blockedWidth} height={9} rx={2} fill={orange}/>
      <Rect x={blockedWidth+gap} y={h-25} width={total>0?w-blockedWidth-gap:w} height={9} rx={2} fill={total>0?green:grid}/>
      {label(0,h-2,localizedFormat('%@%% blocked',localizedNumber(total>0?Math.round(100*content.blocked/total):0)))}
      {label(w,h-2,localizedFormat('%@%% allowed',localizedNumber(total>0?Math.round(100*content.allowed/total):0)),'end')}
    </>:<>
      {[0,.5,1].map(f=><Line key={f} x1={left} y1={top+ph*(1-f)} x2={w-right} y2={top+ph*(1-f)} stroke={grid} strokeWidth={1}/>)}
      {[0,.5,1].map(f=>label(left-6,top+ph*(1-f)+3.5,content.chart==='rate'?new Intl.NumberFormat(locale.replace(/_/g,'-'),{style:'percent',maximumFractionDigits:0}).format(ceiling*f/100):compact(ceiling*f,locale),'end'))}
      {content.chart==='counts'?buckets.map((b,i)=>b.available?<ViewlessBars key={b.start} x={left+slot*(i+.15)} width={slot*.7} baseline={top+ph} allowed={ph*b.allowed/ceiling} blocked={ph*b.blocked/ceiling}/>:null):segments.map((points,index)=><Polyline key={index} points={points.map(p=>p.join(',')).join(' ')} fill="none" stroke={orange} strokeWidth={2.5} strokeLinecap="round" strokeLinejoin="round"/>)}
      {content.chart==='rate'&&segments.flatMap(points=>points.map(([x,y],index)=><Circle key={`${x}:${index}`} cx={x} cy={y} r={2.5} fill={orange}/>))}
      {ticks.map((index,i)=>label(i===0?left:i===ticks.length-1?w-right:left+slot*(index+.5),h-3,buckets[index]!.label,i===0?'start':i===ticks.length-1?'end':'middle'))}
    </>}
  </Svg>;
}
function ViewlessBars({x,width,baseline,allowed,blocked}:{x:number;width:number;baseline:number;allowed:number;blocked:number}) {
  return <><Rect x={x} y={baseline-allowed} width={width} height={allowed} fill={green}/><Rect x={x} y={baseline-allowed-blocked} width={width} height={blocked} fill={orange}/></>;
}

export function ActivityShareCard({content,onReady}:{content:ActivityShareCardContent;onReady?:(ready:boolean)=>void}) {
  const {locale}=useContext(PresentationContext);
  const density=PixelRatio.get(),u=2.5/density;
  const [readyToken,setReadyToken]=useState<string>();
  const modules=content.moduleCount+8,cell=Math.floor(activityCardFrame.footer.height*2.5/modules),qrPixels=modules*cell;
  useEffect(()=>{
    setReadyToken(undefined);onReady?.(false);
    if(cell<3)return;
    let second=0;
    const first=requestAnimationFrame(()=>{second=requestAnimationFrame(()=>{setReadyToken(content.token);onReady?.(true);});});
    return()=>{cancelAnimationFrame(first);if(second)cancelAnimationFrame(second);onReady?.(false);};
  },[content.token,cell,onReady]);
  const frame=(r:{x:number;y:number;width:number;height:number})=>({position:'absolute' as const,left:r.x*u,top:r.y*u,width:r.width*u,height:r.height*u});
  const type={allowFontScaling:false,style:{includeFontPadding:false}} as const;
  const count=localizedNumber(content.blocked);
  // Keep the emphasized count tied to its placeholder. In reordered translations
  // a date can precede it and contain the same digits as a small request count.
  const countMarker='\uFFF0';
  const formats=content.blocked===1?summaryFormats.one:summaryFormats.other;
  const [summaryBefore,summaryAfter]=localizedFormat(formats[content.period],countMarker,content.startLabel,content.endLabel).split(countMarker);
  const f=activityCardFrame.footer;
  return <View pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{position:'absolute',left:-10000,top:0,width:1080/density,height:1350/density}}>
    <Surface testID="activity-share-card" token={content.token} payload={content.payload} ready={readyToken===content.token}
      accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{width:1080/density,height:1350/density,backgroundColor:'#FFFFFF'}}>
      <View style={{height:4*u,backgroundColor:orange}}/>
      <View style={[frame(activityCardFrame.header),{flexDirection:'row',alignItems:'center',gap:12.96*u}]}>
        <Decoration mood="awake" look="original" colorScheme="light" staticExport accessible={false} style={{width:51.84*u,height:51.84*u}}/>
        <View style={{flex:1,gap:6.912*u}}>
          <Text {...type} style={[type.style,{fontSize:15.336*u,lineHeight:19.17*u,fontWeight:'600',color:ink}]}><Text style={{color:orange}}>Lava Security </Text>{localized('My activity')}</Text>
          <View style={{alignSelf:'flex-start',maxWidth:'100%',backgroundColor:'#F4F0EB',borderRadius:20*u,paddingHorizontal:9.072*u,paddingVertical:4.32*u}}>
            <Text {...type} numberOfLines={2} adjustsFontSizeToFit minimumFontScale={.65} style={[type.style,{fontSize:11.664*u,lineHeight:14.58*u,fontWeight:'500',color:'#544D47'}]}>{content.dateLabel}</Text>
          </View>
        </View>
      </View>
      <View testID="activity-share-chart" style={[frame(activityCardFrame.chart),{padding:19.008*u,borderRadius:21.6*u,backgroundColor:'#EDF3EE',justifyContent:'space-between'}]}>
        <Text {...type} style={[type.style,{fontSize:15.12*u,lineHeight:18.144*u,fontWeight:'600',color:ink}]}>{localized(chartTitles[content.chart])}</Text>
        <Chart content={content} u={u}/>
        <View style={{flexDirection:'row',justifyContent:'space-between'}}>{[['Blocked',content.blocked,orange],['Allowed',content.allowed,green]].map(([title,value,color])=><View key={title} style={{flexDirection:'row',alignItems:'center',gap:5*u}}>
          <View style={{width:7*u,height:7*u,borderRadius:3.5*u,backgroundColor:color as string}}/>
          <Text {...type} style={[type.style,{fontSize:12.528*u,lineHeight:15.034*u,color:ink}]}>{localized(title as string)} <Text style={{fontWeight:'600'}}>{(value as number)>=1000000?compact(value as number,locale):localizedNumber(value as number)}</Text></Text>
        </View>)}</View>
      </View>
      <View style={[frame({...f,width:f.width-f.height-15.12}),{justifyContent:'space-between'}]}>
        <Text {...type} numberOfLines={3} adjustsFontSizeToFit minimumFontScale={.62} style={[type.style,{height:66.407*u,fontSize:18.144*u,lineHeight:22.136*u,fontWeight:'500',letterSpacing:-.54*u,color:ink}]}>{summaryBefore}<Text style={{fontWeight:'600'}}>{count}</Text>{summaryAfter}</Text>
        <Text {...type} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={.62} style={[type.style,{fontSize:12.96*u,lineHeight:16.2*u,color:'#5E5952'}]}>{localized('Get Lava and stay protected today')}</Text>
      </View>
      {cell>=3&&<QR testID="activity-share-qr" payload={content.payload} moduleCount={content.moduleCount} style={{position:'absolute',left:(Math.round((f.x+f.width)*2.5)-qrPixels)/density,top:(Math.round((f.y+f.height)*2.5)-qrPixels)/density,width:qrPixels/density,height:qrPixels/density}}/>}
    </Surface>
  </View>;
}
