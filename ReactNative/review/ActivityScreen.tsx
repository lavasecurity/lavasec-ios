import {useRouteViewState} from '../app/use-route-view-state';
import {Alert,isPresentationCancellation,localized} from '../app/presentation';
import {useAppQuery} from '../app/queries';
import {useEffect, useRef, useState} from 'react';
import {AppState, View} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import NativeReview, {type ActivityDates} from '../specs/NativeLavaReview';
import {LavaChoice} from '../src';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {Copy, Row, Screen} from './primitives';
import {QuietFooter,toolbarAction,useToolbar} from './scaffold';
import {useReview} from './ReviewContext';
import {activityEmpty, activityExample} from './activity-model';
import {useReviewNavigation} from './navigation';
import {StorySurface} from './story-scaffold';
import {ActivityCharts} from './activity-scaffold';
import {SettingsMessage,SettingsSurface} from './settings-scaffold';
import {useLocalLogActions} from './local-log-actions';
import {ActivityShareCard,type ActivityChartKind} from './ActivityShareCard';
import {useActivityShare} from './activity-share-actions';
import {mayInteractWithPresentation} from '../app/read-cache';

function calendarDayKey(){
  const now=new Date();
  return `${now.getFullYear()}:${now.getMonth()}:${now.getDate()}:${now.getTimezoneOffset()}`;
}

