import {useLayoutEffect,useSyncExternalStore} from 'react';
import {AppState,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {DeviceQAScreen} from '../review/NativePageScreen';
import {ForegroundFlowScreen} from '../review/ForegroundFlowScreen';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';

// The foreground wrapper is real; the unrelated passcode owner has its own runtime suite.
jest.mock('../review/PasscodeFlowAdapter.ios',()=>({PasscodeFlowAdapter:()=>null}));
const mockGoBack=jest.fn();
const mockSetOptions=jest.fn();
jest.mock('@react-navigation/native',()=>({
  useRoute:()=>({params:{id:'qa-flow'}}),useNavigation:()=>({goBack:mockGoBack,setOptions:mockSetOptions}),useIsFocused:()=>true,
  NavigationIndependentTree:({children}:any)=>children,NavigationContainer:({children}:any)=>children,
  DefaultTheme:{},DarkTheme:{},usePreventRemove:jest.fn(),
  useNavigationContainerRef:()=>({isReady:()=>false}),
}));
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>({Navigator:({children}:any)=>children,Screen:({children}:any)=>typeof children==='function'?children():children})}));

jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaQAConfigurationNativeComponent',()=>{
  const React=require('react');const {TextInput,View}=require('react-native');
  // UIKit/SwiftUI owns this unpublished configuration buffer. Its identity is
  // intentionally opaque to DeviceQAScreen, just like PhoneQAView's @State.
  return {__esModule:true,default:(props:object)=>{
    const [draft,setDraft]=React.useState('');
    const {testID,...rest}=props as any;
    return React.createElement(View,rest,React.createElement(TextInput,{
      testID:'qa-native-configuration',value:draft,onChangeText:setDraft,
    }));
  }};
});

function harness({rootLayout=true,foreground=false,privacy=true,deferDetailClose=false}:{rootLayout?:boolean;foreground?:boolean;privacy?:boolean;deferDetailClose?:boolean}={}){
  const previous=AppState.currentState,originalListener=AppState.addEventListener;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);
    return {remove:()=>{listeners.delete(callback);}};
  };
  const emitState=(state:AppStateStatus)=>act(()=>{
    Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
    listeners.forEach(listener=>listener(state));
  });
  let current={schema:1,fullApp:true,revision:1,qaTools:true,backgroundPrivacyCoverRequired:privacy,appPrivacyCoverRequired:privacy,
    ...(foreground?{foregroundFlow:{id:'qa-flow',kind:'phoneQASheet',name:'',emoji:'🌿',dismissAttempt:0,canCreate:false,templates:[]}}:{}),
    security:{ownerRevision:'qa-owner',readRevision:1},session:initialSession(),
  } as unknown as AppSnapshot;
  let publish!:(value:string)=>void;
  let entryFailure='';
  let releaseDetailClose=()=>{};
  const detailClose=deferDetailClose?new Promise<void>(resolve=>{releaseDetailClose=resolve;}):undefined;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),
    command:jest.fn(async(request:string)=>{
      const command=JSON.parse(request);
      if(command.type==='qa.command'&&command.action==='enter'&&!current.qa){
        if(entryFailure){const message=entryFailure;entryFailure='';throw new Error(message);}
        current={...current,revision:current.revision+1,qa:{id:command.id,search:'',sections:[],formsVisible:true,hasConfiguration:false,staging:false,probeSuffix:'',canaryIP:'',hasResult:false}};
      }
      if(command.type==='qa.command'&&command.action==='leave'&&current.qa?.id===command.id){current={...current,qa:null};}
      const qa=current.qa;
      if(command.type==='qa.command'&&command.action==='detail.close'&&qa&&qa.id===command.id&&qa.detail?.id===command.detail){
        if(detailClose)await detailClose;
        current={...current,qa:{...qa,detail:undefined}};
      }
      return JSON.stringify({snapshot:current,result:null});
    }),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},
  } as unknown as Spec;
  const app=new AppStore(native,current,{initial:true}),disconnect=app.connect();
  function Provider(){
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    const gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    const live=state.snapshot??undefined;
    useLayoutEffect(()=>{if(live&&rootLayout)app.completePresentationLayout(gate.epoch);},[live,gate.epoch]);
    return <ReviewContext.Provider value={{app,live,session:live?.session??initialSession()} as ReviewState}>
      {foreground?<ForegroundFlowScreen/>:<LiveRenderBoundary component={DeviceQAScreen} directScrollRoot/>}
    </ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  return {app,view,emitState,nativeCommand:native.command,releaseDetailClose,failNextEntry:(message:string)=>{entryFailure=message;},async project(change:Partial<AppSnapshot>){
    current={...current,...change,revision:current.revision+1};
    await act(async()=>publish(JSON.stringify(current)));
  },close(){
    releaseDetailClose();
    view.unmount();act(()=>disconnect());AppState.addEventListener=originalListener;
    Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});
  }};
}

