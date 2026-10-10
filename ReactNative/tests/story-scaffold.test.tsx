import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {Children} from 'react';
import {Animated,StyleSheet,View} from 'react-native';
import {ProtectionHero,ConnectionPanel,ConnectionScene,ExploreInvitation,ExplorePlayground,ExploreDescriptions,DemoTransport,GuardSummaries,FilterOverview,FilterIdentity,FilterEmoji,StoryInset,StoryNavigationLine,StorySurface} from '../review/story-scaffold';
import {Row,RowAccessory} from '../review/primitives';
import {connectionStages} from '../review/connection-model';
import {initialSession} from '../review/session';
import type {AppSnapshot} from '../app/contract';
import {colors,colorForScheme} from '../src/colors.ios';
import * as primitives from '../review/primitives';
import {foundation} from '../src/foundation';
import {LavaAppearanceContext} from '../src/appearance';
import {LavaActionButton} from '../src';
import {Group,StableVariants} from '../review/scaffold';
import {configurePresentation,localized} from '../app/presentation';

let mockWindow={width:390,height:844,scale:3,fontScale:1};
jest.mock('react-native/Libraries/Utilities/useWindowDimensions',()=>({__esModule:true,default:()=>mockWindow}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

const session=initialSession();
const stages=connectionStages({session:{...session,activeFilterID:'mine',filterID:'mine'},filters:[{id:'mine',name:'Home',count:'12'}],
  connection:{dns:{primary:{name:'Device DNS',detail:'Wi-Fi',transport:'IP'}},vpn:{eligible:true,enabled:false}}} as unknown as AppSnapshot,session);
const scene=(attention?:readonly import('../review/connection-model').ConnectionPart[])=><ConnectionScene stages={stages} selected="filter" attention={attention} onSelect={()=>{}}/>;
beforeEach(()=>{mockWindow={width:390,height:844,scale:3,fontScale:1};});

test('expanded connection summaries keep projected provider identities and metadata verbatim',()=>{
  configurePresentation({locale:'zh-Hant',textScales:null});
  mockWindow={...mockWindow,width:1024,height:768};
  try {
    const configured=connectionStages({connection:{dns:{primary:{name:'Cancel',detail:'Save',transport:'DoH'}},vpn:{eligible:true,enabled:false}}} as AppSnapshot,session);
    render(<ConnectionPanel stages={configured} onSelect={()=>{}} onExplore={()=>{}}/>);
    expect(screen.getByTestId('connection.dns').props.accessibilityLabel).toBe(`${localized('DNS settings')}, Cancel\nSave · DoH`);
    expect(screen.getByText('Cancel\nSave · DoH')).toBeOnTheScreen();
    expect(screen.queryByText(`${localized('Cancel')}\n${localized('Save')} · DoH`)).toBeNull();
    expect(screen.getByText(localized('This device'))).toBeOnTheScreen();
    expect(screen.getByText(localized('Disabled')+'\n'+localized('DNS fallback: unavailable'))).toBeOnTheScreen();
  } finally {configurePresentation();}
});

test('a discovery dot expands the accessory while preserving the trailing chevron axis',()=>{
  render(<><RowAccessory testID="plain.accessory" intent="page"/><RowAccessory testID="new.accessory" intent="page" attention/></>);
  expect(screen.getByTestId('plain.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
  expect(screen.getByTestId('new.accessory')).toHaveStyle({width:foundation.discovery.dotSize+foundation.space.xs+foundation.control.accessoryGlyph});
});

test('Explore keeps its playable path horizontal in the left lane and stacks it at large text',()=>{
  render(scene());
  expect(screen.getByTestId('connection.path.horizontal')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'VPN'})).toBeOnTheScreen();
  expect(screen.queryByText('VPN off')).toBeNull();
  mockWindow={...mockWindow,width:1024,height:768};screen.rerender(scene());
  expect(screen.getByTestId('connection.path.horizontal')).toBeOnTheScreen();
  mockWindow={...mockWindow,width:852,height:393};screen.rerender(scene());
  expect(screen.getByTestId('connection.path.horizontal')).toBeOnTheScreen();
  mockWindow={...mockWindow,width:768,height:1024};screen.rerender(scene());
  expect(screen.getByTestId('connection.path.horizontal')).toBeOnTheScreen();
  mockWindow={...mockWindow,width:390,height:844,fontScale:2};screen.rerender(scene());
  expect(screen.getByTestId('connection.path.vertical')).toBeOnTheScreen();
  expect(screen.getByText('Filter')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'VPN'})).toBeOnTheScreen();
});

