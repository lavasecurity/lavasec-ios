import {useEffect,useRef,useState} from 'react';
import {AccessibilityInfo,AppState} from 'react-native';
import {useIsFocused,useRoute,type RouteProp} from '@react-navigation/native';
import {localized} from '../app/presentation';
import NativeReview from '../specs/NativeLavaReview';
import {colors} from '../src/colors.ios';
import {LavaActionButton,LavaToggleRow} from '../src';
import {useFeedback} from '../src/feedback';
import {Copy,Screen} from './primitives';
import {useReview} from './ReviewContext';
import {useDiscoveryVisit} from './discovery';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {connectionStages,connectionDemo,demoEnding,demoSection,demoReadingTime,type ConnectionPart} from './connection-model';
import {ConnectionScene,ExplorePlayground,ExploreDescriptions,DemoTransport,StoryLink} from './story-scaffold';
import {DemoPlaybackClock} from './explore-playback';

export function ExploreLink({part,title='Explore this connection',from}:{part?:ConnectionPart;title?:string;from?:'DNS'|'Filters'}){
  const nav=useReviewNavigation();const route=useRoute();
  return <StoryLink title={title} onPress={()=>nav.navigate('Explore',{part,...(from?{returnTo:from,returnKey:route.key}:{})})}/>;
}
export function ExploreScreen(){
  const {app,live,session}=useReview();const feedback=useFeedback();const route=useRoute<RouteProp<ReviewRoutes,'Explore'>>();const nav=useReviewNavigation(route.params);
  useDiscoveryVisit('ios27Patch.settings');
  const stages=connectionStages(live,session);const scenes=connectionDemo(stages);
  const dnsPatchUnseen=live?.discoveries?.['ios27Patch.page']===true;const dnsPatchAvailable=!app||!!live?.dnsPatch?.available;
  const [selected,setSelected]=useState<ConnectionPart|undefined>(route.params?.part);
  const selectedRef=useRef(selected);selectedRef.current=selected;
  const [frame,setFrame]=useState<number>();const [completed,setCompleted]=useState(false);
  const [playing,setPlaying]=useState(false);const playingRef=useRef(playing);playingRef.current=playing;const playback=useRef(new DemoPlaybackClock()).current;
  const [narration,setNarration]=useState(false);const [foreground,setForeground]=useState(AppState.currentState==='active');
  const focused=useIsFocused();const inDemo=frame!==undefined&&frame<scenes.length;const frameRef=useRef(frame);frameRef.current=frame;
  const routing=stages.map(stage=>`${stage.id}:${stage.muted??false}`).join('|');
  const cancel=()=>{playback.cancel();NativeReview.stopDemo();};
  const pause=()=>{cancel();playingRef.current=false;setPlaying(false);};
  const stop=()=>{pause();frameRef.current=undefined;setFrame(undefined);};
  useEffect(()=>{stop();setSelected(route.params?.part);},[route.params?.part]);
  // Stop timers and system speech when interrupted, keeping the current lesson
  // step painted. A real route or routing change still resets the lesson below.
  useEffect(()=>{const listener=AppState.addEventListener('change',state=>{if(state!=='active')pause();setForeground(state==='active');});return()=>listener.remove();},[]);
  useEffect(()=>{if(!focused)stop();},[focused]);
  useEffect(()=>{stop();setCompleted(false);},[routing]);
  useEffect(()=>()=>{cancel();},[]);
  useEffect(()=>{
    if(frame===undefined||!scenes[frame]||!focused||!foreground)return;
    const caption=localized(scenes[frame]!.caption);
    if(!narration||!playing)AccessibilityInfo.announceForAccessibility(caption);
    if(!playing)return;
    const speech=narration?NativeReview.speakDemo(caption,live?.presentation?.locale??'en'):Promise.resolve(false);
    playback.start(demoReadingTime(caption),speech,()=>{
      if(frame+1<scenes.length){frameRef.current=frame+1;setFrame(frame+1);}
      else {stop();setCompleted(true);}
    });
    return()=>{cancel();};
  },[frame,playing,focused,foreground,narration,routing,live?.presentation?.locale]);
  const part=inDemo?undefined:stages.find(stage=>stage.id===selected);
  const openSettings=()=>{
    const destination=part?.destination;if(!destination)return;
    const current=nav.getState?.();const previous=current?.routes[current.index-1];
    if(route.params?.returnTo===destination&&route.params.returnKey&&previous?.key===route.params.returnKey)nav.goBack();
    else nav.navigate(destination);
  };
  const play=()=>{if(!focused||!foreground)return;if(playingRef.current){pause();return;}
    if(frameRef.current===undefined){setSelected(undefined);setCompleted(false);frameRef.current=0;setFrame(0);}playingRef.current=true;setPlaying(true);};
  const advance=(direction:number)=>{
    const current=frameRef.current;if(current===undefined||!focused||!foreground)return;
    if(direction>0&&current===scenes.length-1){
      stop();setCompleted(true);
      feedback.emit({semantic:'selected',controlID:'explore.step',value:'demo:complete'});
      return;
    }
    const next=Math.max(0,Math.min(scenes.length-1,current+direction));if(next===current)return;
    pause();frameRef.current=next;setFrame(next);
    feedback.emit({semantic:'selected',controlID:'explore.step',value:`demo:${next}`});
  };
  const selectPart=(id:ConnectionPart,toggle:boolean)=>{
    if(!focused||!foreground)return;
    if(frameRef.current!==undefined)stop();
    const next=toggle&&selectedRef.current===id?undefined:id;
    if(next===selectedRef.current)return;
    selectedRef.current=next;setSelected(next);setCompleted(false);
    feedback.emit({semantic:'selected',controlID:'explore.step',value:`inspection:${next??'none'}`});
  };
  const configureFooter=!inDemo&&part?.destination
    ? part.id==='dns' ? <><StoryLink testID="explore.configure" title="Open DNS settings" onPress={openSettings}/>
        {dnsPatchAvailable&&<StoryLink testID="explore.dns-patch" title="DNS patch for iOS 27" attention={dnsPatchUnseen} onPress={()=>nav.navigate('DNSPatch')}/>}</>
      : <StoryLink testID="explore.configure" title={part.id==='filter'?'Open Filters':'Open VPN chaining'} onPress={openSettings}/>
    : !part&&!inDemo?<LavaToggleRow title="Narration" value={narration} onValueChange={setNarration}/>:undefined;
  return <Screen wide>
    <ExplorePlayground scene={<ConnectionScene stages={stages} selected={part?.id} attention={inDemo?scenes[frame]!.parts:undefined}
      discoveryAttention={dnsPatchUnseen&&part?.id!=='dns'?['dns']:undefined}
      onSelect={stage=>selectPart(stage.id,true)} onInspect={stage=>selectPart(stage.id,false)}/>}
      transport={inDemo?<DemoTransport frame={frame} total={scenes.length} playing={playing} onPrevious={()=>advance(-1)} onPlay={play} onNext={()=>advance(1)}/>:undefined}
      footer={configureFooter}>
      {inDemo?<ExploreDescriptions selected={frame} descriptions={scenes.map((scene,index)=>({id:scene.id,title:demoSection(index,stages),caption:scene.caption}))}/>:
        part?<><Copy testID="explore.part.title" role="section">{part.title}</Copy>
          <Copy testID="explore.part.description" role="supporting" color={colors.secondaryText}>{part.explanation}</Copy>
          <Copy testID="explore.part.summary" role="supporting" verbatim color={colors.secondaryText}>{part.setupSummary}</Copy></>:
          <><Copy role="section">{completed?demoEnding.title:'Welcome'}</Copy><Copy role="supporting" color={colors.secondaryText}>{completed?demoEnding.caption:'Play a demo of how Lava works, or tap a step to learn more.'}</Copy></>}
      {!inDemo&&!part&&<LavaActionButton testID="explore.play" title={completed?'Play again':'Play demo'} icon="play" onPress={play}/>}
    </ExplorePlayground></Screen>;
}
