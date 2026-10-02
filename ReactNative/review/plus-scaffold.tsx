import {connectionParts} from './connection-model';
import {useState,type PropsWithChildren,type ReactNode} from 'react';
import {View,StyleSheet,useWindowDimensions} from 'react-native';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';
import {useTextScale} from '../app/text-metrics';
import {Copy,DisclosureRow,Guardian,Symbol} from './primitives';
import {PagedCards} from './paging-scaffold';
import {Group,ListRow} from './scaffold';

// These illustrations explain possibilities, never live configuration. Purchase
// actions and entitlements remain with the screen and native service below them.
// Equal benefits share one frame. Their illustrations distinguish the stories;
// arbitrary fill/ordering variants must not imply a hierarchy between them.
function BenefitScene({title,description,art,testID,children}:PropsWithChildren<{
  title:string;description:string;art:ReactNode;testID?:string;
}>){
  const {width}=useWindowDimensions();const scale=useTextScale();
  const usable=Math.min(width,foundation.layout.readingWidth)-foundation.space.screenHorizontal*2-foundation.space.lg*2;
  const paired=usable/scale>=foundation.layout.readingWidth-foundation.space.xl*4;
  return <View testID={testID} style={[s.scene,paired&&s.paired]}>
    <View accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[s.art,paired&&s.pairedPart]}>{art}</View>
    <View style={[s.copy,paired&&s.pairedPart]}><Copy role="body" weight="700">{title}</Copy><Copy role="body" color={colors.secondaryText}>{description}</Copy>{children}</View>
  </View>;
}
function RoutineCard({title,icon,selected=false}:{title:string;icon:string;selected?:boolean}){
  return <View style={[s.routineCard,selected?s.routineSelected:s.routineQuiet]}>
    <Symbol name={icon} size={foundation.control.target} tone={selected?'white':'secondary'}/>
    <Copy role="section" center color={selected?colors.actionForeground:colors.secondaryText}>{title}</Copy>
    <View style={s.routineMark}><Symbol name={selected?'checkmark.circle.fill':'line.3.horizontal.decrease.circle'} size={foundation.control.glyphSlot} tone={selected?'white':'secondary'}/></View>
  </View>;
}
function RoutineScene(){
  const scale=useTextScale();
  // Larger text keeps the foreground illustration; the actual benefit and
  // capacity stay fully readable in the content, without shrinking to fit art.
  return <View style={s.routines}>
    {scale<=1.3&&<RoutineCard title="Home" icon="house"/>}
    <RoutineCard title="Work" icon="briefcase" selected/>
    {scale<=1.3&&<RoutineCard title="Away" icon="sun.max"/>}
  </View>;
}
function DNSChoice({custom=false}:{custom?:boolean}){
  return <View style={[s.dnsChoice,custom?s.dnsSelected:s.dnsQuiet]}>
    <Symbol name={custom?'checkmark.circle.fill':connectionParts.dns.symbol} size={foundation.control.glyphSlot} tone={custom?'white':'secondary'}/>
    <View style={s.choiceText}><Copy role="supporting" weight="600" color={custom?colors.actionForeground:colors.secondaryText}>{custom?'Custom DNS':'Device DNS'}</Copy></View>
  </View>;
}
function ConnectionChoiceScene(){
  return <View style={s.connectionChoice}>
    <View style={s.filterDisc}><Symbol name="line.3.horizontal.decrease.circle" size={foundation.control.target}/></View>
    <View style={s.choiceStem}/>
    <View style={s.dnsChoices}>{[false,true].map(custom=><View key={String(custom)} style={s.dnsBranch}>
      <View style={s.branchConnector}><View style={[s.branchRail,custom?s.branchAfter:s.branchBefore]}/><View style={[s.branchLine,custom?s.chosenLine:s.quietLine]}/></View>
      <DNSChoice custom={custom}/>
    </View>)}</View>
  </View>;
}
function GuardScene(){
  const scale=useTextScale();
  return <View style={s.guardPortraits}>
    {scale<=1.3&&<View style={s.guardCompanion}><Guardian look="kiwiCreme" mood="awake" size={foundation.control.target*2}/></View>}
    <View style={s.guardPortrait}><Guardian look="aquamarine" mood="awake" size={foundation.control.target*3}/></View>
    {scale<=1.3&&<View style={s.guardCompanion}><Guardian look="strawberryObsidian" mood="awake" size={foundation.control.target*2}/></View>}
  </View>;
}
export function LavaPlusStory(){
  const [details,setDetails]=useState(false);
  return <View style={s.stack}>
    <View style={s.intro}><Copy role="body" color={colors.secondaryText}>More ways to make Lava your own</Copy></View>
    <PagedCards label="Lava Plus benefits" pages={[
      {id:'room',title:'Room for more',content:<BenefitScene testID="plus.scene.routines" title="Room for more" description="Keep work, home and everything in between covered—with space for 50 filters and 2 million rules." art={<RoutineScene/>}/>},
      {id:'connection',title:'Choose how you connect',content:<BenefitScene testID="plus.scene.connection" title="Choose how you connect" description="Keep the DNS and VPN you trust. Make Lava fit the setup you’ve sweated over." art={<ConnectionChoiceScene/>}/>},
      {id:'guard',title:'Find your Lava',content:<BenefitScene testID="plus.scene.guards" title="Find your Lava" description="Choose your Guard. Discover what they’re made of—and the security tips they carry." art={<GuardScene/>}/>},
    ]}/>
    <Group testID="plus.included"><DisclosureRow icon="gift" title="Everything included" expanded={details} onChange={setDetails}/>
    {details&&[
      ['Saved filters','Up to 50'],['Filter rules','Up to 2 million'],['Allowed domains','Up to 1,000'],['Blocked domains','Up to 1,000'],
      ['Your own blocklists','Included'],['Custom DNS','Included'],['VPN chaining','Included'],['All Lava Guards','Included'],['Family Sharing','Included'],
    ].map(([title,value])=><ListRow key={title} title={title!} metadata={value}/>)}</Group>
  </View>;
}
const s=StyleSheet.create({
  stack:{gap:foundation.space.xl},intro:{gap:foundation.space.sm},
  scene:{flexGrow:1,padding:foundation.space.lg,gap:foundation.space.lg},
  paired:{flexDirection:'row',alignItems:'center',gap:foundation.space.xl},
  pairedPart:foundation.layout.horizontalPart,art:{minHeight:foundation.control.target*4,justifyContent:'center'},copy:{gap:foundation.space.sm},
  routines:{flexDirection:'row',alignItems:'center',justifyContent:'center',paddingHorizontal:foundation.space.sm},
  routineCard:{flex:1,minWidth:0,maxWidth:foundation.control.target*3.5,borderRadius:foundation.radius.control,borderCurve:'continuous',paddingHorizontal:foundation.space.sm,gap:foundation.space.sm,alignItems:'center'},
  routineQuiet:{backgroundColor:colors.groupedBackground,paddingVertical:foundation.space.md},
  routineSelected:{backgroundColor:colors.safeControlGreen,paddingVertical:foundation.space.xl,marginHorizontal:-foundation.space.sm,zIndex:1},routineMark:{paddingTop:foundation.space.sm},
  connectionChoice:{flexDirection:'row',alignItems:'center',justifyContent:'center'},
  filterDisc:{width:foundation.control.target*1.5,height:foundation.control.target*1.5,borderRadius:foundation.radius.circle,backgroundColor:colors.softGreen,alignItems:'center',justifyContent:'center'},
  choiceStem:{width:foundation.space.md,height:1,backgroundColor:colors.safeGreen},
  dnsChoices:{flex:1,minWidth:0},dnsBranch:{flexDirection:'row',alignItems:'stretch'},
  branchConnector:{width:foundation.space.md},branchRail:{position:'absolute',left:0,width:1},
  branchBefore:{top:'50%',bottom:0,backgroundColor:colors.separator},branchAfter:{top:0,bottom:'50%',backgroundColor:colors.safeGreen},
  branchLine:{position:'absolute',left:0,right:0,top:'50%',height:1},chosenLine:{backgroundColor:colors.safeGreen},quietLine:{backgroundColor:colors.separator},
  dnsChoice:{flex:1,marginVertical:foundation.space.md,minHeight:foundation.control.target*1.25,flexDirection:'row',alignItems:'center',paddingHorizontal:foundation.space.md,paddingVertical:foundation.space.sm,gap:foundation.space.sm,borderRadius:foundation.radius.control,borderCurve:'continuous'},
  dnsQuiet:{backgroundColor:colors.groupedBackground},dnsSelected:{backgroundColor:colors.safeControlGreen},choiceText:{flex:1,minWidth:0},
  guardPortraits:{flexDirection:'row',alignItems:'center',justifyContent:'center'},
  guardPortrait:{alignItems:'center',justifyContent:'center',width:foundation.control.target*3.5,minHeight:foundation.control.target*3.5,zIndex:1},
  guardCompanion:{flex:1,minWidth:0,alignItems:'center',justifyContent:'center',marginHorizontal:-foundation.space.sm,opacity:0.45},
});