test.each(['light','dark'] as const)('learning uses an adaptive outline in %s; demo retains immediate inspection',scheme=>{
  const select=jest.fn();
  render(<LavaAppearanceContext.Provider value={scheme}><ConnectionScene stages={stages} selected="filter" onSelect={select}/></LavaAppearanceContext.Provider>);
  const glyph=screen.getByTestId('connection.glyph.filter');
  expect(screen.getByTestId('connection.filter')).toHaveStyle({borderWidth:1.5,borderColor:colorForScheme('navigationForeground',scheme)});
  expect(StyleSheet.flatten(glyph.props.style).backgroundColor).toBeUndefined();
  expect(glyph.findByProps({symbol:stages[1]!.symbol}).props.tone).toBe('green');
  fireEvent.press(screen.getByTestId('connection.dns'));expect(select).toHaveBeenCalledTimes(1);
  screen.rerender(<LavaAppearanceContext.Provider value={scheme}><ConnectionScene stages={stages} selected="filter" attention={['phone','dns']} onSelect={select}/></LavaAppearanceContext.Provider>);
  fireEvent.press(screen.getByTestId('connection.dns'));expect(select).toHaveBeenCalledTimes(2);
  expect(screen.queryAllByRole('button')).toHaveLength(stages.length);
  expect(screen.getByTestId('connection.glyph.filter').findByProps({symbol:stages[1]!.symbol}).props.revealEnabled).toBe(true);
  expect(screen.getByTestId('connection.glyph.filter').props.style).not.toContainEqual({backgroundColor:colors.safeControlGreen});
});

// A demo frame has one selected focus, even when its narration describes a
// longer route. Manual inspection is comparison, so it dims nothing.
test('demo narration selects one focus and dims other parts; a tap dims nothing',()=>{
  render(<ConnectionScene stages={stages} attention={['phone']} onSelect={()=>{}}/>);
  const glyph=(id:string)=>screen.getByTestId(`connection.glyph.${id}`).findByProps({symbol:stages.find(stage=>stage.id===id)!.symbol});
  const control=(id:string)=>StyleSheet.flatten(screen.getByTestId(`connection.${id}`).props.style);
  expect(glyph('phone').props).toMatchObject({tone:'green',revealEnabled:true,revealVisible:true});
  expect(control('phone').opacity).toBeUndefined();
  expect(glyph('filter').props).toMatchObject({tone:'secondary',revealEnabled:true,revealVisible:false});
  expect(control('filter').opacity).toBe(foundation.interaction.dimmedOpacity);
  expect(glyph('vpn').props).toMatchObject({tone:'secondary',revealVisible:false});

  // The route narration mentions filter, VPN, and DNS, while the aperture rests
  // on DNS. Only DNS remains selected; the other narrated route parts dim too.
  screen.rerender(<ConnectionScene stages={stages} attention={['filter','vpn','dns']} onSelect={()=>{}}/>);
  expect(control('filter').opacity).toBe(foundation.interaction.dimmedOpacity);
  expect(control('vpn').opacity).toBe(foundation.interaction.dimmedOpacity);
  expect(control('dns').opacity).toBeUndefined();
  expect(glyph('filter').props).toMatchObject({tone:'secondary'});
  expect(glyph('dns').props).toMatchObject({tone:'green',revealVisible:true});
  expect(control('phone').opacity).toBe(foundation.interaction.dimmedOpacity);

  screen.rerender(<ConnectionScene stages={stages} selected="filter" onSelect={()=>{}}/>);
  expect(glyph('phone').props).toMatchObject({tone:'green',revealEnabled:false});
  expect(glyph('filter').props).toMatchObject({tone:'green',revealEnabled:false});
  for(const id of ['phone','filter','dns']) expect(control(id).opacity).toBeUndefined();
});

test('connection rails and selection use the same visible stroke in both layouts',()=>{
  render(scene());
  const outline=StyleSheet.flatten(screen.getByTestId('connection.filter').props.style).borderWidth;
  const rails=()=>screen.UNSAFE_getAllByType(View).map(node=>StyleSheet.flatten(node.props.style)).filter(style=>style?.backgroundColor===colors.safeGreen);
  expect(rails().some(style=>style.height===outline&&style.opacity!==0.35)).toBe(true);
  mockWindow={...mockWindow,fontScale:2};screen.rerender(scene());
  expect(rails().some(style=>style.width===outline&&style.opacity!==0.35)).toBe(true);
});

