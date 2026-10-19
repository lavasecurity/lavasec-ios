import {useEffect,useRef,useState,type ReactNode} from 'react';
import {Animated,Easing,Pressable,ScrollView,StyleSheet,View,type ColorValue,type TextStyle} from 'react-native';
import {LavaActionButton} from '../../index';
import {animationNow} from '../../animation-clock';
import {PreparationProgressMotion,type PreparationFrame} from './motion';
import type {PreparationCommandPort,PreparationCopy,PreparationSnapshot} from './contract';

export type PreparationTextProps={children:string;kind:'title'|'supporting'|'previous'|'quiet';style?:TextStyle;header?:boolean;testID?:string;numberOfLines?:number;adjustsFontSizeToFit?:boolean;minimumFontScale?:number};
export type PreparationScreenProps={
  snapshot:PreparationSnapshot;
  port:PreparationCommandPort;
  copy:PreparationCopy;
  active:boolean;
  reduceMotion:boolean;
  guardian:ReactNode;
  successGlyph:ReactNode;
  failureGlyph:ReactNode;
  renderText:(props:PreparationTextProps)=>ReactNode;
  background:ColorValue;
  progressColor:ColorValue;
  progressTrack:ColorValue;
};

/** The title retains its incidental upward transition. Only the determinate
 * bar has the preparation PRD's exception to the accessibility motion policy. */
function PreparationTitle({title,reduceMotion,renderText,testID='preparation.title'}:{title:string;reduceMotion:boolean;renderText:PreparationScreenProps['renderText'];testID?:string}){
  const [displayed,setDisplayed]=useState(title);
  const opacity=useRef(new Animated.Value(1)).current;
  const offset=useRef(new Animated.Value(0)).current;
  const generation=useRef(0);
  useEffect(()=>{
    const epoch=++generation.current;
    if(displayed===title)return;
    const animation=Animated.parallel([
      Animated.timing(opacity,{toValue:0,duration:reduceMotion?80:140,easing:Easing.bezier(.42,0,1,1),useNativeDriver:true}),
      Animated.timing(offset,{toValue:reduceMotion?0:-18,duration:reduceMotion?80:140,easing:Easing.bezier(.42,0,1,1),useNativeDriver:true}),
    ]);
    animation.start(({finished})=>{
      if(!finished||generation.current!==epoch)return;
      setDisplayed(title);offset.setValue(reduceMotion?0:18);
      Animated.parallel([
        Animated.timing(opacity,{toValue:1,duration:reduceMotion?120:220,easing:Easing.bezier(0,0,.58,1),useNativeDriver:true}),
        Animated.timing(offset,{toValue:0,duration:reduceMotion?120:220,easing:Easing.bezier(0,0,.58,1),useNativeDriver:true}),
      ]).start();
    });
    return()=>{++generation.current;animation.stop();opacity.setValue(1);offset.setValue(0);};
  },[title,reduceMotion]);
  return <Animated.View style={[styles.title,{opacity,transform:[{translateY:offset}]}]}>
    {renderText({children:displayed,kind:'title',testID,numberOfLines:2,adjustsFontSizeToFit:true,minimumFontScale:.86})}
  </Animated.View>;
}

/** Shared app presentation consumes native snapshots and an admitted command
 * port. It has no model/store, authorization, navigation or haptic implementation. */
