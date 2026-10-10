import {animationNow} from '../src/animation-clock';
import {useEffect,useLayoutEffect,useRef,useState,type ReactNode} from 'react';
import {Animated,AppState,Easing,Pressable,StyleSheet,View} from 'react-native';
import {useHeaderHeight} from '@react-navigation/elements';
import {useIsFocused,usePreventRemove} from '@react-navigation/native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import type {AppCommand,OnboardingSetup} from '../app/contract';
import {mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationNativeLayout,usePresentationReadiness} from '../app/use-presentation-readiness';
import {Alert,localized} from '../app/presentation';
import {LavaActionButton} from '../src';
import {lavaTokens} from '../src/generated/tokens';
import {foundation} from '../src/foundation';
import {GuardianDrawing} from '../src/GuardianDrawing';
import {OnboardingBackground,OnboardingLavaDrawing} from '../src/OnboardingDrawing';
import {useReview} from './ReviewContext';
import {useOnboardingDestination} from './onboarding-geometry';
import {OnboardingTravel,OnboardingPhaseCommands,onboardingPageMotion} from './onboarding-motion';
import {useCrossFadePreference,useReducedMotionPreference} from './navigation-scaffold';
import {OnboardingChoice,OnboardingCurtain,OnboardingFeature,OnboardingFooter,OnboardingPageScroll,OnboardingProgress,OnboardingStageLayout,OnboardingStep,OnboardingWelcome,onboardingPageTitle} from './onboarding-scaffold';
import {Copy} from './primitives';
import {toolbarButton,useToolbar} from './scaffold';