test.each(['horizontal','vertical'] as const)('Explore %s taps and dragging use local layout regardless of global origin',direction=>{
  if(direction==='vertical')mockWindow={...mockWindow,fontScale:2};
  const select=jest.fn(),inspect=jest.fn(),lock=jest.fn();
  const hook=jest.spyOn(primitives,'usePageInspectionLock').mockReturnValue(lock);
  // Deliberately unrelated page origin: native bars, safe areas and page scroll
  // cannot change hit testing when only page deltas are used.
  const point=(index:number,offset=900)=>({nativeEvent:{pageX:offset+(direction==='horizontal'?index*90:0)+20,pageY:offset+(direction==='vertical'?index*100:0)+20,locationX:20,locationY:20}});
  try{
    render(<ConnectionScene stages={stages} onSelect={select} onInspect={inspect}/>);
    stages.forEach((stage,index)=>{
      fireEvent(screen.getByTestId(`connection.stage.${stage.id}`),'layout',{nativeEvent:{layout:{x:direction==='horizontal'?index*90:0,y:direction==='vertical'?index*100:0,width:80,height:90}}});
      fireEvent(screen.getByTestId(`connection.${stage.id}`),'layout',{nativeEvent:{layout:{x:0,y:0,width:80,height:90}}});
    });
    const path=screen.getByTestId(`connection.path.${direction}`),first=screen.getByTestId(`connection.${stages[0]!.id}`);
    expect(path.props.onStartShouldSetResponderCapture()).toBe(false);
    fireEvent(first,'touchStart',point(0));fireEvent(path,'touchEnd',point(0));fireEvent.press(first);
    expect(select).toHaveBeenCalledWith(stages[0]);
    for(const offset of [900,100]){
      fireEvent(first,'touchStart',point(0,offset));
      expect(lock).toHaveBeenLastCalledWith(true);
      expect(path.props.onMoveShouldSetResponderCapture(point(0,offset))).toBe(false);
      act(()=>{expect(path.props.onMoveShouldSetResponderCapture(point(1,offset))).toBe(true);});
      fireEvent(path,'responderGrant',point(1,offset));
      fireEvent(path,'responderMove',point(1,offset));fireEvent(path,'responderMove',point(3,offset));
      fireEvent(path,'responderRelease',point(3,offset));fireEvent(path,'touchEnd',point(3,offset));
      expect(lock).toHaveBeenLastCalledWith(false);
    }
    expect(inspect.mock.calls.map(call=>call[0].id)).toEqual([stages[1]!.id,stages[3]!.id,stages[1]!.id,stages[3]!.id]);
    expect(select).toHaveBeenCalledTimes(1);
    fireEvent(first,'touchStart',point(0));fireEvent(path,'touchCancel');
    fireEvent(path,'responderMove',point(2));fireEvent(path,'responderRelease',point(2));
    expect(inspect).toHaveBeenCalledTimes(4);expect(select).toHaveBeenCalledTimes(1);
    expect(lock).toHaveBeenLastCalledWith(false);
    fireEvent(first,'touchStart',point(0));
    fireEvent(screen.getByTestId(`connection.stage.${stages[0]!.id}`),'layout',{nativeEvent:{layout:{x:0,y:0,width:100,height:110}}});
    fireEvent(path,'responderMove',point(2));fireEvent(path,'responderRelease',point(2));
    expect(inspect).toHaveBeenCalledTimes(4);
    expect(lock).toHaveBeenLastCalledWith(false);
    screen.rerender(<ConnectionScene stages={stages} attention={['phone']} onSelect={select} onInspect={inspect}/>);
    fireEvent(first,'touchStart',point(0));fireEvent(path,'touchEnd',point(0));fireEvent.press(first);
    expect(select).toHaveBeenCalledTimes(2);
  }finally{hook.mockRestore();}
});

