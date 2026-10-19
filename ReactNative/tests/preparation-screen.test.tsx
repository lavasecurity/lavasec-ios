import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {Animated,AppState,StyleSheet,Text} from 'react-native';
import {PreparationScreen,type PreparationScreenProps} from '../src/flows/preparation/PreparationScreen';
import type {PreparationSnapshot} from '../src/flows/preparation/contract';
import {PreparationGuardian} from '../src/flows/preparation/PreparationGuardian';
import * as guardianMotion from '../src/guardian-motion';

jest.mock('../src/index',()=>{
  const {Pressable,Text}=require('react-native');
  return {LavaActionButton:({title,onPress,disabled,testID}:any)=><Pressable testID={testID} disabled={disabled} onPress={onPress}><Text>{title}</Text></Pressable>};
});
const state=(changes:Partial<PreparationSnapshot>={}):PreparationSnapshot=>({id:'attempt-1',origin:'filters',state:'preparing',progress:.5,title:'Building the filter',message:'',busy:false,recovery:{retry:false,editReturn:false,keepCurrent:false,upgrade:null},...changes});
const props=(snapshot:PreparationSnapshot,send=jest.fn().mockResolvedValue(true)):PreparationScreenProps=>({snapshot,port:{send},copy:{previousFilter:'Your previous filter is still active.',retry:'Try Again',upgrade:'Upgrade',keepCurrent:'Keep Current Filter',backToEdit:'Back to Edit',backToReview:'Back to Review'},active:true,reduceMotion:false,guardian:<Text>Guardian</Text>,successGlyph:<Text>Success glyph</Text>,failureGlyph:<Text>Failure glyph</Text>,renderText:({children,header,testID,numberOfLines,adjustsFontSizeToFit,minimumFontScale})=><Text testID={testID} accessibilityRole={header?'header':undefined} numberOfLines={numberOfLines} adjustsFontSizeToFit={adjustsFontSizeToFit} minimumFontScale={minimumFontScale}>{children}</Text>,background:'white',progressColor:'green',progressTrack:'gray'});

beforeEach(()=>jest.useFakeTimers());
afterEach(()=>{jest.clearAllTimers();jest.useRealTimers();jest.restoreAllMocks();});

test('failure at mount exposes the native permitted recovery and one native announcement request',async()=>{
  const send=jest.fn().mockResolvedValue(true);
  render(<PreparationScreen {...props(state({state:'failed',title:"We couldn't update your filter",message:'Network failed',origin:'domainHistory',recovery:{retry:true,editReturn:true,keepCurrent:true,upgrade:null}}),send)}/>);
  expect(screen.getByRole('header',{name:"We couldn't update your filter"})).toBeTruthy();
  expect(screen.getByText('Back to Review')).toBeTruthy();
  expect(screen.getByText('Your previous filter is still active.')).toBeTruthy();
  expect(screen.getByTestId('preparation.keepCurrent')).toHaveStyle({height:46,paddingTop:2});
  expect(screen.getByTestId('preparation.failure.title').props.numberOfLines).toBeUndefined();
  expect(send).toHaveBeenCalledWith({type:'preparation.announce',id:'attempt-1'});
  await act(async()=>{
    fireEvent.press(screen.getByTestId('preparation.retry'));
    fireEvent.press(screen.getByTestId('preparation.retry'));
  });
  expect(send.mock.calls.filter(([command])=>command.type==='preparation.retry')).toHaveLength(1);
});

test.each([false,true])('ticker preserves the native two-line fit and ease-in/ease-out title transition with Reduce Motion %s',reduceMotion=>{
  const timing=jest.spyOn(Animated,'timing').mockImplementation((_value,_configuration)=>({
    start:callback=>callback?.({finished:true}),stop:()=>{},reset:()=>{},
  }));
  const first=props(state({title:'Downloading filter lists'}));
  const view=render(<PreparationScreen {...first} reduceMotion={reduceMotion}/>);
  expect(screen.getByTestId('preparation.title')).toHaveProp('numberOfLines',2);
  expect(screen.getByTestId('preparation.title')).toHaveProp('adjustsFontSizeToFit',true);
  expect(screen.getByTestId('preparation.title')).toHaveProp('minimumFontScale',.86);
  expect(screen.getByTestId('preparation.title').props.accessibilityRole).toBeUndefined();
  view.rerender(<PreparationScreen {...first} snapshot={state({title:'Building the filter'})} reduceMotion={reduceMotion}/>);
  const exit=timing.mock.calls.map(([,configuration])=>configuration).filter(configuration=>configuration.duration===(reduceMotion?80:140));
  const entry=timing.mock.calls.map(([,configuration])=>configuration).filter(configuration=>configuration.duration===(reduceMotion?120:220));
  expect(exit).toHaveLength(2);expect(entry).toHaveLength(2);
  expect(exit[0]!.easing?.(.5)).toBeCloseTo(.31536,4);
  expect(entry[0]!.easing?.(.5)).toBeCloseTo(.68464,4);
  expect(exit[1]!.toValue).toBe(reduceMotion?0:-18);
  expect(entry[1]!.toValue).toBe(0);
  expect(screen.getByTestId('preparation.title')).toHaveTextContent('Building the filter');
});