const easeInOut=Easing.bezier(.42,0,.58,1);
export function OnboardingFlow(){
  const {app,live,look}=useReview();const geometry=useOnboardingDestination();const {setup,frames,sourceFrame,size,source}=geometry;
  // This hook belongs to the visible modal's independent navigator. The
  // hidden Guard viewport cannot admit setup while its drawings have zero size.
  const focused=useIsFocused();const currentVisit=!!setup&&(!app||live?.onboardingSetup?.id===setup.id);
  const onLayout=usePresentationNativeLayout(currentVisit);
  usePresentationReadiness(app,!!app&&focused&&currentVisit,size.width>0&&size.height>0,`onboarding-size:${setup?.id}`);
  const mascotSize=lavaTokens.guard.mascotSize;
  const reduced=useReducedMotionPreference();const crossFade=useCrossFadePreference();const header=useHeaderHeight();const insets=useSafeAreaInsets();
  const [elapsed,setElapsed]=useState(0);const [openingElapsed,setOpeningElapsed]=useState(0);const [retry,setRetry]=useState(0);const [failed,setFailed]=useState(false);
  const [permissionSmile,setPermissionSmile]=useState(false);const previousRequest=useRef(setup?.busy);const smileTimer=useRef<ReturnType<typeof setTimeout>|undefined>(undefined);
  const travel=useRef<OnboardingTravel|undefined>(undefined);const travelStart=useRef<number|undefined>(undefined);const openStart=useRef<number|undefined>(undefined);
  const sendPending=useRef(new Set<string>());const alive=useRef(true);const lastPage=useRef(setup?.page??0);
  const pendingNavigation=useRef<{key:string}|undefined>(undefined);
  const phaseCommands=useRef(new OnboardingPhaseCommands());
  const blink=useRef(0);if(setup&&lastPage.current!==setup.page){if(lastPage.current===3&&setup.page===4)blink.current++;lastPage.current=setup.page;}
  const backdrop=useRef(new Animated.Value(setup?.page===0?1:0)).current;
  const mascotOpacity=useRef(new Animated.Value(setup?.page===0?0:1)).current;
  const returnOffset=useRef(new Animated.ValueXY({x:0,y:0})).current;
  const previousPosition=useRef<{x:number;y:number}|undefined>(undefined);const previousPage=useRef(setup?.page);
  const previousPaintPage=useRef(setup?.page);
  const paintVisit=useRef({id:setup?.id,page:setup?.page,previous:undefined as number|undefined,generation:0});
  if(paintVisit.current.id!==setup?.id||paintVisit.current.page!==setup?.page)paintVisit.current={id:setup?.id,page:setup?.page,previous:paintVisit.current.id===setup?.id?paintVisit.current.page:undefined,generation:paintVisit.current.generation+1};
  const returningWelcome=setup?.page===0&&paintVisit.current.previous!==undefined&&paintVisit.current.previous!==0;
  const returnGeneration=paintVisit.current.generation;
  const [readyReturn,setReadyReturn]=useState<number>();
  const returnReady=readyReturn===returnGeneration;
  const [settledReturn,setSettledReturn]=useState<number>();
  const returnSettled=settledReturn===paintVisit.current.generation;
  const command=(action:AppCommand,quiet=false)=>{
    // AppStore serializes choices and navigation. Keep A→B→A intent; only
    // consecutive duplicate navigation and identical pending side effects coalesce.
    const navigation=action.type==='onboarding.navigate'||action.type==='onboarding.back';
    const choice=action.type==='onboarding.choice';const key=JSON.stringify(action);
    if(!app||!mayInteractWithPresentation(app))return Promise.resolve(false);
    if(navigation?pendingNavigation.current?.key===key:!choice&&sendPending.current.has(key))return Promise.resolve(false);
    const intent=navigation?{key}:undefined;
    if(intent)pendingNavigation.current=intent;else if(!choice)sendPending.current.add(key);
    return app.command(action).then(()=>true).catch(error=>{if(!quiet&&alive.current&&mayInteractWithPresentation(app)&&!['Authentication cancelled.','Read access changed.'].includes(error.message))Alert.alert('Lava',error.message);return false;})
      .finally(()=>{if(intent){if(pendingNavigation.current===intent)pendingNavigation.current=undefined;}else if(!choice)sendPending.current.delete(key);});
  };
  usePreventRemove(!!setup,()=>{
    if(!setup)return;
    if(setup.mock)void command({type:'onboarding.dismiss',id:setup.id});
    else if(setup.history.length)void command({type:'onboarding.back',id:setup.id});
  });
  useEffect(()=>{alive.current=true;return()=>{alive.current=false;};},[]);
  useEffect(()=>{
    if(previousRequest.current==='notifications'&&!setup?.busy&&setup?.notifications&&setup.vpnInstalled&&setup.page===2){
      setPermissionSmile(true);clearTimeout(smileTimer.current);smileTimer.current=setTimeout(()=>setPermissionSmile(false),1090);
    }
    previousRequest.current=setup?.busy;
    if(setup?.page!==2||setup.busy){clearTimeout(smileTimer.current);setPermissionSmile(false);}
  },[setup?.busy,setup?.notifications,setup?.vpnInstalled,setup?.page]);
  useEffect(()=>()=>clearTimeout(smileTimer.current),[]);
  useLayoutEffect(()=>{
    const returning=previousPage.current===5&&setup?.page!==5;previousPage.current=setup?.page;
    returnOffset.stopAnimation();returnOffset.setValue({x:0,y:0});
    if(!returning||!sourceFrame||!previousPosition.current)return;
    returnOffset.setValue({x:previousPosition.current.x-sourceFrame.x-sourceFrame.width/2,y:previousPosition.current.y-sourceFrame.y-sourceFrame.height/2});
    const motion=Animated.timing(returnOffset,{toValue:{x:0,y:0},duration:400,easing:easeInOut,useNativeDriver:true});motion.start();return()=>motion.stop();
  },[setup?.id,setup?.page]);
  useEffect(()=>{if(!setup)return;const enter=()=>{if(AppState.currentState==='active')void command({type:'onboarding.enter',id:setup.id},true);};enter();const listener=AppState.addEventListener('change',state=>{if(state==='active')enter();});return()=>listener.remove();},[setup?.id,live?.security.readRevision]);
  useEffect(()=>{
    if(!setup)return;
    if(returningWelcome&&!returnReady)return;
    const previous=previousPaintPage.current;previousPaintPage.current=setup.page;
    const motion=onboardingPageMotion(previous,setup.page,reduced,crossFade);let active=true;
    const generation=paintVisit.current.generation;
    const background=Animated.timing(backdrop,{toValue:setup.page===0?1:0,duration:returningWelcome?motion.ordinary:reduced?250:700,easing:returningWelcome?easeInOut:Easing.bezier(0,0,.58,1),useNativeDriver:true});
    const moving=returningWelcome?background:Animated.parallel([background,
      Animated.timing(mascotOpacity,{toValue:setup.page===0?0:1,duration:motion.entryDuration,delay:motion.entryDelay,easing:easeInOut,useNativeDriver:true})]);
    moving.start(({finished})=>{if(active&&finished&&returningWelcome&&paintVisit.current.generation===generation){mascotOpacity.setValue(0);setSettledReturn(generation);}});
    return()=>{active=false;moving.stop();};
  },[setup?.id,setup?.page,reduced,crossFade,returnReady]);
  useEffect(()=>{
    phaseCommands.current.reset();
    travel.current=undefined;travelStart.current=undefined;openStart.current=undefined;setElapsed(0);setOpeningElapsed(0);setFailed(false);
  },[setup?.id,setup?.page,retry]);
  useEffect(()=>{
    if(!setup||setup.page!==5)return;const deadline=setTimeout(()=>{if(!travel.current)setFailed(true);},8000);
    return()=>clearTimeout(deadline);
  },[setup?.id,setup?.page,retry]);
  useEffect(()=>{
    if(!setup||setup.page!==5||!frames||!sourceFrame)return;
    const now=animationNow();
    if(!travel.current){travel.current=new OnboardingTravel(sourceFrame,frames.mascot,now);travelStart.current=now;setFailed(false);}
    else travel.current.retarget(frames.mascot,now);
  },[setup?.id,setup?.page,frames,sourceFrame,retry]);
  useEffect(()=>{
    if(!setup||setup.page!==5)return;let active=true,request=0;
    const tick=()=>{
      if(!active||AppState.currentState!=='active')return;const now=animationNow();
      const phaseCommand=(type:'onboarding.ready'|'onboarding.release'|'onboarding.complete')=>phaseCommands.current.send(`${setup.id}:${setup.phase}:${retry}:${live?.security.readRevision}:${type}`,now,()=>command({type,id:setup.id},true));
      if(travelStart.current!==undefined){const t=now-travelStart.current;setElapsed(t);if(t>=1.74&&setup.phase==='arriving'&&frames)phaseCommand('onboarding.ready');}
      if(setup.phase==='opening'){
        openStart.current??=now;const t=now-openStart.current;setOpeningElapsed(t);
        if(t>=.84)phaseCommand('onboarding.release');
      }
      if(setup.phase==='released'&&openStart.current!==undefined&&now-openStart.current>=(setup.mock?2.92:.92))phaseCommand('onboarding.complete');
      request=requestAnimationFrame(tick);
    };
    tick();const lifecycle=AppState.addEventListener('change',value=>{cancelAnimationFrame(request);if(value==='active')tick();});
    return()=>{active=false;cancelAnimationFrame(request);lifecycle.remove();};
  },[setup?.id,setup?.page,setup?.phase,frames,retry,live?.security.readRevision]);
  const close=()=>{if(setup?.mock)void command({type:'onboarding.dismiss',id:setup.id});};
  const landscape=size.width>size.height;
  const sourceInset=landscape&&size.height<foundation.layout.expandedSceneMinHeight?128:0;
  useToolbar({title:setup&&landscape?onboardingPageTitle(setup.page):'',headerTitleStyle:landscape&&setup?.page===0?{color:'white'}:undefined,headerBackVisible:false,
    unstable_headerLeftItems:()=>setup?.history.length&&!['opening','released'].includes(setup.phase)?[toolbarButton('Back','chevron.left',()=>void command({type:'onboarding.back',id:setup.id}),!!setup.busy)]:[],
    unstable_headerRightItems:()=>setup?.mock?[toolbarButton('Close','xmark',close,!!setup.busy)]:[]},[setup?.id,setup?.page,setup?.history.length,setup?.busy,setup?.phase,landscape]);
  if(!setup)return null;
  const busy=!!setup.busy||['opening','released'].includes(setup.phase);const opening=setup.phase==='opening'||setup.phase==='released';
  const position=setup.page===5&&travel.current?travel.current.position(animationNow()):sourceFrame?{x:sourceFrame.x+sourceFrame.width/2,y:sourceFrame.y+sourceFrame.height/2}:undefined;
  if(setup.page===5&&position)previousPosition.current=position;
  const contentHeight=Math.max(0,size.height-header-insets.bottom);
  const mascotState=opening?'sleeping':setup.page===2&&(!setup.vpnInstalled||setup.busy==='vpn')?'sleeping':permissionSmile||setup.page===5&&elapsed<1.09?'grateful':'awake';
  const reveal=setup.page===5&&travel.current?easeInOut(Math.min(1,Math.max(0,(elapsed-1.19)/.55))):0;
  const surroundings=opening?1-easeInOut(Math.min(1,openingElapsed/.7)):1;
  const navigate=(page:number,revisit=false)=>void command({type:'onboarding.navigate',id:setup.id,page,revisit});
  return <View testID="onboarding.flow.viewport" onLayout={onLayout} style={{flex:1}}><View pointerEvents="none" style={[StyleSheet.absoluteFill,{opacity:surroundings}]}><OnboardingBackground width={size.width} height={size.height} frames={frames} reveal={reveal}/></View>
    <Animated.View pointerEvents="none" style={[StyleSheet.absoluteFill,{opacity:backdrop}]}><OnboardingLavaDrawing width={size.width} height={size.height} active={setup.page===0}/></Animated.View>
    <OnboardingCurtain key={setup.id} welcome={setup.page===0} width={size.width} height={size.height} reduced={reduced} crossFade={crossFade} opacity={reduced||crossFade?backdrop:1} returnProgress={returningWelcome?backdrop:undefined} wavesActive={!returningWelcome||returnSettled} onReturnReady={()=>{if(paintVisit.current.generation===returnGeneration)setReadyReturn(returnGeneration);}}/>
    <OnboardingControls setup={setup} busy={busy} bottom={insets.bottom} left={insets.left} right={insets.right} compact={sourceInset>0} reduced={reduced} crossFade={crossFade} welcomeReturn={returningWelcome?backdrop:undefined} returnSettled={returnSettled} onPage={page=>navigate(page,true)} onNext={()=>navigate(setup.page+1)}>
      {(progress,footer)=><View style={{flex:1,paddingTop:header}}><OnboardingStageLayout source={source} progress={progress} width={size.width} height={size.height} left={insets.left} right={insets.right} welcome={setup.page===0}>
        <OnboardingPages setup={setup} command={command} height={contentHeight} reduced={reduced} crossFade={crossFade} landscape={landscape} sourceInset={sourceInset} welcomeReturn={returningWelcome?backdrop:undefined} returnSettled={returnSettled}/>
        {failed&&<View style={[StyleSheet.absoluteFill,{padding:24,gap:16}]}><Copy role="supporting">Guard is still loading. Please try again.</Copy><LavaActionButton title="Try again" role="secondary" onPress={()=>setRetry(value=>value+1)}/></View>}
      </OnboardingStageLayout>{footer}</View>}
    </OnboardingControls>
    {position&&<Animated.View pointerEvents="none" style={{position:'absolute',left:position.x-mascotSize/2,top:position.y-mascotSize/2,width:mascotSize,height:mascotSize,opacity:setup.phase==='released'?0:returningWelcome?backdrop.interpolate({inputRange:[0,1],outputRange:[1,0]}):mascotOpacity,transform:returnOffset.getTranslateTransform()}}>
      <GuardianDrawing size={mascotSize} look={look} mood={mascotState} blinkTrigger={blink.current} finishTrigger={opening?1:0} keepsColorWhenSleeping={!opening}/>
      <View accessible={false} testID="onboarding.mascot" style={StyleSheet.absoluteFill}/>
    </Animated.View>}
    {setup.page===5&&reveal>=1&&frames&&<><View pointerEvents="none" accessible accessibilityLabel={localized('Ready')} accessibilityValue={{text:localized('Your next step to a safer internet.')}} testID="onboarding.ready" style={{position:'absolute',left:frames.panel.x,top:frames.panel.y,width:frames.panel.width,height:frames.panel.height}}/>
      <Pressable accessibilityRole="button" accessibilityLabel={localized('Open Guard')} testID="onboarding.primary" disabled={busy||setup.phase!=='ready'} onPress={()=>void command({type:'onboarding.open',id:setup.id})} style={{position:'absolute',left:frames.action.x,top:frames.action.y,width:frames.action.width,height:frames.action.height}}/></>}
  </View>;
}
function OnboardingControls({setup,busy,bottom,left,right,compact,reduced,crossFade,welcomeReturn,returnSettled,onPage,onNext,children}:{setup:OnboardingSetup;busy:boolean;bottom:number;left:number;right:number;compact:boolean;reduced:boolean;crossFade:boolean;welcomeReturn?:Animated.Value;returnSettled:boolean;onPage:(page:number)=>void;onNext:()=>void;children:(progress:ReactNode,footer:ReactNode)=>ReactNode}){
  const retained=useRef(setup);if(setup.page<5)retained.current=setup;
  const done=setup.page===5;const [removed,setRemoved]=useState(done);const [height,setHeight]=useState(0);
  const opacity=useRef(new Animated.Value(done?0:1)).current;
  const visible=done?retained.current:setup;
  const transition=useRef({page:visible.page,welcome:visible.page===0,previous:undefined as number|undefined});if(transition.current.page!==visible.page)transition.current={page:visible.page,welcome:transition.current.page===0,previous:transition.current.page};
  const welcomeTransition=transition.current.welcome;
  useLayoutEffect(()=>{
    if(!done)setRemoved(false);
    const motion=Animated.timing(opacity,{toValue:done?0:1,duration:reduced||crossFade?200:320,easing:reduced||crossFade?easeInOut:Easing.bezier(0,0,.58,1),useNativeDriver:true});
    motion.start(({finished})=>{if(finished&&done)setRemoved(true);});return()=>motion.stop();
  },[done,reduced,crossFade]);
  if(done&&removed)return children(null,<View accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{height}}/>);
  // One interactive progress group belongs to either scaffold slot. On Back,
  // the retired slot fades as inaccessible paint on the same return clock.
  const belowSource=compact&&visible.page>0;
  const progress=<OnboardingProgress page={visible.page} visited={visible.visited} busy={busy||done} vpnInstalled={visible.vpnInstalled} onPage={onPage} duration={welcomeTransition?(reduced?250:1100):reduced||crossFade?200:320} smooth={welcomeTransition||reduced||crossFade}/>;
  const sourceProgress=belowSource?<Animated.View pointerEvents={done?'none':'auto'} accessibilityElementsHidden={done} importantForAccessibility={done?'no-hide-descendants':'auto'} style={{opacity}}>{progress}</Animated.View>
    :compact&&welcomeReturn&&!returnSettled?<Animated.View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{opacity:welcomeReturn.interpolate({inputRange:[0,1],outputRange:[1,0]})}}><OnboardingProgress page={transition.current.previous??1} visited={visible.visited} busy vpnInstalled={visible.vpnInstalled} onPage={onPage} duration={0} smooth={false}/></Animated.View>:null;
  const footer=<Animated.View onLayout={event=>setHeight(event.nativeEvent.layout.height)} pointerEvents={done?'none':'auto'} accessibilityElementsHidden={done} importantForAccessibility={done?'no-hide-descendants':'auto'} style={{opacity}}>
    <OnboardingFooter page={visible.page} busy={busy||done} vpnInstalled={visible.vpnInstalled} bottom={bottom} left={left} right={right} progress={belowSource?null:welcomeReturn?<Animated.View style={{opacity:welcomeReturn}}>{progress}</Animated.View>:progress} outlineTransitionDuration={welcomeTransition?(reduced?250:1100):reduced||crossFade?200:320} onNext={onNext}/>
  </Animated.View>;
  return children(sourceProgress,footer);
}
export function OnboardingPages({setup,command,height,reduced,crossFade,landscape=false,sourceInset=0,welcomeReturn,returnSettled=false}:{setup:OnboardingSetup;command:(action:AppCommand,quiet?:boolean)=>Promise<unknown>;height:number;reduced:boolean;crossFade:boolean;landscape?:boolean;sourceInset?:number;welcomeReturn?:Animated.Value;returnSettled?:boolean}){
  const current=useRef(setup);const [outgoing,setOutgoing]=useState<OnboardingSetup>();
  if(current.current.page!==setup.page){setOutgoing(current.current);current.current=setup;}
  else current.current=setup;
  const movement=useRef(new Animated.Value(0)).current;
  useLayoutEffect(()=>{
    if(!outgoing)return;
    if(setup.page===0&&welcomeReturn){if(returnSettled)setOutgoing(previous=>previous===outgoing?undefined:previous);return;}
    movement.setValue(0);
    let active=true;const transition=onboardingPageMotion(outgoing.page,setup.page,reduced,crossFade);
    const motion=Animated.timing(movement,{toValue:1,duration:transition.exitDuration,easing:transition.exitSmooth?easeInOut:Easing.bezier(0,0,.58,1),useNativeDriver:true});
    motion.start(({finished})=>{if(active&&finished)setOutgoing(previous=>previous===outgoing?undefined:previous);});return()=>{active=false;motion.stop();};
  },[outgoing,reduced,crossFade,welcomeReturn,returnSettled]);
  return <View style={{flex:1}}><OnboardingStage key={setup.page} page={setup.page} previousPage={outgoing?.page} reduced={reduced} crossFade={crossFade} inset={setup.page===0?0:sourceInset} welcomeReturn={setup.page===0?welcomeReturn:undefined}>
    <OnboardingPageScroll welcome={setup.page===0} landscape={landscape}><OnboardingPageBody setup={setup} command={command} showTitle={!landscape}/></OnboardingPageScroll>
  </OnboardingStage>{outgoing&&<Animated.View testID="onboarding.page.outgoing" pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[StyleSheet.absoluteFill,
    {marginLeft:outgoing.page===0?0:sourceInset},outgoing.page===0&&!reduced?{transform:[{translateY:movement.interpolate({inputRange:[0,1],outputRange:[0,height*1.1]})}]}:{opacity:(setup.page===0&&welcomeReturn?welcomeReturn:movement).interpolate({inputRange:[0,1],outputRange:[1,0]})}]}>
    <OnboardingPageScroll welcome={outgoing.page===0} landscape={landscape}><OnboardingPageBody setup={outgoing} command={command} showTitle={!landscape}/></OnboardingPageScroll>
  </Animated.View>}</View>;
}
function OnboardingStage({page,previousPage,reduced,crossFade,inset,welcomeReturn,children}:{page:number;previousPage?:number;reduced:boolean;crossFade:boolean;inset:number;welcomeReturn?:Animated.Value;children:ReactNode}){
  const opacity=useRef(new Animated.Value(page===0?1:0)).current;
  useLayoutEffect(()=>{if(page===0)return;const transition=onboardingPageMotion(previousPage,page,reduced,crossFade);const motion=Animated.timing(opacity,{toValue:1,duration:transition.entryDuration,delay:transition.entryDelay,easing:transition.entrySmooth?easeInOut:Easing.bezier(0,0,.58,1),useNativeDriver:true});motion.start();return()=>motion.stop();},[]);
  return <Animated.View style={{flex:1,marginLeft:inset,opacity:welcomeReturn??opacity}}>{children}</Animated.View>;
}
function OnboardingPageBody({setup,command,showTitle}:{setup:OnboardingSetup;command:(action:AppCommand,quiet?:boolean)=>Promise<unknown>;showTitle:boolean}){
  const busy=!!setup.busy;const change=(choice:Omit<Extract<AppCommand,{type:'onboarding.choice'}>,'type'|'id'>)=>void command({type:'onboarding.choice',id:setup.id,...choice});
  if(setup.page===5)return null;
  if(setup.page===0)return <OnboardingWelcome showTitle={showTitle}/>;
  if(setup.page===1)return <OnboardingStep title={onboardingPageTitle(1)} showTitle={showTitle}><OnboardingFeature symbol="shield" title="Lava blocks your device's access to malicious domains"/><OnboardingFeature symbol="lock" title="Local filter makes it safe, private and free"/><OnboardingFeature symbol="slider.horizontal.3" title="You're in full control of what gets logged locally"/></OnboardingStep>;
  if(setup.page===2)return <OnboardingStep title={onboardingPageTitle(2)} showTitle={showTitle}>
    <OnboardingChoice title={setup.vpnInstalled?'VPN installed':'Install local VPN'} symbol="shield" selected={setup.vpnInstalled} busy={setup.busy==='vpn'} disabled={busy||setup.vpnInstalled} testID="onboarding.install-vpn" onPress={setup.vpnInstalled?undefined:()=>void command({type:'onboarding.vpn',id:setup.id})}/>
    <OnboardingChoice title={setup.notifications?'Notifications enabled (optional)':'Enable notifications (optional)'} symbol="bell" selected={setup.notifications} busy={setup.busy==='notifications'} disabled={busy||setup.notifications} testID="onboarding.notifications" onPress={setup.notifications?undefined:()=>void command({type:'onboarding.notifications',id:setup.id})}/>
    {!!setup.error&&<Copy verbatim role="supporting">{setup.error}</Copy>}
  </OnboardingStep>;
  if(setup.page===3)return <OnboardingStep title={onboardingPageTitle(3)} showTitle={showTitle}><View style={{gap:16}}>{([
    ['essential','Core','🌱','Blocks malicious sites: phishing, scams, and malware.'],['balanced','Balanced','🪴','Adds spam, fraud, and abuse coverage. Best for most.'],['comprehensive','Extra','💐','Adds ads and trackers. May break some sites.'],
  ] as const).map(([level,title,emoji,summary])=><OnboardingChoice key={level} title={title} emoji={emoji} summary={summary} selected={setup.level===level} disabled={busy} testID={`onboarding.filter.${level}`} onPress={()=>change({level})}/>)}</View></OnboardingStep>;
  return <OnboardingStep title={onboardingPageTitle(4)} showTitle={showTitle} description="Change these anytime in Settings."><View style={{gap:16}}>
    <OnboardingChoice title="Keep connections working" summary="Try a backup DNS service when websites won't load. The default is Quad9" symbol="network" selected={setup.fallback} disabled={busy} testID="onboarding.dns-fallback" onPress={()=>change({fallback:!setup.fallback})}/>
    {setup.supportsDNSProfile&&<OnboardingChoice title="Set up DNS profile" summary="This helps Lava work well in iOS 27 with Connectivity Assist. Follow the orange dots for complete setups" symbol="doc.text" selected={setup.dnsProfile} disabled={busy} testID="onboarding.dns-profile" onPress={()=>change({dnsProfile:!setup.dnsProfile})}/>}
  </View>{!!setup.error&&<><Copy verbatim role="supporting">{setup.error}</Copy><LavaActionButton title="Set up later" role="secondary" onPress={()=>void command({type:'onboarding.navigate',id:setup.id,page:5,skipFailedDNSProfile:true})}/></>}</OnboardingStep>;
}