const viewport=(width=390,height=844)=>({nativeEvent:{layout:{x:0,y:0,width,height}}});
async function measureQA(width=390,height=844){
  await act(async()=>{});
  await act(async()=>fireEvent(screen.getByTestId('device-qa-page',{includeHiddenElements:true}),'layout',viewport(width,height)));
}

test('cold Device QA stays covered after the root layout until its focused native viewport is nonzero',async()=>{
  const {app,close}=harness();
  try{
    await act(async()=>{});
    await act(async()=>{});
    expect(app.getPresentationHydration().required).toBe(true);
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    const host=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    await measureQA(390,0);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA(0,844);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.getByTestId('device-qa-page')).toBe(host);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
  }finally{close();}
});

test('availability loss retires an unmeasured Device QA ticket without stranding the root cover',async()=>{
  const {app,project,close}=harness();
  try{
    await act(async()=>{});
    await act(async()=>{});
    expect(app.getPresentationHydration().required).toBe(true);
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    expect(app.getPresentationHydration().required).toBe(false);
  }finally{close();}
});

test('Device QA reenablement admits a fresh host whose own viewport must satisfy pending readiness',async()=>{
  const {app,project,close}=harness({rootLayout:false});
  try{
    await act(async()=>{});
    const first=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    const oldLayout=first.props.onLayout;
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    await project({qaTools:true});
    const next=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    expect(next).not.toBe(first);
    await act(async()=>app.completePresentationLayout(app.getPresentationHydration().epoch));
    await act(async()=>oldLayout(viewport()));
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA(390,0);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('device-qa-page')).toBe(next);
  }finally{close();}
});

test('a QA sheet replaces the pushed Device QA visit and return mounts a fresh page',async()=>{
  const {app,emitState,project,nativeCommand,close}=harness();
  try{
    await act(async()=>{});
    const first=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    const commands=()=>((nativeCommand as jest.Mock).mock.calls as string[][])
      .map(([request])=>JSON.parse(request!) as {type:string;action:string;id:string});
    const oldID=commands().find(command=>command.type==='qa.command'&&command.action==='enter')?.id;
    expect(oldID).toBeTruthy();
    await project({qa:null,foregroundFlow:{id:'qa-sheet',kind:'phoneQASheet',name:'',emoji:'🌿',dismissAttempt:0,canCreate:false,templates:[]}});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    expect(commands()).toContainEqual({type:'qa.command',id:oldID,action:'leave'});
    await project({qa:{id:'qa-sheet',search:'',sections:[],formsVisible:true,hasConfiguration:false,staging:false,probeSuffix:'',canaryIP:'',hasResult:false},foregroundFlow:{id:'feedback',kind:'feedback',name:'',emoji:'🌿',dismissAttempt:0,canCreate:false,templates:[]} as AppSnapshot['foregroundFlow']});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    emitState('background');
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    emitState('active');
    await project({qa:null,foregroundFlow:null});
    await act(async()=>{});
    const next=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    expect(next).not.toBe(first);
    const entries=commands().filter(command=>command.type==='qa.command'&&command.action==='enter');
    expect(entries.at(-1)?.id).not.toBe(oldID);
    expect(app.getSnapshot().snapshot?.qa?.id).toBe(entries.at(-1)?.id);
  }finally{close();}
});