test('a title that returns during fade-out restores full opacity and position',()=>{
  const timing=jest.spyOn(Animated,'timing').mockImplementation((value,configuration)=>({
    start:()=>{const animated=value as Animated.Value;animated.setValue((animated as any).__getValue()+(Number(configuration.toValue)-(animated as any).__getValue())/2);},
    stop:()=>{},reset:()=>{},
  } as ReturnType<typeof Animated.timing>));
  const first=props(state({title:'Downloading filter lists'}));
  const view=render(<PreparationScreen {...first}/>);
  view.rerender(<PreparationScreen {...first} snapshot={state({title:'Building the filter'})}/>);
  const opacity=timing.mock.calls.find(([,configuration])=>configuration.duration===140&&configuration.toValue===0)?.[0] as Animated.Value;
  const offset=timing.mock.calls.find(([,configuration])=>configuration.duration===140&&configuration.toValue===-18)?.[0] as Animated.Value;
  expect((opacity as any).__getValue()).toBeCloseTo(.5);
  expect((offset as any).__getValue()).toBeCloseTo(-9);
  view.rerender(<PreparationScreen {...first}/>);
  expect((opacity as any).__getValue()).toBe(1);
  expect((offset as any).__getValue()).toBe(0);
  expect(screen.getByTestId('preparation.title')).toHaveTextContent('Downloading filter lists');
});

test('the native waking Guardian waits for first admitted paint and does not replay waking after resume',async()=>{
  const previousAppState=AppState.currentState;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const eye=jest.spyOn(guardianMotion,'guardianEye');
  const view=render(<PreparationGuardian active={false} look="original"/>);
  try{
    expect(eye.mock.calls.at(-1)?.[0]).toEqual(guardianMotion.stableGuardianFrame('sleeping'));
    await act(async()=>jest.advanceTimersByTime(1000));
    view.rerender(<PreparationGuardian active look="original"/>);
    await act(async()=>jest.advanceTimersByTime(300));
    const waking=eye.mock.calls.at(-1)?.[0];
    expect(waking?.shieldWakeAmount).toBeGreaterThan(0);
    expect(waking?.shieldWakeAmount).toBeLessThan(1);
    view.rerender(<PreparationGuardian active={false} look="original"/>);
    expect(eye.mock.calls.at(-1)?.[0]).toEqual(guardianMotion.stableGuardianFrame('waking'));
    view.rerender(<PreparationGuardian active look="original"/>);
    await act(async()=>jest.advanceTimersByTime(300));
    expect(eye.mock.calls.at(-1)?.[0]).toEqual(guardianMotion.stableGuardianFrame('waking'));
  }finally{
    view.unmount();
    Object.defineProperty(AppState,'currentState',{configurable:true,value:previousAppState});
  }
});

test('a nonretryable switch offers neither retry nor an editor return',()=>{
  render(<PreparationScreen {...props(state({state:'failed',recovery:{retry:false,editReturn:false,keepCurrent:true,upgrade:null}}))}/>);
  expect(screen.queryByTestId('preparation.retry')).toBeNull();
  expect(screen.queryByTestId('preparation.editReturn')).toBeNull();
  expect(screen.getByTestId('preparation.keepCurrent')).toBeTruthy();
});

test('typed upgrade capability replaces retry and refreshes after Plus returns',()=>{
  const first=props(state({state:'failed',recovery:{retry:false,editReturn:true,keepCurrent:true,upgrade:'rules'}}));
  const view=render(<PreparationScreen {...first}/>);
  expect(screen.getByTestId('preparation.upgrade')).toBeTruthy();expect(screen.queryByTestId('preparation.retry')).toBeNull();
  view.rerender(<PreparationScreen {...first} snapshot={{...first.snapshot,recovery:{...first.snapshot.recovery,upgrade:null,retry:true}}}/>);
  expect(screen.getByTestId('preparation.retry')).toBeTruthy();expect(screen.queryByTestId('preparation.upgrade')).toBeNull();
});

test('concealed state cannot invoke recovery or announce terminal outcomes',()=>{
  const send=jest.fn().mockResolvedValue(true);
  render(<PreparationScreen {...props(state({state:'failed',recovery:{retry:true,editReturn:true,keepCurrent:true,upgrade:null}}),send)} active={false}/>);
  fireEvent.press(screen.getByTestId('preparation.retry',{includeHiddenElements:true}));
  expect(send).not.toHaveBeenCalled();
});

