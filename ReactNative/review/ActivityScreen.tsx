import {Alert, localized} from '../app/presentation';
import {useAppQuery} from '../app/queries';
import {useEffect, useRef, useState} from 'react';
import {AppState, View} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import NativeReview, {type ActivityDates} from '../specs/NativeLavaReview';
import {LavaChoice} from '../src';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {Copy, Row, Screen} from './primitives';
import {QuietFooter} from './scaffold';
import {useReview} from './ReviewContext';
import {activityEmpty, activityExample} from './activity-model';
import {useReviewNavigation} from './navigation';
import {detailStyles as s} from './detail-scaffold';
import {StorySurface} from './story-scaffold';
import {ActivityCharts} from './activity-scaffold';
import {SettingsSurface} from './settings-scaffold';

function calendarDayKey(){
  const now=new Date();
  return `${now.getFullYear()}:${now.getMonth()}:${now.getDate()}:${now.getTimezoneOffset()}`;
}

// Reference: DiagnosticsView.swift. Date selection is the original native
// ActivityDateRangePickerSheet; React owns this screen and its accepted range.
export function ActivityScreen() {
  const nav = useReviewNavigation();
  const {app,live,activityExample: showExample} = useReview();
  const [dates, setDates] = useState<ActivityDates | null>(live?.activityDates ?? null);
  const [period,setPeriod]=useState<'today'|'week'|'month'|'custom'>('today');
  const dateRequest=useRef(0);
  const pendingPreset=useRef<number|undefined>(undefined);
  const calendarDay=useRef(calendarDayKey());
  const activePeriod=useRef(period);activePeriod.current=period;
  const mounted = useRef(false);
  const picking = useRef(false);
  const preparingCustom = useRef<number|undefined>(undefined);
  const [pickerVisible,setPickerVisible]=useState(false);
  const focused=useIsFocused();
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  useEffect(()=>{const listener=AppState.addEventListener('change',state=>setForeground(state==='active'));return()=>listener.remove();},[]);
  const canPresentCustom=useRef(focused&&foreground);canPresentCustom.current=focused&&foreground;
  useEffect(()=>{
    if((!focused||!foreground)&&preparingCustom.current!==undefined){
      ++dateRequest.current;preparingCustom.current=undefined;picking.current=false;setPickerVisible(false);
    }
  },[focused,foreground]);
  const choosePeriod=(preset:'today'|'week'|'month',showFailure=true)=>{
    if(picking.current)return;
    const request=++dateRequest.current;
    const day=calendarDayKey();pendingPreset.current=request;
    return NativeReview.getActivityDatePreset(preset).then(value=>{
      if(!mounted.current||request!==dateRequest.current)return;
      if(!value)throw new Error('Activity dates unavailable');
      calendarDay.current=day;
      setDates(value);setPeriod(preset);
    }).catch(()=>{if(showFailure&&mounted.current&&request===dateRequest.current)Alert.alert('Activity dates unavailable','Please try again.');})
      .finally(()=>{if(pendingPreset.current===request)pendingPreset.current=undefined;});
  };
  useEffect(() => {
    mounted.current = true;const request=++dateRequest.current;
    NativeReview.getActivityDates().then(value => { if (mounted.current&&request===dateRequest.current) setDates(value); })
      .catch(() => { if (mounted.current&&request===dateRequest.current) Alert.alert('Activity dates unavailable', 'Please try again.'); });
    return () => { mounted.current = false; };
  }, []);
  const wasForeground=useRef(foreground);
  useEffect(()=>{
    const returning=foreground&&!wasForeground.current;wasForeground.current=foreground;
    if(returning&&activePeriod.current!=='custom')choosePeriod(activePeriod.current,false);
  },[foreground]);
  const pickCustom=()=>{
    if(picking.current||!dates)return;
    picking.current=true;setPickerVisible(true);const request=++dateRequest.current;preparingCustom.current=request;
    Promise.resolve(period==='custom'?dates:NativeReview.getActivityDatePreset('fortnight'))
      .then(initial=>{
        if(!mounted.current||request!==dateRequest.current||!canPresentCustom.current)return null;
        if(!initial)throw new Error('Activity dates unavailable');
        preparingCustom.current=undefined;
        return NativeReview.pickActivityDates(initial.start,initial.end);
      })
      .then(value=>{if(mounted.current&&value&&request===dateRequest.current){setDates(value);setPeriod('custom');}})
      .catch(()=>{if(mounted.current&&request===dateRequest.current)Alert.alert('Activity dates unavailable','Please try again.');})
      .finally(()=>{if(request===dateRequest.current){preparingCustom.current=undefined;picking.current=false;if(mounted.current)setPickerVisible(false);}});
  };
  const query = useAppQuery<typeof activityEmpty>(dates ? {type:'activity.query',start:dates.start,end:dates.end,hourly:period==='today'} : null);
  // The existing foreground query poll rerenders this screen every five seconds.
  // Check the local calendar here instead of adding another timer or querying a
  // preset on every tick. Returning focus also catches a missed day/zone change.
  useEffect(()=>{
    if(!focused||!foreground||picking.current||pendingPreset.current!==undefined)return;
    const day=calendarDayKey();
    if(day===calendarDay.current)return;
    // A rejected refresh keeps the previous key so the next poll can retry.
    if(activePeriod.current!=='custom')choosePeriod(activePeriod.current,false);
    else calendarDay.current=day;
  });
  const summary = app ? query.value ?? activityEmpty : showExample && period==='today' && dates?.includesToday ? activityExample : activityEmpty;
  const loaded = !app || query.value !== undefined;
  const total = summary.allowed + summary.blocked;
  const qualifies=total>5000&&summary.blocked/total>0.1;
  useEffect(()=>{
    if(!app||!dates||!focused||!foreground||pickerVisible||!qualifies)return;
    const token=`activity-${Date.now()}-${Math.random()}`;
    void app.command({type:'activity.visibility',token,visible:true,start:dates.start,end:dates.end}).catch(()=>{});
    return()=>{void app.command({type:'activity.visibility',token,visible:false}).catch(()=>{});};
  },[app,dates?.start,dates?.end,focused,foreground,pickerVisible,qualifies]);
  return <Screen onRefresh={app?()=>query.refresh():undefined}>
    <LavaChoice testID="activity.period" reselectValue="custom" label={localized('Activity')} options={[{value:'today',label:localized('Today')},{value:'week',label:localized('7 days')},{value:'month',label:localized('Month')},{value:'custom',label:localized('Custom')}]} value={pickerVisible?'custom':period} disabled={pickerVisible} onValueChange={value=>value==='custom'?pickCustom():choosePeriod(value)}/>
    {period==='custom'&&dates&&<Copy testID="activity.custom-range" role="supporting" color={colors.secondaryText} verbatim>{dates.label}</Copy>}
    <StorySurface tone="green" testID="activity.digest"><ActivityCharts buckets={summary.buckets??[]} rangeKey={`${period}:${dates?.start}:${dates?.end}`}
      allowed={summary.allowed} blocked={summary.blocked} loaded={loaded} pending={!loaded&&!query.error} uptime={summary.uptime}/></StorySurface>
    {query.error&&<Copy role="supporting" color={colors.secondaryText}>{query.error}</Copy>}
    <SettingsSurface testID="activity.domain-logs">
      <Row intent="page" icon={foundation.symbol.ranking} testID="row.Top domains" title="Top Domains" onPress={() => nav.navigate('TopDomains', dates ? {start:dates.start,end:dates.end} : undefined)} />
      <Row intent="page" icon="clock.arrow.circlepath" title="Domain History" onPress={() => nav.navigate('History')} />
    </SettingsSurface>
    <QuietFooter note="Detailed activity stays on this device for 7 days." title="Review Privacy & Data" onPress={() => nav.navigate('Privacy')} />
  </Screen>;
}