test('Device QA retains its native configuration host while same-owner fields are revoked and reauthorized',async()=>{
  const {app,emitState,project,close}=harness();
  try{
    await act(async()=>{});
    await measureQA();
    const host=screen.getByTestId('device-qa-page');
    const field=screen.getByTestId('qa-native-configuration');
    fireEvent.changeText(field,'[Interface]\nPrivateKey = unpublished-native-buffer');
    emitState('background');
    expect(app.getSnapshot().snapshot).toBeNull();
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toBe(host);
    expect(screen.getByTestId('qa-native-configuration',{includeHiddenElements:true})).toBe(field);
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toHaveProp('pointerEvents','none');
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toHaveProp('accessibilityElementsHidden',true);
    emitState('active');
    await project({security:{ownerRevision:'qa-owner',readRevision:2} as AppSnapshot['security']});
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.getByTestId('device-qa-page')).toBe(host);
    expect(screen.getByTestId('qa-native-configuration')).toBe(field);
    expect(field).toHaveProp('value','[Interface]\nPrivateKey = unpublished-native-buffer');
    expect(screen.getByTestId('device-qa-page')).toHaveProp('pointerEvents','auto');
    expect(screen.getByTestId('device-qa-page')).toHaveProp('accessibilityElementsHidden',false);
  }finally{close();}
});

test.each([false,true].flatMap(foreground=>[false,true].map(privacy=>({foreground,privacy}))))('failed QA re-entry exposes retry instead of the retained blank page ($foreground, $privacy)',async options=>{
  const {emitState,project,failNextEntry,close}=harness(options);
  try{
    await act(async()=>{});await measureQA();
    emitState('background');emitState('active');
    failNextEntry('QA could not resume.');
    await project({qa:null,security:{ownerRevision:'qa-owner',readRevision:2} as AppSnapshot['security']});
    await act(async()=>{});
    await act(async()=>fireEvent(screen.getByTestId('qa.entry-state',{includeHiddenElements:true}),'layout',viewport()));
    expect(screen.getByText('QA could not resume.')).toBeOnTheScreen();
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Try again'})));
    await measureQA();
    expect(screen.getByTestId('device-qa-page')).toBeOnTheScreen();
    expect(screen.queryByText('QA could not resume.')).toBeNull();
  }finally{close();}
});

test('Device QA removes its host on explicit availability loss and retires native drafts on owner replacement',async()=>{
  const {app,emitState,project,close}=harness();
  try{
    await act(async()=>{});
    await measureQA();
    const first=screen.getByTestId('device-qa-page');
    const oldLayout=first.props.onLayout;
    fireEvent.changeText(screen.getByTestId('qa-native-configuration'),'Previous owner draft');
    emitState('background');emitState('active');
    await project({security:{ownerRevision:'next-qa-owner',readRevision:2} as AppSnapshot['security']});
    const next=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    expect(next).not.toBe(first);
    expect(app.getPresentationHydration().required).toBe(true);
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    await act(async()=>oldLayout(viewport()));
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
    fireEvent.changeText(screen.getByTestId('qa-native-configuration'),'Withdrawn QA draft');
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    expect(screen.queryByTestId('qa-native-configuration',{includeHiddenElements:true})).toBeNull();
    emitState('background');emitState('active');
    await project({qaTools:true});
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('device-qa-page')).not.toBe(next);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
  }finally{close();}
});