test.each([false,true])('native confirmed success fills before glyph and ACK with Reduce Motion %s',async reduceMotion=>{
  const send=jest.fn().mockResolvedValue(true);
  render(<PreparationScreen {...props(state({state:'success',progress:1,title:'Success'}),send)} reduceMotion={reduceMotion}/>);
  expect(screen.queryByText('Success glyph')).toBeNull();
  expect(screen.getByTestId('preparation.progress.fill').props.style).toEqual(expect.arrayContaining([expect.objectContaining({width:'75%'})]));
  await act(async()=>jest.advanceTimersByTime(540));expect(screen.queryByText('Success glyph')).toBeNull();
  await act(async()=>jest.advanceTimersByTime(40));expect(screen.getByText('Success glyph',{includeHiddenElements:true})).toBeTruthy();
  const success=screen.getByTestId('preparation.success-stage');
  const opacity=StyleSheet.flatten(success.props.style).opacity;
  expect(screen.getByTestId('preparation.success-slot',{includeHiddenElements:true})).toHaveStyle({width:68,height:68});
  if(reduceMotion){
    expect(opacity).toBe(1);
    expect(screen.queryByTestId('preparation.preparing-stage',{includeHiddenElements:true})).toBeNull();
    expect(screen.queryByTestId('preparation.progress',{includeHiddenElements:true})).toBeNull();
  }else{
    expect(opacity).toBeGreaterThanOrEqual(0);expect(opacity).toBeLessThan(.1);
    expect(screen.getByTestId('preparation.preparing-stage',{includeHiddenElements:true})).toHaveProp('accessibilityElementsHidden',true);
    expect(screen.getByTestId('preparation.progress.fill',{includeHiddenElements:true})).toHaveStyle({width:'100%'});
    await act(async()=>jest.advanceTimersByTime(120));
    const incoming=StyleSheet.flatten(screen.getByTestId('preparation.success-stage').props.style);
    const outgoing=StyleSheet.flatten(screen.getByTestId('preparation.preparing-stage',{includeHiddenElements:true}).props.style);
    expect(incoming.opacity).toBeGreaterThan(.3);expect(incoming.opacity).toBeLessThan(.8);
    expect(outgoing.opacity).toBeCloseTo(1-incoming.opacity);
    // The native transition overlaps two centered compositions. It does not
    // interpolate one title's position or collapse the old track immediately.
    expect(incoming).toMatchObject({position:'absolute',top:0,bottom:0,justifyContent:'center',gap:24});
    expect(outgoing).toMatchObject({gap:24});
    expect(screen.getByTestId('preparation.title.outgoing',{includeHiddenElements:true})).toHaveTextContent('Success');
    expect(screen.getByTestId('preparation.title')).toHaveTextContent('Success');
    expect(screen.getByTestId('preparation.progress',{includeHiddenElements:true})).toHaveStyle({height:4,maxWidth:280});
    await act(async()=>jest.advanceTimersByTime(80));
    expect(screen.getByTestId('preparation.preparing-stage',{includeHiddenElements:true})).toBeTruthy();
    expect(StyleSheet.flatten(screen.getByTestId('preparation.success-stage').props.style).opacity).toBeGreaterThan(.95);
    await act(async()=>jest.advanceTimersByTime(48));
    expect(screen.queryByTestId('preparation.preparing-stage',{includeHiddenElements:true})).toBeNull();
    expect(screen.queryByTestId('preparation.progress',{includeHiddenElements:true})).toBeNull();
    expect(StyleSheet.flatten(screen.getByTestId('preparation.success-stage').props.style)).toMatchObject({opacity:1});
    expect(StyleSheet.flatten(screen.getByTestId('preparation.success-stage').props.style).position).toBeUndefined();
  }
  expect(send).not.toHaveBeenCalledWith({type:'preparation.presented',id:'attempt-1'});
  await act(async()=>jest.advanceTimersByTime(700));
  expect(send).toHaveBeenCalledWith({type:'preparation.presented',id:'attempt-1'});
});

