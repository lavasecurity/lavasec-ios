import {useEffect,useMemo,useRef,useState,useSyncExternalStore} from 'react';
import {AppState,PlatformColor,StyleSheet,View} from 'react-native';
import {Text,localized} from '../app/presentation';
import {domainReviewPrivacyScope,mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationAuthority,usePresentationReadiness} from '../app/use-presentation-readiness';
import {useReview} from './ReviewContext';
import {PresentationCover} from './PresentationCover';
import {Symbol} from './primitives';
import {useReducedMotionPreference} from './navigation-scaffold';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {preparationFlowStyles as styles,preparationTextAppearance} from '../src/flows/preparation/appearance';
import {PreparationGuardian} from '../src/flows/preparation/PreparationGuardian';
import {PreparationScreen,type PreparationTextProps} from '../src/flows/preparation/PreparationScreen';
import type {PreparationCommandPort} from '../src/flows/preparation/contract';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';

const noSubscribe=()=>()=>{};
function PreparationText({children,kind,style,header,testID,numberOfLines,adjustsFontSizeToFit,minimumFontScale}:PreparationTextProps){
  const appearance=preparationTextAppearance(kind);
  // The original native cover uses semantic fonts at every window size. Keep
  // Dynamic Type, without the ordinary RN page's additional tablet expansion.
  return <Text verbatim responsive={false} testID={testID} accessibilityRole={header?'header':undefined} allowFontScaling dynamicTypeRamp={appearance.ramp}
    numberOfLines={numberOfLines} adjustsFontSizeToFit={adjustsFontSizeToFit} minimumFontScale={minimumFontScale}
    style={[appearance.style,kind==='title'&&{color:PlatformColor('label')},style]}>{children}</Text>;
}

/** iOS app/security binding. The shared renderer only receives admitted props. */
export function PreparationFlow({id}:{id:string}){
  return <NativeFlowMetrics><PreparationFlowBody id={id}/></NativeFlowMetrics>;
}
function PreparationFlowBody({id}:{id:string}){
  const {app,live}=useReview();
  const projection=live?.preparation?.id===id?live.preparation:undefined;
  const retained=useRef(projection);if(projection)retained.current=projection;
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  const [entryError,setEntryError]=useState('');
  const entering=useRef(false);
  const authority=usePresentationAuthority(app);
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>!!app&&mayInteractWithPresentation(app));
  const scope=JSON.stringify([id,live?domainReviewPrivacyScope(live):null]);
  usePresentationReadiness(app,!!app,!!projection||!!entryError,scope);
  const reduceMotion=useReducedMotionPreference();
  useEffect(()=>{const listener=AppState.addEventListener('change',state=>setForeground(state==='active'));return()=>listener.remove();},[]);
  const port=useMemo<PreparationCommandPort>(()=>({send:async command=>{
    const current=app?.getSnapshot?.().snapshot;
    if(!app||command.id!==id||AppState.currentState!=='active'||!mayInteractWithPresentation(app)
      ||current?.preparation?.id!==id)throw new Error('Read access changed.');
    return app.command(command);
  }}),[app,id]);
  const enter=async()=>{
    if(!app||entering.current||!foreground||!authority)return;
    entering.current=true;setEntryError('');
    try{await app.command({type:'preparation.enter',id});}
    catch(error){setEntryError((error as Error).message);}
    finally{entering.current=false;}
  };
  useEffect(()=>{if(!projection&&!entryError)void enter();},[app,id,!!projection,foreground,authority,live?.security.readRevision]);
  const active=!!projection&&authority&&foreground&&interactive;
  const snapshot=projection??retained.current;
  return <View style={styles.root}>
    {snapshot&&<View style={[styles.root,{opacity:projection?1:0}]} pointerEvents={active?'auto':'none'} accessibilityElementsHidden={!active}>
      <PreparationScreen key={id} snapshot={snapshot} port={port} active={active} reduceMotion={reduceMotion}
        copy={{previousFilter:localized('Your previous filter is still active.'),retry:localized('Try Again'),upgrade:localized('Upgrade'),
          keepCurrent:localized('Keep Current Filter'),backToEdit:localized('Back to Edit'),backToReview:localized('Back to Review')}}
        renderText={props=><PreparationText {...props}/>}
        guardian={<PreparationGuardian look={live?.look??'original'} active={active}/>}
        successGlyph={<Symbol name="checkmark.circle.fill" size={68} pointSize={56} weight="bold" tone="green" responsive={false}/>}
        failureGlyph={<Symbol name="exclamationmark.triangle.fill" size={70} height={191/3} pointSize={56} weight="bold" tone="orange" responsive={false}/>}
        background={colors.groupedBackground} progressColor={colors.safeGreen} progressTrack={PlatformColor('systemFill')}/>
    </View>}
    {!projection&&<View style={StyleSheet.absoluteFill}><PresentationCover testID="preparation.privacy-cover">
      {!!entryError&&entryError!=='Authentication cancelled.'&&<PreparationText kind="supporting">{entryError}</PreparationText>}
      <LavaActionButton title="Unlock Lava" role="secondary" onPress={()=>void enter()}/>
    </PresentationCover></View>}
  </View>;
}
