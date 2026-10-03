import {DNSEditorProvider} from './dns-editor';
import type {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import {createContext, useContext, useMemo, useEffect, useState, useSyncExternalStore, type ComponentType, type ReactNode} from 'react';
import {View} from 'react-native';
import {FeedbackProvider} from '../src/feedback';
import type {AppearanceStore} from './appearance-store';
import {initialPreviewDraft, type PreviewDraft} from './preview-model';
import {initialSession, type PreviewSession} from './session';
import {PresentationCover} from './PresentationCover';
import {presentationOwnerScope} from '../app/read-cache';

export type ReviewState = {
  app?: AppStore;
  onboardingPreview?:boolean;
  live?: AppSnapshot;
  appearance: AppearanceStore;
  look: string;
  setLook: (look: string) => void;
  draft: PreviewDraft;
  setDraft: (draft: PreviewDraft) => void;
  session: PreviewSession;
  setSession: (session: PreviewSession) => void | Promise<void>;
  savedDraft: PreviewDraft;
  setSavedDraft: (draft: PreviewDraft) => void;
  activityExample?: boolean;
  reviewGallery?: boolean;
};
const context = createContext<ReviewState | null>(null);
function Provider({value,children}:{value:ReviewState|null;children:ReactNode}) {
  const feedback=useMemo(()=>({emit:(event:import('../src/feedback').FeedbackEvent)=>{
    if(value?.app) void value.app.command({type:'haptic',kind:event.semantic,controlID:event.controlID,value:event.value}).catch(()=>{});
  }}),[value?.app]);
  return <DNSEditorProvider retirementKey={value?.app?(value.live?presentationOwnerScope(value.live):'revoked'):undefined}
    available={!value?.app||!!value.live}><context.Provider value={value}><FeedbackProvider value={feedback}>{children}</FeedbackProvider></context.Provider></DNSEditorProvider>;
}
export const ReviewContext = {...context,Provider};
export function useReview() {
  const state = useContext(context);
  if (!state) throw new Error('Review screen must be inside its isolated review provider.');
  return state;
}

/** Shared native scaffolds also support standalone review fixtures. */
export function useOptionalReview(){return useContext(context);}

/** Private route bodies can be discarded without replacing their native screen or navigator. */
export function LiveRenderBoundary({component: Component}: {component: ComponentType}) {
  const {app,live}=useReview();
  const required=useSyncExternalStore(app?.subscribe??(()=>()=>{}),()=>!!app?.getPresentationHydration?.().required);
  const coverRequired=app?.getSnapshot?.()?.privacyCoverRequired!==false;
  const concealed=!!app&&coverRequired&&(!live||required);
  if(app&&!live)return <View style={{flex:1}}>{concealed&&<PresentationCover testID="lava-route-privacy-cover"/>}</View>;
  // Native-confirmed all-off may retain already-painted values through inactive
  // and resume frames. Query authority still revokes on inactivity; policy or
  // data-scope changes discard values. Keep
  // the screen's native scroll/form identity through ordinary navigation and
  // settings updates; loss of the live snapshot above disposes its whole body.
  // UIKit presents sheets in a separate controller above the root frame. Keep
  // its ScrollView direct and add the opaque cover as a sibling in that route.
  return <><Component/>{concealed&&<View style={{position:'absolute',top:0,bottom:0,left:0,right:0,zIndex:1}}><PresentationCover testID="lava-route-privacy-cover"/></View>}</>;
}

/** The isolated gallery may edit fixtures; a production callback must never copy native data here. */
export function usePreviewFixtureState(enabled: boolean) {
  const [draft,setDraft]=useState(initialPreviewDraft);
  const [savedDraft,setSavedDraft]=useState(initialPreviewDraft);
  const [session,setSession]=useState(initialSession);
  useEffect(()=>{if(!enabled){setDraft(initialPreviewDraft());setSavedDraft(initialPreviewDraft());setSession(initialSession());}},[enabled]);
  return {
    draft:enabled?draft:initialPreviewDraft(),savedDraft:enabled?savedDraft:initialPreviewDraft(),session:enabled?session:initialSession(),
    setDraft:(value:PreviewDraft)=>{if(enabled)setDraft(value);},
    setSavedDraft:(value:PreviewDraft)=>{if(enabled)setSavedDraft(value);},
    setSession:(value:PreviewSession)=>{if(enabled)setSession(value);},
  };
}