test('native QA modal Close retires only its detail while private fields are revoked',async()=>{
  const {app,emitState,project,nativeCommand,close}=harness();
  try{
    await act(async()=>{});await measureQA();
    const qa=app.getSnapshot().snapshot!.qa!;
    await project({qa:{...qa,detail:{id:'result-detail',kind:'result',title:'QA result',message:'Private native result'}}});
    emitState('background');
    expect(screen.queryByText('Private native result')).toBeNull();
    const options=mockSetOptions.mock.calls.map(([value])=>value).reverse().find(value=>value.title==='QA result'&&value.unstable_headerLeftItems);
    expect(options).toBeTruthy();
    await act(async()=>options.unstable_headerLeftItems()[0].onPress());
    expect(nativeCommand).toHaveBeenCalledWith(JSON.stringify({type:'qa.command',id:qa.id,detail:'result-detail',action:'detail.close'}));
    expect(screen.queryByTestId('qa.detail-page',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toBeTruthy();
    emitState('active');
    await project({security:{ownerRevision:'qa-owner',readRevision:2} as AppSnapshot['security']});
    expect(screen.queryByTestId('qa.detail-page',{includeHiddenElements:true})).toBeNull();
  }finally{close();}
});

test('an unrelated native snapshot cannot reopen an optimistically closed QA detail',async()=>{
  const {app,emitState,project,releaseDetailClose,close}=harness({deferDetailClose:true});
  try{
    await act(async()=>{});await measureQA();
    const qa=app.getSnapshot().snapshot!.qa!;
    const detail={id:'result-detail',kind:'result' as const,title:'QA result',message:'Private native result'};
    await project({qa:{...qa,detail}});
    const options=mockSetOptions.mock.calls.map(([value])=>value).reverse().find(value=>value.title==='QA result'&&value.unstable_headerLeftItems);
    expect(options).toBeTruthy();
    act(()=>options.unstable_headerLeftItems()[0].onPress());
    expect(screen.queryByTestId('qa.detail-page',{includeHiddenElements:true})).toBeNull();
    await project({qa:{...qa,detail:{...detail}},security:{ownerRevision:'qa-owner',readRevision:2} as AppSnapshot['security']});
    expect(screen.queryByTestId('qa.detail-page',{includeHiddenElements:true})).toBeNull();
    emitState('background');
    emitState('active');
    await project({qa:{...qa,detail:{...detail}},security:{ownerRevision:'qa-owner',readRevision:3} as AppSnapshot['security']});
    expect(screen.queryByTestId('qa.detail-page',{includeHiddenElements:true})).toBeNull();
    releaseDetailClose();
    await act(async()=>{});
  }finally{close();}
});


test.each([true,false])('foreground QA owns its privacy cover above the generic flow gate (cover policy %s)',async privacy=>{
  const {app,emitState,close}=harness({foreground:true,privacy});
  try{
    await act(async()=>{});await measureQA();
    const host=screen.getByTestId('device-qa-page');
    emitState('background');
    expect(app.getSnapshot().snapshot).toBeNull();
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toBe(host);
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toHaveProp('pointerEvents','none');
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    if(privacy)expect(screen.getByTestId('qa.privacy-cover')).toBeTruthy();
    else{
      expect(screen.queryByTestId('qa.privacy-cover')).toBeNull();
      expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).not.toHaveStyle({opacity:0});
    }
  }finally{close();}
});

test('QA keeps a direct scaffold scroll root through repeated all-off resumes without an unlock page',async()=>{
  const {view,emitState,project,close}=harness({privacy:false});
  try{
    await act(async()=>{});await measureQA();
    const scroll=screen.getByTestId('device-qa-page');
    const field=screen.getByTestId('qa-native-configuration');
    fireEvent.changeText(field,'synthetic retained configuration');
    for(let cycle=0;cycle<3;cycle++){
      emitState('background');emitState('active');
      expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toBe(scroll);
      expect(screen.queryByTestId('qa.privacy-cover')).toBeNull();
      expect(screen.queryByText('Unlock Lava')).toBeNull();
      await project({security:{ownerRevision:'qa-owner',readRevision:cycle+2} as AppSnapshot['security']});
      expect(screen.getByTestId('qa-native-configuration')).toBe(field);
      expect(field).toHaveProp('value','synthetic retained configuration');
      const tree=view.toJSON();const root=Array.isArray(tree)?tree[0]:tree;
      expect(root?.type).toBe('RCTScrollView');
    }
  }finally{close();}
});