export function PreparationScreen(props:PreparationScreenProps){
  const {snapshot,port,copy,active,reduceMotion,renderText}=props;
  const motion=useRef(new PreparationProgressMotion());
  const [frame,setFrame]=useState<PreparationFrame>({progress:snapshot.state==='success' ? .75 : snapshot.progress,glyph:false,complete:false});
  const current=useRef({snapshot,active,port});current.current={snapshot,active,port};
  const sent=useRef<string|undefined>(undefined);const pending=useRef(false);const [busy,setBusy]=useState(false);
  const [laidOut,setLaidOut]=useState(false);
  const completionRequest=useRef(0);
  const [completionRevision,setCompletionRevision]=useState(0);
  const handoff=useRef<{startedAt?:number;pausedAt?:number;finished:boolean}>({finished:false});
  const [handoffProgress,setHandoffProgress]=useState(0);
  const [error,setError]=useState('');
  useEffect(()=>{
    pending.current=false;setBusy(false);setError('');sent.current=undefined;
    handoff.current={finished:false};setHandoffProgress(0);
  },[snapshot.id]);
  useEffect(()=>{
    motion.current.update(snapshot,animationNow()*1000);
    setFrame(motion.current.frame(animationNow()*1000));
  },[snapshot.id,snapshot.state,snapshot.progress]);
  useEffect(()=>{
    if(!active||!laidOut||snapshot.state!=='success')return;
    const id=snapshot.id;let mounted=true;let retry:ReturnType<typeof setTimeout>|undefined;
    const note=()=>{void port.send({type:'preparation.rendered',id}).catch(()=>{
      if(mounted&&current.current.active&&current.current.snapshot.id===id)retry=setTimeout(note,250);
    });};
    note();return()=>{mounted=false;if(retry!==undefined)clearTimeout(retry);};
  },[active,laidOut,snapshot.id,snapshot.state,port]);
  useEffect(()=>{
    const id=snapshot.id;let request=0;let mounted=true;
    const now=()=>animationNow()*1000;
    const pause=()=>{
      const timestamp=now();motion.current.pause(timestamp);
      if(handoff.current.startedAt!==undefined&&handoff.current.pausedAt===undefined)handoff.current.pausedAt=timestamp;
    };
    if(!active){pause();return;}
    const resumedAt=now();motion.current.resume(resumedAt);
    if(handoff.current.pausedAt!==undefined){
      if(handoff.current.startedAt!==undefined)handoff.current.startedAt+=resumedAt-handoff.current.pausedAt;
      handoff.current.pausedAt=undefined;
    }
    const tick=()=>{
      if(!mounted||current.current.snapshot.id!==id||!current.current.active)return;
      const timestamp=now();const next=motion.current.frame(timestamp);setFrame(next);
      if(!next.glyph){handoff.current={finished:false};setHandoffProgress(0);}
      else{
        handoff.current.startedAt??=timestamp;
        // Native's incidental handoff is instant under Reduce Motion. The
        // determinate fill retains its separately specified 550ms exception.
        const progress=handoff.current.finished||reduceMotion?1:successHandoffEase(Math.min(1,Math.max(0,(timestamp-handoff.current.startedAt)/250)));
        if(progress>=1)handoff.current.finished=true;
        setHandoffProgress(progress);
      }
      if(motion.current.needsFrame(timestamp))request=requestAnimationFrame(tick);
    };
    tick();return()=>{mounted=false;cancelAnimationFrame(request);pause();};
  },[snapshot.id,snapshot.state,snapshot.progress,active,reduceMotion]);
  useEffect(()=>{
    if(!active||snapshot.state!=='failed'&&!(snapshot.state==='success'&&frame.glyph))return;
    const id=snapshot.id;let mounted=true;let retry:ReturnType<typeof setTimeout>|undefined;
    const announce=()=>{void port.send({type:'preparation.announce',id}).catch(()=>{
      if(mounted&&current.current.active&&current.current.snapshot.id===id)retry=setTimeout(announce,250);
    });};
    announce();return()=>{mounted=false;if(retry!==undefined)clearTimeout(retry);};
  },[active,snapshot.id,snapshot.state,frame.glyph,port]);
  useEffect(()=>{
    const id=snapshot.id;
    if(!active||snapshot.state!=='success'||!frame.complete||sent.current===id)return;
    const request=++completionRequest.current;
    let mounted=true;let retry:ReturnType<typeof setTimeout>|undefined;
    void port.send({type:'preparation.presented',id}).then(()=>{
      if(current.current.snapshot.id===id)sent.current=id;
    }).catch(()=>{
      if(mounted&&completionRequest.current===request&&current.current.snapshot.id===id){
        retry=setTimeout(()=>{if(mounted)setCompletionRevision(value=>value+1);},250);
      }
    });
    return()=>{mounted=false;if(retry!==undefined)clearTimeout(retry);};
  },[active,snapshot.id,snapshot.state,frame.complete,port,completionRevision]);
  const send=async(type:'preparation.retry'|'preparation.editReturn'|'preparation.keepCurrent'|'preparation.upgrade')=>{
    if(pending.current||!current.current.active||snapshot.busy)return;
    const id=snapshot.id;pending.current=true;setBusy(true);setError('');
    try{await port.send({type,id});}
    catch(failure){if(current.current.snapshot.id===id&&current.current.active)setError((failure as Error).message);}
    finally{if(current.current.snapshot.id===id){pending.current=false;setBusy(false);}}
  };
  const disabled=busy||snapshot.busy||!active;
  const failure=snapshot.state==='failed';
  const success=snapshot.state==='success'&&frame.glyph;
  const retainsPreparing=!success||handoffProgress<1;
  return <ScrollView testID="preparation.screen" onLayout={event=>setLaidOut(event.nativeEvent.layout.width>0&&event.nativeEvent.layout.height>0)} style={[styles.screen,{backgroundColor:props.background}]}
    contentContainerStyle={styles.scroll} contentInsetAdjustmentBehavior="automatic" showsVerticalScrollIndicator={false}
    pointerEvents={active?'auto':'none'} accessibilityElementsHidden={!active} importantForAccessibility={active?'auto':'no-hide-descendants'}>
    <View style={styles.center}>
      {failure?<>
        <View accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">{props.failureGlyph}</View>
        <View style={styles.failureCopy}>
          {renderText({children:snapshot.title,kind:'title',header:true,testID:'preparation.failure.title'})}
          {renderText({children:snapshot.message,kind:'supporting'})}
          {renderText({children:copy.previousFilter,kind:'previous',style:{paddingTop:6}})}
        </View>
        <View style={styles.actions}>
          {snapshot.recovery.upgrade?<LavaActionButton testID="preparation.upgrade" title={copy.upgrade} disabled={disabled} onPress={()=>void send('preparation.upgrade')}/>
            :snapshot.recovery.retry?<LavaActionButton testID="preparation.retry" title={copy.retry} disabled={disabled} onPress={()=>void send('preparation.retry')}/>:null}
          {snapshot.recovery.editReturn&&<LavaActionButton testID="preparation.editReturn" role="secondary" title={snapshot.origin==='domainHistory'?copy.backToReview:copy.backToEdit} disabled={disabled} onPress={()=>void send('preparation.editReturn')}/>}
          {snapshot.recovery.keepCurrent&&<Pressable testID="preparation.keepCurrent" accessibilityRole="button" accessibilityState={{disabled}} disabled={disabled}
            onPress={()=>void send('preparation.keepCurrent')} style={styles.keepCurrent}>
            {renderText({children:copy.keepCurrent,kind:'quiet'})}
          </Pressable>}
          {!!error&&renderText({children:error,kind:'supporting'})}
        </View>
      </>:<>
        {retainsPreparing&&<View testID="preparation.preparing-stage" pointerEvents="none" accessibilityElementsHidden={success}
          importantForAccessibility={success?'no-hide-descendants':'auto'} style={[styles.stage,{opacity:success?1-handoffProgress:1}]}>
          <View accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants">{props.guardian}</View>
          <PreparationTitle title={snapshot.title} reduceMotion={reduceMotion} renderText={renderText} testID={success?'preparation.title.outgoing':'preparation.title'}/>
          {snapshot.state!=='idle'&&<View testID="preparation.progress" accessibilityRole="progressbar" accessibilityLabel={snapshot.title}
            accessibilityValue={{min:0,max:100,now:Math.round(snapshot.progress*100)}} style={[styles.progress,{backgroundColor:props.progressTrack}]}>
            <View testID="preparation.progress.fill" style={[styles.fill,{backgroundColor:props.progressColor,width:`${Math.max(0,Math.min(1,frame.progress))*100}%`}]}/>
          </View>}
        </View>}
        {/* Native crossfades two fixed, centered compositions. Keeping the old
            76+76+4pt group during the fade and the new 68+76pt group centered
            independently preserves the title's 10pt and hero's 14pt offsets. */}
        {success&&<View testID="preparation.success-stage" style={[styles.stage,retainsPreparing&&styles.successOverlay,{opacity:handoffProgress}]}>
          <View testID="preparation.success-slot" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={styles.successSlot}>{props.successGlyph}</View>
          <PreparationTitle title={snapshot.title} reduceMotion={reduceMotion} renderText={renderText}/>
        </View>}
      </>}
    </View>
  </ScrollView>;
}

const styles=StyleSheet.create({
  screen:{flex:1},scroll:{flexGrow:1,padding:24},center:{flexGrow:1,justifyContent:'center',alignItems:'center',gap:24},
  stage:{width:'100%',alignItems:'center',gap:24},
  successOverlay:{position:'absolute',top:0,right:0,bottom:0,left:0,justifyContent:'center'},
  successSlot:{width:68,height:68,alignItems:'center',justifyContent:'center'},
  title:{minHeight:76,maxWidth:340,width:'100%',justifyContent:'center'},
  progress:{width:'100%',maxWidth:280,height:4,borderRadius:2,overflow:'hidden'},fill:{height:4,borderRadius:2},
  failureCopy:{alignSelf:'stretch',gap:10},actions:{alignSelf:'center',width:'100%',maxWidth:320,gap:10},
  keepCurrent:{height:46,paddingTop:2,justifyContent:'center',alignItems:'center'},
});

const successHandoffEase=Easing.bezier(.42,0,.58,1);