test('Explore taps work without layout or asynchronous native measurements',()=>{
  const select=jest.fn();render(<ConnectionScene stages={stages} onSelect={select}/>);
  const path=screen.getByTestId('connection.path.horizontal'),filter=screen.getByTestId('connection.filter');
  expect(path.props.onStartShouldSetResponderCapture()).toBe(false);
  const point={nativeEvent:{pageX:250,pageY:730,locationX:20,locationY:20}};
  for(let index=0;index<2;index++){
    fireEvent(filter,'touchStart',point);fireEvent(path,'touchEnd',point);fireEvent.press(filter);
  }
  expect(select).toHaveBeenCalledTimes(2);
  expect(select).toHaveBeenLastCalledWith(stages.find(stage=>stage.id==='filter'));
  expect(filter.findAllByProps({pointerEvents:'none'}).length).toBeGreaterThan(0);
});

test('Explore invitation uses the canonical faceless Lava mark and keeps its whole tile actionable',()=>{
  const onPress=jest.fn();render(<ExploreInvitation onPress={onPress}/>);
  const invitation=screen.getByTestId('guard.explore');
  expect(invitation.findByProps({symbol:'lava.shield.fill'}).props).toMatchObject({accessible:false,accessibilityElementsHidden:true});
  expect(invitation.findAllByProps({symbol:'shield.fill'})).toHaveLength(0);
  fireEvent.press(invitation);expect(onPress).toHaveBeenCalledTimes(1);
});

test('Explore leads with its shared Guard heading and navigation accessory before its decorative path and summary',()=>{
  render(<ExploreInvitation onPress={()=>{}}/>);
  const invitation=screen.getByTestId('guard.explore');
  const heading=screen.UNSAFE_getByType(StoryNavigationLine);
  expect(heading.findByType(RowAccessory).props.intent).toBe('page');
  expect(screen.getByTestId('guard.explore.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
  expect(screen.getByText('Explore')).toHaveStyle({fontSize:foundation.type.caption.fontSize,fontWeight:foundation.type.caption.fontWeight});
  expect(screen.getByText('Explore').props.dynamicTypeRamp).toBe(foundation.type.caption.dynamicTypeRamp);
  const children=invitation.children;
  expect(children[0]).toBe(heading);
  expect(children[1].findAllByProps({symbol:'lava.shield.fill'}).length).toBeGreaterThan(0);
  expect(screen.getAllByRole('button')).toHaveLength(1);
});

test('Settings connection uses the same destination rows in compact and expanded layouts',()=>{
  const select=jest.fn(),explore=jest.fn();
  const panel=()=> <ConnectionPanel stages={stages} onSelect={select} onExplore={explore}/>;
  render(panel());
  expect(screen.UNSAFE_getByType(Group).props.tone).toBe('green');
  expect(screen.UNSAFE_getByType(Group).props.footer).toBeUndefined();
  expect(Children.toArray(screen.UNSAFE_getByType(Group).props.children)).toHaveLength(4);
  expect(screen.queryByTestId('connection.phone')).toBeNull();
  expect(screen.queryByTestId('connection.path.horizontal')).toBeNull();
  expect(screen.getByRole('button',{name:'Filter'})).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'VPN chaining'})).toBeOnTheScreen();
  const footer=screen.getByRole('button',{name:'Explore this connection'});
  fireEvent.press(footer);expect(explore).toHaveBeenCalledTimes(1);
  fireEvent.press(screen.getByTestId('connection.dns'));expect(select).toHaveBeenCalledWith(stages.find(stage=>stage.id==='dns'));
  mockWindow={...mockWindow,width:1024,height:768,fontScale:1};screen.rerender(panel());
  expect(screen.getByRole('button',{name:'Explore this connection'})).toBe(footer);
  expect(screen.getByTestId('connection.phone')).toBeOnTheScreen();
  mockWindow={...mockWindow,width:1024,height:1366};screen.rerender(panel());
  expect(screen.queryByTestId('connection.phone')).toBeNull();
  expect(screen.getByTestId('connection.dns')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:/Filter, Home/})).toBeOnTheScreen();
  expect(screen.getByTestId('connection.dns.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
});

