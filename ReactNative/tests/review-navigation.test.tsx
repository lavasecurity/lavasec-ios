import type {PropsWithChildren} from 'react';
import {AppState} from 'react-native';
import {act,renderHook} from '@testing-library/react-native';
import {useReviewNavigation} from '../review/navigation';
import {initialSession} from '../review/session';
import type {NavigationAction} from '@react-navigation/native';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
let mockFocused=true;
const mockNavigate=jest.fn();
const mockDispatch=jest.fn();
const mockGetState=jest.fn();
let mockRemoval:((event:{data:{action:NavigationAction}})=>void)|undefined;
const mockNavigation={navigate:mockNavigate,dispatch:mockDispatch,getState:mockGetState};
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>mockFocused,useNavigation:()=>mockNavigation,usePreventRemove:(enabled:boolean,callback:(event:{data:{action:NavigationAction}})=>void)=>{mockRemoval=enabled?callback:undefined;}}));
beforeEach(()=>{mockFocused=true;mockNavigate.mockClear();mockDispatch.mockClear();mockGetState.mockReset();mockRemoval=undefined;jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});});
afterEach(()=>jest.restoreAllMocks());
test.each(['inactive','background','pop','cancel'])('protected navigation handles %s while authentication is pending',async event=>{
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const app={command};const listeners=new Set<(state:string)=>void>();
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  });
  try {
    const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
    const {result,rerender,unmount}=renderHook(()=>useReviewNavigation(),{wrapper});
    act(()=>{result.current.navigate('Account');result.current.navigate('Privacy');});
    expect(command).toHaveBeenCalledTimes(1);
    if(event==='pop'){mockFocused=false;rerender(undefined);}
    else if(event!=='cancel')act(()=>{for(const listener of listeners)listener(event);for(const listener of listeners)listener('active');});
    await act(async()=>event==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    if(event==='inactive')expect(mockNavigate).toHaveBeenCalledWith('Account');
    else expect(mockNavigate).not.toHaveBeenCalled();
    unmount();
  }finally{subscription.mockRestore();}
});


test.each(['GO_BACK','POP'].flatMap(type=>['Explore','VPNChaining'].map(origin=>[type,origin])))('protected contextual return intercepts native %s from %s and awaits authorization',async(type,origin)=>{
  let resolve!:()=>void;
  const command=jest.fn(()=>new Promise<void>(yes=>{resolve=yes;}));
  const session=initialSession();session.protectedActions['Update App Settings']=true;
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'editor'},{name:origin,key:'child'}]});
  renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
  const action={type};
  act(()=>{mockRemoval!({data:{action}});mockRemoval!({data:{action}});});
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockDispatch).not.toHaveBeenCalled();
  await act(async()=>resolve());
  expect(mockDispatch).toHaveBeenCalledWith(action);
});

test.each(['cancel','background','blur','replaced'])('contextual authorization cannot pop after %s',async event=>{
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const session=initialSession();session.protectedActions['Update App Settings']=true;
  const listeners=new Set<(state:string)=>void>();
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  });
  try{
    const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
    mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'editor'},{name:'Explore',key:'explore'}]});
    const {rerender}=renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
    // Reentry after background is a new native authorization, never an inherited grant.
    act(()=>{listeners.forEach(listener=>listener('background'));listeners.forEach(listener=>listener('active'));mockRemoval!({data:{action:{type:'POP'}}});});
    expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
    if(event==='background')act(()=>listeners.forEach(listener=>listener('background')));
    if(event==='blur'){mockFocused=false;rerender(undefined);}
    if(event==='replaced')mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'new-editor'},{name:'Explore',key:'explore'}]});
    await act(async()=>event==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    expect(mockDispatch).not.toHaveBeenCalled();
  }finally{subscription.mockRestore();}
});

test('unprotected contextual returns keep the native transition without interception',()=>{
  const command=jest.fn();const session=initialSession();
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
  expect(mockRemoval).toBeUndefined();expect(command).not.toHaveBeenCalled();
});