test('concealment pauses both the success crossfade and its completion hold',async()=>{
  const send=jest.fn().mockResolvedValue(true);
  const first=props(state({state:'success',progress:1,title:'Success'}),send);
  const view=render(<PreparationScreen {...first}/>);
  await act(async()=>jest.advanceTimersByTime(660));
  const opacity=()=>StyleSheet.flatten(screen.getByTestId('preparation.success-stage',{includeHiddenElements:true}).props.style).opacity;
  const partial=opacity();expect(partial).toBeGreaterThan(0);expect(partial).toBeLessThan(1);
  view.rerender(<PreparationScreen {...first} active={false}/>);
  await act(async()=>jest.advanceTimersByTime(5000));
  expect(opacity()).toBe(partial);
  expect(send).not.toHaveBeenCalledWith({type:'preparation.presented',id:'attempt-1'});
  view.rerender(<PreparationScreen {...first}/>);
  // Resuming can include the fraction of a frame elapsed before concealment;
  // it must preserve the partial transition rather than finish it while hidden.
  expect(opacity()).toBeGreaterThanOrEqual(partial);expect(opacity()).toBeLessThan(1);
  await act(async()=>jest.advanceTimersByTime(200));
  expect(opacity()).toBe(1);
  expect(screen.queryByTestId('preparation.preparing-stage',{includeHiddenElements:true})).toBeNull();
  expect(send).not.toHaveBeenCalledWith({type:'preparation.presented',id:'attempt-1'});
  await act(async()=>jest.advanceTimersByTime(400));
  expect(send.mock.calls.filter(([command])=>command.type==='preparation.presented')).toEqual([[{type:'preparation.presented',id:'attempt-1'}]]);
});

test('a transient bridge failure retries the display ACK without restarting native work',async()=>{
  let failed=false;
  const send=jest.fn().mockImplementation(command=>{
    if(command.type==='preparation.presented'&&!failed){failed=true;return Promise.reject(new Error('Read access changed.'));}
    return Promise.resolve(true);
  });
  render(<PreparationScreen {...props(state({state:'success',progress:1,title:'Success'}),send)}/>);
  await act(async()=>jest.advanceTimersByTime(1300));
  await act(async()=>jest.advanceTimersByTime(300));
  expect(send.mock.calls.filter(([command])=>command.type==='preparation.presented')).toHaveLength(2);
  expect(send.mock.calls.every(([command])=>['preparation.announce','preparation.presented'].includes(command.type))).toBe(true);
});

test.each([300,660])('supersession at %sms retires old fill/handoff callbacks and never acknowledges the new preparing operation',async elapsed=>{
  const send=jest.fn().mockResolvedValue(true);const first=props(state({state:'success',progress:1,title:'Success'}),send);
  const view=render(<PreparationScreen {...first}/>);
  await act(async()=>jest.advanceTimersByTime(elapsed));
  if(elapsed>550)expect(screen.getByTestId('preparation.success-stage')).toBeTruthy();
  view.rerender(<PreparationScreen {...first} snapshot={state({id:'attempt-2',progress:.1})}/>);
  await act(async()=>jest.advanceTimersByTime(3000));
  expect(screen.queryByText('Success glyph',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByTestId('preparation.title.outgoing',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByTestId('preparation.title')).toHaveTextContent('Building the filter');
  expect(send.mock.calls.filter(([command])=>command.type==='preparation.presented')).toHaveLength(0);
});

test('an ACK rejected after privacy revocation is retried on resume rather than stranding the native success hold',async()=>{
  let rejectAcknowledgement!:(reason:Error)=>void;
  let acknowledgements=0;
  const send=jest.fn().mockImplementation(command=>{
    if(command.type==='preparation.presented'&&acknowledgements++===0)return new Promise((_resolve,reject)=>{rejectAcknowledgement=reject;});
    return Promise.resolve(true);
  });
  const first=props(state({state:'success',progress:1,title:'Success'}),send);
  const view=render(<PreparationScreen {...first}/>);
  await act(async()=>jest.advanceTimersByTime(1300));
  expect(acknowledgements).toBe(1);
  view.rerender(<PreparationScreen {...first} active={false}/>);
  await act(async()=>rejectAcknowledgement(new Error('Read access changed.')));
  await act(async()=>jest.advanceTimersByTime(1000));
  expect(acknowledgements).toBe(1);
  view.rerender(<PreparationScreen {...first}/>);
  await act(async()=>{});
  expect(acknowledgements).toBe(2);
});

test('only an admitted nonzero success viewport requests the bounded native late-render lease',async()=>{
  const send=jest.fn().mockResolvedValue(true);
  const first=props(state({state:'success',progress:1,title:'Success'}),send);
  const view=render(<PreparationScreen {...first} active={false}/>);
  fireEvent(screen.getByTestId('preparation.screen',{includeHiddenElements:true}),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:0}}});
  expect(send).not.toHaveBeenCalledWith({type:'preparation.rendered',id:'attempt-1'});
  fireEvent(screen.getByTestId('preparation.screen',{includeHiddenElements:true}),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
  expect(send).not.toHaveBeenCalledWith({type:'preparation.rendered',id:'attempt-1'});
  view.rerender(<PreparationScreen {...first}/>);
  await act(async()=>{});
  expect(send).toHaveBeenCalledWith({type:'preparation.rendered',id:'attempt-1'});
});