test('summary metadata stays in its footer slot as filter names, counts, and text scale change',()=>{
  const onFilters=jest.fn();
  const summaries=(name:string,count:string)=><GuardSummaries today={{value:'25% blocked',allowed:9,blocked:3}} filter={{name,count}} onActivity={()=>{}} onFilters={onFilters}/>;
  render(summaries('Home','12 rules'));
  const tile=screen.getByTestId('guard.filter'),footer=screen.getByTestId('guard.filter.detail');
  expect(footer).toHaveStyle({marginTop:'auto'});
  mockWindow={...mockWindow,fontScale:2};
  screen.rerender(summaries('The filter I use with my whole family','1,234,567 rules'));
  expect(screen.getByTestId('guard.filter')).toBe(tile);
  expect(screen.getByTestId('guard.filter.detail')).toBe(footer);
  expect(StyleSheet.flatten(footer.props.style).height).toBeUndefined();
  expect(screen.getByText('1,234,567 rules')).toBeOnTheScreen();
  fireEvent.press(tile);expect(onFilters).toHaveBeenCalledTimes(1);
});

test('identity and Guard emoji use the scoped glyph size while list emoji and names retain heading typography',()=>{
  const emoji='👩🏽‍💻',name='The filter I use with my whole family';
  const open=jest.fn();
  const content=(editing:boolean)=><>
    <GuardSummaries today={{value:'25% blocked'}} filter={{name,emoji}} onActivity={()=>{}} onFilters={open}/>
    <FilterIdentity name={name} emoji={emoji} rules="12 rules" status="Up to date" icon="checkmark" onRename={editing?open:undefined}/>
    <FilterOverview name={name} emoji={emoji} counts={[]} onOpen={open}/>
    <View testID="list.emoji"><FilterEmoji emoji={emoji}/></View>
  </>;
  render(content(false));
  for(const editing of [false,true]){
    mockWindow={...mockWindow,width:320,fontScale:2};screen.rerender(content(editing));
    const symbols=screen.UNSAFE_getAllByType(FilterEmoji);
    expect(symbols).toHaveLength(4);
    for(const symbol of symbols){
      const text=symbol.findByType(require('react-native').Text);
      expect(text.props.children).toBe(emoji);
      expect(text.props.allowFontScaling).toBe(true);
      expect(StyleSheet.flatten(text.props.style).fontSize).toBe(symbol.props.context==='identity'?18:foundation.type.heading.fontSize);
    }
    expect(screen.getByTestId('filter.identity.name')).toHaveStyle({fontSize:foundation.type.heading.fontSize});
    expect(screen.getByTestId('filter.identity.name').props.numberOfLines).toBeUndefined();
    expect(screen.getByTestId('guard.filter')).toHaveProp('accessibilityLabel',`Now filtering, ${emoji} ${name}`);
  }
  fireEvent.press(screen.getByTestId('guard.filter'));
  fireEvent.press(screen.getByTestId('filter.identity.rename'));
  expect(open).toHaveBeenCalledTimes(2);
});

test('Explore keeps the diagram green and supporting content in a separate neutral group',()=>{
  render(<ExplorePlayground scene={<View testID="example.scene"/>}/>);
  expect(screen.getByTestId('example.scene')).toBeOnTheScreen();
  expect(screen.queryAllByRole('button')).toHaveLength(0);
  expect(screen.queryByText('Play an example')).toBeNull();
  expect(screen.getByTestId('explore.diagram.panel')).toHaveStyle({backgroundColor:colors.softGreen});
  expect(screen.getByTestId('explore.detail.panel')).toHaveStyle({backgroundColor:colors.cardBackground});
});

test('all descriptions participate in shared stable layout while only the current one is accessible',()=>{
  const descriptions=[{id:'short',title:'First',caption:'Short caption'},{id:'long',title:'Second',caption:'A much longer explanation that should reserve sufficient space before playback reaches it.'}];
  const content=(selected:number)=><ExploreDescriptions selected={selected} descriptions={descriptions}/>;
  render(content(0));
  expect(screen.UNSAFE_getByType(StableVariants).props.variants).toHaveLength(2);
  expect(screen.queryByText(descriptions[1]!.caption)).toBeNull();
  expect(screen.getByText(descriptions[1]!.caption,{includeHiddenElements:true})).toBeTruthy();
  const region=screen.getByTestId('explore.detail.region');
  mockWindow={...mockWindow,width:320,fontScale:2};screen.rerender(content(1));
  expect(screen.getByTestId('explore.detail.region')).toBe(region);
  expect(screen.getByTestId('explore.demo.caption.long')).toHaveTextContent(descriptions[1]!.caption);
  expect(screen.queryByTestId('explore.demo.caption.short')).toBeNull();
  expect(screen.queryByText(descriptions[0]!.caption)).toBeNull();
});

