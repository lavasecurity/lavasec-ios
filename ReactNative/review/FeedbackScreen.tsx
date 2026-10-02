import {Alert} from '../app/presentation';
import {useState} from 'react';
import {View} from 'react-native';
import {LavaActionButton, LavaCard} from '../src';
import {colors} from '../src/colors.ios';
import {Copy, Section} from './primitives';
import {Group, Info, ListRow, QuietFooter, Sheet, Toggle, toolbarButton, useToolbar} from './scaffold';
import {DetailField, DetailReviewValue, DetailSteps, detailStyles as s} from './detail-scaffold';
import {previewNotice, useReviewNavigation} from './navigation';

const topics=["I can't visit a website","VPN or filter doesn't work","A Lava feature doesn't work",'Translation is not quite right','I have a suggestion','Something else'];
export function FeedbackScreen() {
  const nav=useReviewNavigation();const [step,setStep]=useState(0);const [furthest,setFurthest]=useState(0);const [topic,setTopic]=useState('');const [details,setDetails]=useState('');const [email,setEmail]=useState('');const [site,setSite]=useState('');const [diagnostics,setDiagnostics]=useState(false);
  const next=()=>{const value=Math.min(step+1,2);setStep(value);setFurthest(Math.max(value,furthest));};
  const close=()=>{if(topic||details||email||site||diagnostics)Alert.alert('Discard feedback?','Your feedback draft will be removed.',[{text:'Cancel',style:'cancel'},{text:'Discard',style:'destructive',onPress:()=>nav.goBack()}]);else nav.goBack();};
  useToolbar({unstable_headerLeftItems:()=>[toolbarButton('Cancel','xmark',close)],unstable_headerRightItems:()=>[]},[topic,details,email,site,diagnostics]);
  const field=(label:string,value:string,onChange:(s:string)=>void,multiline=false)=><View style={s.tightStack}><DetailField title={label} placeholder={label==='Details'?'What were you trying to do? What did Lava do instead?':label} value={value} onChangeText={onChange} multiline={multiline} maxLength={multiline?5000:320} autoCapitalize={multiline?'sentences':'none'} keyboardType={label==='Email for follow-up (optional)'?'email-address':label==='Site or domain'?'url':'default'}/>{multiline&&<View style={s.right}><Copy role="caption" color={colors.secondaryText}>{details.length}/5,000</Copy></View>}</View>;
  return <Sheet header={<DetailSteps titles={['Topic','Details','Review']} current={step} furthest={furthest} onSelect={setStep}/>}
    footer={<View style={s.actions}>{step>0&&<View style={s.flex}><LavaActionButton title="Back" role="secondary" onPress={()=>setStep(step-1)} /></View>}<View style={s.flex}><LavaActionButton title={step===0?'Continue':step===1?'Review':'Submit'} disabled={step===0?!topic:step===1?!details.trim():false} onPress={step===2?previewNotice:next} /></View></View>}>
    {step===0&&<><Info icon="ladybug" title="No silent telemetry" description="Lava only sends feedback after you review it and tap Submit" /><Section title="Choose a topic"><Group>{topics.map(title=><ListRow key={title} title={title} selected={topic===title} onPress={()=>{setTopic(title);setFurthest(Math.max(furthest,0));}} />)}</Group></Section></>}
    {step===1&&<><Section title="Tell us more"><LavaCard><View style={s.stack}>{topic===topics[0]&&<>{field('Site or domain',site,setSite)}<View style={s.divider}/></>}{field('Details',details,setDetails,true)}<View style={s.divider}/>{field('Email for follow-up (optional)',email,setEmail)}</View></LavaCard><Toggle title="Include optional diagnostic" standalone value={diagnostics} onChange={setDiagnostics} /></Section><QuietFooter note="Optional diagnostics include anonymized data like VPN status, network logs, and your active filter. They help the Lava team figure out what went wrong." title="See what information is sent" onPress={previewNotice} /></>}
    {step===2&&<Section title="Review and submit"><LavaCard><View style={s.stack}>{[['Topic',topic],...(site?[['Site or domain',site]]:[]),['Details',details||'Not provided'],['Email',email||'Not provided'],['Diagnostics',diagnostics?'Sent':'Not sent']].map(([label,value],i)=><DetailReviewValue key={label} label={label!} divider={i>0}>{value}</DetailReviewValue>)}</View></LavaCard></Section>}
  </Sheet>;
}