// Reference: DiagnosticsView.swift. Date selection is the original native
// ActivityDateRangePickerSheet; React owns this screen and its accepted range.
export function ActivityScreen() {
  const nav = useReviewNavigation();
  const {app,live,activityExample: showExample} = useReview();
  const logs=useLocalLogActions();const logActions=useRef(logs);logActions.current=logs;
  const exportAction=useRef(()=>{});
  const [dates, setDates] = useRouteViewState<ActivityDates | null>(live?.activityDates ?? null);
  const [period,setPeriod]=useRouteViewState<'today'|'week'|'month'|'custom'>('today');
  const dateRequest=useRef(0);
  const pendingPreset=useRef<number|undefined>(undefined);
  const dateWork=useRef<{request:number;epoch:number|undefined}|undefined>(undefined);
  // The admitted native projection already supplies today's calendar range.
  // Use it for the first query instead of starting another date round trip.
  const initializedDates=useRef(!!live?.activityDates);
  const resumePreset=useRef(false);
  const calendarDay=useRef(calendarDayKey());
  const activePeriod=useRef(period);activePeriod.current=period;
  const mounted = useRef(false);
  const picking = useRef(false);
  const [pickerVisible,setPickerVisible]=useState(false);
  const focused=useIsFocused();
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  const epoch=app?.getReadEpoch?.();
  const authoritative=!app?.getSnapshot||!!live&&!!app.getSnapshot().snapshot;
  const activeDates=!app?.getSnapshot||foreground;
  const canPresentCustom=useRef(focused&&activeDates);canPresentCustom.current=focused&&activeDates;
  const cancelDates=()=>{
    ++dateRequest.current;dateWork.current=undefined;pendingPreset.current=undefined;
    picking.current=false;setPickerVisible(false);
  };
  // Invalidate synchronously at the lifecycle boundary. A native picker reply
  // can arrive before React commits its concealed render.
  useEffect(()=>{mounted.current=true;const listener=AppState.addEventListener('change',state=>{
    if(state!=='active'){resumePreset.current=true;cancelDates();}
    setForeground(state==='active');
  });return()=>{mounted.current=false;++dateRequest.current;listener.remove();};},[]);
  const canReadDates=()=>mounted.current&&canPresentCustom.current&&(!app?.getSnapshot
    ||!!live&&AppState.currentState==='active'&&!!app.getSnapshot().snapshot&&app.getReadEpoch?.()===epoch);
  const choosePeriod=(preset:'today'|'week'|'month',showFailure=true)=>{
    if(picking.current||!canReadDates())return;
    const request=++dateRequest.current;
    const day=calendarDayKey();pendingPreset.current=request;dateWork.current={request,epoch};
    return NativeReview.getActivityDatePreset(preset).then(value=>{
      if(request!==dateRequest.current||!canReadDates())return;
      if(!value)throw new Error('Activity dates unavailable');
      initializedDates.current=true;calendarDay.current=day;
      setDates(value);setPeriod(preset);
    }).catch(()=>{if(showFailure&&request===dateRequest.current&&canReadDates())Alert.alert('Activity dates unavailable','Please try again.');})
      .finally(()=>{if(pendingPreset.current===request)pendingPreset.current=undefined;if(dateWork.current?.request===request)dateWork.current=undefined;});
  };
  useEffect(()=>{
    if(!focused||!activeDates||!authoritative){
      if(!foreground||!authoritative)resumePreset.current=true;
      if(dateWork.current)cancelDates();return;
    }
    // A resumed route can render before AppStore.refresh restores its fields.
    // Start date preparation only with the current render's admitted setters.
    if(dateWork.current&&dateWork.current.epoch!==epoch){resumePreset.current=true;cancelDates();}
    if(dateWork.current)return;
    if(!initializedDates.current){
      const request=++dateRequest.current;const day=calendarDayKey();dateWork.current={request,epoch};
      NativeReview.getActivityDates().then(value=>{
        if(request!==dateRequest.current||!canReadDates())return;
        initializedDates.current=true;resumePreset.current=false;calendarDay.current=day;setDates(value);
      }).catch(()=>{if(request===dateRequest.current&&canReadDates())Alert.alert('Activity dates unavailable','Please try again.');})
        .finally(()=>{if(dateWork.current?.request===request)dateWork.current=undefined;});
    }else if(resumePreset.current){
      resumePreset.current=false;
      if(activePeriod.current!=='custom')choosePeriod(activePeriod.current,false);
    }
  },[app,focused,activeDates,authoritative,epoch]);
  const pickCustom=()=>{
    if(picking.current||!dates||!canReadDates())return;
    picking.current=true;setPickerVisible(true);const request=++dateRequest.current;dateWork.current={request,epoch};
    Promise.resolve(period==='custom'?dates:NativeReview.getActivityDatePreset('fortnight'))
      .then(initial=>{
        if(request!==dateRequest.current||!canReadDates())return null;
        if(!initial)throw new Error('Activity dates unavailable');
        return NativeReview.pickActivityDates(initial.start,initial.end);
      })
      .then(value=>{if(value&&request===dateRequest.current&&canReadDates()){initializedDates.current=true;setDates(value);setPeriod('custom');}})
      .catch(()=>{if(request===dateRequest.current&&canReadDates())Alert.alert('Activity dates unavailable','Please try again.');})
      .finally(()=>{if(request===dateRequest.current){dateWork.current=undefined;picking.current=false;if(mounted.current)setPickerVisible(false);}});
  };
  const query = useAppQuery<typeof activityEmpty>(dates ? {type:'activity.query',start:dates.start,end:dates.end,hourly:period==='today'} : null);
  // The existing foreground query poll rerenders this screen every five seconds.
  // Check the local calendar here instead of adding another timer or querying a
  // preset on every tick. Returning focus also catches a missed day/zone change.
  useEffect(()=>{
    if(!canReadDates()||picking.current||dateWork.current||pendingPreset.current!==undefined)return;
    const day=calendarDayKey();
    if(day===calendarDay.current)return;
    // A rejected refresh keeps the previous key so the next poll can retry.
    if(activePeriod.current!=='custom')choosePeriod(activePeriod.current,false);
    else calendarDay.current=day;
  });
  const summary = app ? query.value ?? activityEmpty : showExample && period==='today' && dates?.includesToday ? activityExample : activityEmpty;
  const loaded = !app || query.value !== undefined;
  const [chart,setChart]=useState<ActivityChartKind>('total');
  const share=useActivityShare({dates,chart,period,loaded});
  const shareAction=useRef(share);shareAction.current=share;
  const choosingExport=useRef(false);
  exportAction.current=()=>{
    if(choosingExport.current||logs.exportBusy||share.busy||!focused||!foreground||!mayInteractWithPresentation(app))return;
    const readEpoch=app?.getReadEpoch?.();choosingExport.current=true;
    void NativeReview.chooseActivityExport(!!app&&loaded&&!!dates).then(choice=>{
      if(!mounted.current||!canPresentCustom.current||!mayInteractWithPresentation(app)||app?.getReadEpoch?.()!==readEpoch)return;
      if(choice==='chart')shareAction.current.exportChart();
      else if(choice==='diagnostics')logActions.current.exportLogs();
      else if(choice==='logs')logActions.current.exportAllLogs();
    }).catch(error=>{if(!isPresentationCancellation(error.message))Alert.alert('Lava',error.message);})
      .finally(()=>{choosingExport.current=false;});
  };
  useToolbar({unstable_headerRightItems:()=>[
    toolbarAction('Export','share',()=>exportAction.current(),logs.exportBusy||share.busy,'activity.export-logs'),
    toolbarAction('Clear all logs','delete',()=>logActions.current.clearAllLogs(),logs.clearBusy,'activity.clear-logs'),
  ]},[logs.exportBusy,share.busy,logs.clearBusy]);
  const total = summary.allowed + summary.blocked;
  const qualifies=total>5000&&summary.blocked/total>0.1;
  useEffect(()=>{
    if(!app||!dates||!focused||!foreground||pickerVisible||!qualifies)return;
    const token=`activity-${Date.now()}-${Math.random()}`;
    void app.command({type:'activity.visibility',token,visible:true,start:dates.start,end:dates.end}).catch(()=>{});
    return()=>{void app.command({type:'activity.visibility',token,visible:false}).catch(()=>{});};
  },[app,dates?.start,dates?.end,focused,foreground,pickerVisible,qualifies]);
  return <Screen onRefresh={app?()=>query.refresh():undefined}>
    {share.content&&focused&&foreground&&<ActivityShareCard content={share.content} onReady={share.ready}/>}
    {!!share.error&&<SettingsMessage warning>{share.error}</SettingsMessage>}
    {!!logs.exportError&&<SettingsMessage warning>{logs.exportError}</SettingsMessage>}
    <LavaChoice testID="activity.period" reselectValue="custom" label={localized('Activity')} options={[{value:'today',label:localized('Today')},{value:'week',label:localized('7 days')},{value:'month',label:localized('Month')},{value:'custom',label:localized('Custom')}]} value={pickerVisible?'custom':period} disabled={pickerVisible} onValueChange={value=>value==='custom'?pickCustom():choosePeriod(value)}/>
    {period==='custom'&&dates&&<Copy testID="activity.custom-range" role="supporting" color={colors.secondaryText} verbatim>{dates.label}</Copy>}
    <StorySurface tone="green" testID="activity.digest"><ActivityCharts buckets={summary.buckets??[]} rangeKey={`${period}:${dates?.start}:${dates?.end}`}
      allowed={summary.allowed} blocked={summary.blocked} loaded={loaded} pending={!loaded&&!query.error} uptime={summary.uptime} chart={chart} onChartChange={setChart}/></StorySurface>
    {query.error&&<Copy role="supporting" color={colors.secondaryText}>{query.error}</Copy>}
    <SettingsSurface testID="activity.domain-logs">
      <Row intent="page" icon={foundation.symbol.ranking} testID="row.Top domains" title="Top Domains" onPress={() => nav.navigate('TopDomains', dates ? {start:dates.start,end:dates.end} : undefined)} />
      <Row intent="page" icon="clock.arrow.circlepath" title="Domain History" onPress={() => nav.navigate('History')} />
    </SettingsSurface>
    <QuietFooter note="Detailed activity stays on this device for 7 days." title="Review Privacy & Data" onPress={() => nav.navigate('Privacy')} />
  </Screen>;
}