test('transport places a single story counter beside grouped glyph actions with meaningful endpoints',()=>{
  const onPrevious=jest.fn(),onPlay=jest.fn(),onNext=jest.fn();
  const content=(frame:number,playing:boolean)=><DemoTransport frame={frame} total={13} playing={playing} onPrevious={onPrevious} onPlay={onPlay} onNext={onNext}/>;
  render(content(0,true));
  expect(screen.getByText('1/13')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Previous'})).toBeDisabled();
  fireEvent.press(screen.getByRole('button',{name:'Pause demo'}));expect(onPlay).toHaveBeenCalledTimes(1);
  screen.rerender(content(12,false));
  expect(screen.getByText('13/13')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Next'})).toBeEnabled();
  fireEvent.press(screen.getByRole('button',{name:'Next'}));expect(onNext).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('button',{name:'Resume demo'})).toBeOnTheScreen();
});

test('filter overview is one navigation target with a heading chevron and three count legends',()=>{
  const open=jest.fn();
  const overview=(name:string)=><FilterOverview name={name} rules="4,321 rules" counts={[{label:'Blocklists',value:3},{label:'Blocked Domains',value:7},{label:'Allowed Exceptions',value:0}]} onOpen={open}/>;
  render(overview('Saved filter'));
  const target=screen.getByTestId('row.Now filtering');
  expect(screen.queryByRole('button',{name:'Share your filter'})).toBeNull();
  expect(screen.getByText('Allowed exceptions')).toBeTruthy();
  expect(screen.getByText('0')).toBeTruthy();
  mockWindow={...mockWindow,fontScale:2};screen.rerender(overview('The filter I use with my whole family'));
  expect(screen.getByTestId('row.Now filtering')).toBe(target);
  expect(screen.getByText('🌿 The filter I use with my whole family').props.numberOfLines).toBeUndefined();
  fireEvent.press(target);expect(open).toHaveBeenCalledTimes(1);
});


test('Off Guard hero uses an outline and retains its shared action',async()=>{
  render(<ProtectionHero title="Protection Off" description="Tap once to add local protection" mascot={<View/>} accessibilityActions={[]} onAccessibilityAction={()=>{}}><LavaActionButton title="Turn on" onPress={()=>{}}/></ProtectionHero>);
  const container=screen.getByTestId('guard.material');
  expect(StyleSheet.flatten(container.props.style)).toMatchObject({borderColor:colors.softGreen,borderWidth:1,borderRadius:foundation.radius.surface});
  expect(StyleSheet.flatten(container.props.style).backgroundColor).toBeUndefined();
  expect(screen.getByRole('button',{name:'Turn on'})).toBeOnTheScreen();
  await act(async()=>{});
});

test('Guard Explore summary uses the same regular metadata role as its rule count',()=>{
  render(<><ExploreInvitation onPress={()=>{}}/><GuardSummaries today={{value:'0% blocked',allowed:0,blocked:0}} filter={{name:'Home',count:'12 rules'}} onActivity={()=>{}} onFilters={()=>{}}/></>);
  const summary=screen.getByText('Learn more about how Lava works');
  const count=screen.getByText('12 rules');
  expect(summary).toHaveStyle({fontSize:15,fontWeight:'400'});
  expect(summary.props.dynamicTypeRamp).toBe(count.props.dynamicTypeRamp);
});

test('Ready and Off share the actual Guard material, slots and accessible status',async()=>{
  const props={title:'Protection Off',description:'Tap once to add local protection',mascot:<View testID="destination.mascot"/>,accessibilityActions:[],onAccessibilityAction:()=>{}};
  const tree=render(<ProtectionHero {...props} ready action={<LavaActionButton title="Open Guard" onPress={()=>{}}/>}/>);
  const material=screen.getByTestId('guard.material');
  expect(screen.getByLabelText('Protection status').props.accessibilityValue.text).toBe('Ready. Your next step to a safer internet.');
  tree.rerender(<ProtectionHero {...props} action={<LavaActionButton title="Turn on" onPress={()=>{}}/>}/>);
  expect(screen.getByTestId('guard.material')).toBe(material);
  expect(screen.getByLabelText('Protection status').props.accessibilityValue.text).toBe('Protection off. Tap once to turn on protection');
  expect(screen.getByTestId('destination.mascot')).toBeOnTheScreen();
  await act(async()=>{});
});
