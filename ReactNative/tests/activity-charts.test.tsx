import {fireEvent,render,screen} from '@testing-library/react-native';
import {StyleSheet,Pressable,Text,useColorScheme} from 'react-native';
import {LavaAppearanceContext,type LavaColorScheme} from '../src/appearance';
import {colorForScheme} from '../src/colors.ios';
import {Screen} from '../review/primitives';
import {ActivityFlowBar} from '../review/detail-scaffold';
import {ActivityCharts} from '../review/activity-scaffold';
import {activityRate,type ActivityBucket} from '../review/activity-model';
jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View}));
jest.mock('../app/text-metrics',()=>({useTextScale:()=>1}));
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true}));
jest.mock('react-native/Libraries/Utilities/useColorScheme',()=>({__esModule:true,default:jest.fn(()=> 'light')}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
const buckets:ActivityBucket[]=[
  {start:1,label:'9 AM',allowed:7,blocked:3,available:true,partial:false},
  {start:2,label:'10 AM',allowed:2,blocked:1,available:true,partial:true},
  {start:3,label:'11 AM',allowed:0,blocked:0,available:false,partial:false},
];
const haptic=jest.fn();
const charts=(rangeKey='today')=><ActivityCharts allowed={9} blocked={4} loaded uptime="1h" buckets={buckets} rangeKey={rangeKey} onInspect={haptic}/>;
const layout={nativeEvent:{layout:{width:300,height:160,x:0,y:0}}};
const next=()=>fireEvent.press(screen.getByTestId('activity.chart.next'));
beforeEach(()=>{haptic.mockClear();jest.mocked(useColorScheme).mockReturnValue('light');});
test('cycling the title preserves plot height and leaves chart gestures for inspection',()=>{
  render(charts());
  const height=StyleSheet.flatten(screen.getByTestId('activity.plot.total').props.style).height;
  expect(height).toBe(120);
  next();expect(screen.getByTestId('activity.plot.counts')).toHaveStyle({height});
  next();expect(screen.getByTestId('activity.plot.rate')).toHaveStyle({height});
  next();expect(screen.getByTestId('activity.plot.total')).toHaveStyle({height});
  expect(screen.getByRole('button',{name:'Total requests'})).toBeOnTheScreen();
});
test.each(['total','counts','rate'] as const)('%s keeps its caption and geometry while a new range is pending, without inspection feedback',mode=>{
  const content=(pending:boolean,rangeKey:string)=><ActivityCharts allowed={pending?0:9} blocked={pending?0:4} loaded={!pending} pending={pending} uptime="1h"
    buckets={pending?[buckets[2]!]:buckets} rangeKey={rangeKey} onInspect={haptic}/>;
  render(content(false,'today'));
  for(let page=0;page<['total','counts','rate'].indexOf(mode);page++)next();
  const root=screen.getByTestId('activity.charts');
  const plot=screen.getByTestId(`activity.plot.${mode}`);
  const interaction=mode==='total'?screen.getByTestId('activity.total.inspect'):plot;
  const caption=screen.getByTestId('activity.caption');
  const legends=['allowed','blocked'].map(outcome=>screen.getByTestId(`legend.${outcome}`));
  const plotStyle=StyleSheet.flatten(plot.props.style);
  const captionStyle=StyleSheet.flatten(caption.props.style);
  const geometry=()=>StyleSheet.flatten(screen.getByTestId(mode==='total'?'activity.total.content':'activity.baseline').props.style);
  const contentGeometry=geometry();
  fireEvent(interaction,'layout',layout);
  fireEvent(interaction,'responderGrant',{nativeEvent:{locationX:40}});
  fireEvent(interaction,'responderRelease');
  expect(haptic).toHaveBeenCalledTimes(1);

  screen.rerender(content(true,'week'));
  expect(screen.getByTestId('activity.charts')).toBe(root);
  expect(screen.getByTestId(`activity.plot.${mode}`)).toBe(plot);
  expect(screen.getByTestId('activity.caption')).toBe(caption);
  expect(caption).toHaveTextContent('Loading Activity…');
  expect(plot).toHaveStyle(plotStyle);expect(caption).toHaveStyle(captionStyle);
  expect(geometry()).toEqual(contentGeometry);
  for(const [index,outcome] of ['allowed','blocked'].entries()){
    expect(screen.getByTestId(`legend.${outcome}`)).toBe(legends[index]);
    expect(legends[index]!).toHaveTextContent(/—/);
  }
  expect(interaction).toHaveProp('accessibilityState',{busy:true});
  expect(interaction).toHaveAccessibilityValue({text:'Loading Activity…'});
  expect(interaction.props.accessibilityActions).toEqual([]);
  expect(interaction.props.onStartShouldSetResponder()).toBe(false);
  fireEvent(interaction,'responderGrant',{nativeEvent:{locationX:40}});
  fireEvent(interaction,'responderMove',{nativeEvent:{locationX:150}});
  fireEvent(interaction,'responderRelease');
  fireEvent(interaction,'accessibilityAction',{nativeEvent:{actionName:'increment'}});
  expect(haptic).toHaveBeenCalledTimes(1);
  expect(caption).toHaveTextContent('Loading Activity…');
  expect(screen.queryByText('No data')).toBeNull();

  screen.rerender(content(false,'week'));
  expect(screen.queryByText('Loading Activity…')).toBeNull();
  expect(screen.getByTestId(`activity.plot.${mode}`)).toBe(plot);
  expect(plot).toHaveStyle(plotStyle);expect(caption).toHaveStyle(captionStyle);
  expect(geometry()).toEqual(contentGeometry);
  expect(interaction).toHaveProp('accessibilityState',{busy:false});
  expect(interaction.props.onStartShouldSetResponder()).toBe(true);
  fireEvent(interaction,'responderGrant',{nativeEvent:{locationX:40}});
  expect(haptic).toHaveBeenCalledTimes(2);
  expect(haptic).toHaveBeenLastCalledWith('populated');
});
test('dragging inspects successive buckets and emits one haptic per changed bucket',()=>{
  render(charts());next();
  const plot=screen.getByTestId('activity.plot.counts');fireEvent(plot,'layout',layout);
  fireEvent(plot,'responderGrant',{nativeEvent:{locationX:40}});
  expect(plot).toHaveProp('accessibilityValue',{text:'9 AM, 7 Allowed, 3 Blocked'});
  const selectedHeight=(index:number)=>StyleSheet.flatten(screen.getByTestId(`activity.bucket.${index}.selection`).props.style).height;
  const stackedHeight=(index:number)=>['allowed','blocked'].reduce((height,outcome)=>height+StyleSheet.flatten(screen.getByTestId(`activity.bucket.${index}.${outcome}`).props.style).height,0);
  const tallestSelection=selectedHeight(0);
  expect(tallestSelection).toBeCloseTo(stackedHeight(0));
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:45}});
  expect(haptic).toHaveBeenCalledTimes(1);
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:150}});
  expect(haptic).toHaveBeenCalledTimes(2);
  expect(plot).toHaveProp('accessibilityValue',{text:'10 AM, 2 Allowed, 1 Blocked'});
  expect(screen.queryByTestId('activity.bucket.0.selection')).toBeNull();
  expect(selectedHeight(1)).toBeCloseTo(stackedHeight(1));
  expect(selectedHeight(1)).toBeCloseTo(tallestSelection*3/10);
  expect(screen.getByTestId('activity.bucket.1.selection')).toHaveStyle({bottom:0,left:1,right:1});
  expect(StyleSheet.flatten(screen.getByTestId('activity.bucket.1.selection').props.style).top).toBeUndefined();
  expect(screen.getByTestId('activity.bucket.1')).toHaveStyle({height:'100%'});
  next();expect(screen.getByTestId('activity.plot.rate')).toHaveProp('accessibilityValue',{text:'Drag to inspect'});
  screen.rerender(charts('week'));
  expect(screen.getByTestId('activity.plot.rate')).toHaveProp('accessibilityValue',{text:'Drag to inspect'});
});
test.each(['light','dark'] as const)('selected bar and rate strokes follow app %s appearance across inspection and theme changes',scheme=>{
  const alternate=scheme==='light'?'dark':'light';
  jest.mocked(useColorScheme).mockReturnValue(alternate);
  const content=(appearance:LavaColorScheme)=><LavaAppearanceContext.Provider value={appearance}>{charts()}</LavaAppearanceContext.Provider>;
  const expectStroke=(id:string,appearance:LavaColorScheme)=>{
    const stroke=StyleSheet.flatten(screen.getByTestId(id).props.style).borderColor;
    expect(stroke).toBe(colorForScheme('primaryText',appearance));
    expect(typeof stroke).toBe('string');
  };
  render(content(scheme));next();
  const counts=screen.getByTestId('activity.plot.counts');fireEvent(counts,'layout',layout);
  fireEvent(counts,'responderGrant',{nativeEvent:{locationX:40}});
  expectStroke('activity.bucket.0.selection',scheme);
  fireEvent(counts,'responderMove',{nativeEvent:{locationX:150}});
  expectStroke('activity.bucket.1.selection',scheme);
  screen.rerender(content(alternate));
  expectStroke('activity.bucket.1.selection',alternate);
  expect(counts).toHaveAccessibilityValue({text:'10 AM, 2 Allowed, 1 Blocked'});
  expect(haptic).toHaveBeenCalledTimes(2);
  next();const rate=screen.getByTestId('activity.plot.rate');fireEvent(rate,'layout',layout);
  fireEvent(rate,'responderGrant',{nativeEvent:{locationX:40}});
  expectStroke('activity.point.0',alternate);
  fireEvent(rate,'responderMove',{nativeEvent:{locationX:150}});
  expectStroke('activity.point.1',alternate);
  expect(StyleSheet.flatten(screen.getByTestId('activity.point.0').props.style).borderWidth).toBeUndefined();
  screen.rerender(content(scheme));
  expectStroke('activity.point.1',scheme);
  expect(rate).toHaveAccessibilityValue({text:'10 AM, 33% blocked'});
  expect(haptic).toHaveBeenCalledTimes(4);
});
test('rate inspection rounds percentages and preserves unavailable versus zero-request data',()=>{
  render(charts());next();next();
  const plot=screen.getByTestId('activity.plot.rate');fireEvent(plot,'layout',layout);
  fireEvent(plot,'responderGrant',{nativeEvent:{locationX:150}});
  expect(plot).toHaveProp('accessibilityValue',{text:'10 AM, 33% blocked'});
  expect(screen.getByTestId('legend.blocked')).toHaveProp('accessibilityLabel','Blocked, 1 (33%)');
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'increment'}});
  expect(plot).toHaveProp('accessibilityValue',{text:'No data'});
  expect(activityRate(buckets[2]!)).toBeUndefined();
  expect(activityRate({...buckets[2]!,available:true})).toBeUndefined();
});


test('Total inspection keeps its aggregate, dims the complete other legend and ignores the gap',()=>{
  render(charts());const plot=screen.getByTestId('activity.total.inspect');
  fireEvent(plot,'layout',{nativeEvent:{layout:{width:303}}});
  fireEvent(plot,'responderGrant',{nativeEvent:{locationX:50}});
  expect(plot).toHaveAccessibilityValue({text:'Blocked, 4'});
  expect(screen.getByTestId('legend.allowed')).toHaveStyle({opacity:0.35});
  expect(screen.getByTestId('legend.blocked')).toHaveStyle({opacity:1});
  expect(screen.getByTestId('activity.total.value')).toHaveTextContent('13');
  expect(screen.getByTestId('legend.allowed')).toHaveProp('accessibilityLabel','Allowed, 9 (69%)');
  expect(screen.getByTestId('legend.blocked')).toHaveProp('accessibilityLabel','Blocked, 4 (31%)');
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:300*4/13+1.5}});
  expect(haptic).toHaveBeenCalledTimes(1);
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:290}});
  expect(haptic).toHaveBeenCalledTimes(2);expect(haptic).toHaveBeenLastCalledWith('populated');
  expect(plot).toHaveAccessibilityValue({text:'Allowed, 9'});
  fireEvent(plot,'responderRelease');
  expect(plot).toHaveAccessibilityValue({text:'Allowed, 9'});
  expect(screen.getByTestId('activity.total.value')).toHaveTextContent('13');
  expect(screen.getByTestId('legend.allowed')).toHaveProp('accessibilityLabel','Allowed, 9 (69%)');
  expect(screen.getByTestId('legend.blocked')).toHaveProp('accessibilityLabel','Blocked, 4 (31%)');
});

test.each(['counts','rate'] as const)('%s legends follow the inspected bucket and omit Partial without changing data',kind=>{
  const data=[...buckets,{start:4,label:'Noon',allowed:0,blocked:0,available:true,partial:true},
    {start:5,label:'1 PM',allowed:0,blocked:5,available:true,partial:false}];
  render(<ActivityCharts allowed={9} blocked={9} loaded uptime="1h" buckets={data} rangeKey="today"/>);
  next();if(kind==='rate')next();
  const plot=screen.getByTestId(`activity.plot.${kind}`);fireEvent(plot,'layout',layout);
  const inspect=(index:number)=>fireEvent(plot,'responderGrant',{nativeEvent:{locationX:(index+0.5)*60}});
  const legend=(allowed:string,blocked:string)=>{
    expect(screen.getByTestId('legend.allowed')).toHaveProp('accessibilityLabel',`Allowed, ${allowed}`);
    expect(screen.getByTestId('legend.blocked')).toHaveProp('accessibilityLabel',`Blocked, ${blocked}`);
  };
  legend('9 (50%)','9 (50%)');
  inspect(0);legend('7 (70%)','3 (30%)');
  expect(screen.getByTestId('activity.caption.text')).toHaveTextContent(/^9 AM$/);
  inspect(1);legend('2 (67%)','1 (33%)');
  expect(screen.getByTestId('activity.caption.text')).toHaveTextContent(/^10 AM$/);
  expect(plot.props.accessibilityValue.text).not.toContain('Partial');
  expect(data[1]!.partial).toBe(true);
  inspect(2);legend('—','—');expect(plot).toHaveAccessibilityValue({text:'No data'});
  inspect(3);legend('0 (0%)','0 (0%)');expect(screen.getByTestId('activity.caption.text')).toHaveTextContent(/^Noon$/);
  inspect(4);legend('0 (0%)','5 (100%)');
  screen.rerender(<ActivityCharts allowed={2} blocked={8} loaded uptime="2h" buckets={data} rangeKey="week"/>);
  legend('2 (20%)','8 (80%)');expect(plot).toHaveAccessibilityValue({text:'Drag to inspect'});
});

test.each(['light','dark'] as const)('rate connections stay below all 5pt dots and selected borders in %s',scheme=>{
  const data:ActivityBucket[]=[0,100,100,20,undefined,80,0].map((rate,index)=>({
    start:index,label:String(index),allowed:rate===undefined?0:100-rate,blocked:rate??0,available:rate!==undefined,partial:false,
  }));
  render(<LavaAppearanceContext.Provider value={scheme}><ActivityCharts allowed={300} blocked={300} loaded uptime="1h" buckets={data} rangeKey="today"/></LavaAppearanceContext.Provider>);
  next();next();const plot=screen.getByTestId('activity.plot.rate');
  fireEvent(plot,'layout',{nativeEvent:{layout:{width:70,height:120}}});
  const layers=screen.getByTestId('activity.rate.marks');
  expect(layers.children.map((child:{props:{testID:string}})=>child.props.testID)).toEqual(['activity.rate.lines','activity.rate.points']);
  expect(screen.getByTestId('activity.rate.lines').children.map((child:{props:{testID:string}})=>child.props.testID)).toEqual(['activity.line.1','activity.line.2','activity.line.3','activity.line.6']);
  const baseline=120-StyleSheet.flatten(screen.getByTestId('activity.baseline').props.style).bottom;
  for(const index of [0,1,2,3,5,6]){
    const point=StyleSheet.flatten(screen.getByTestId(`activity.point.${index}`).props.style);
    expect(point.width).toBe(5);expect(point.height).toBe(5);
    expect(point.left+point.width/2).toBe((index+0.5)*10);
    expect(point.top).toBeGreaterThanOrEqual(0);expect(point.top+point.height).toBeLessThanOrEqual(baseline);
  }
  for(const index of [1,2,3,6]){
    const line=StyleSheet.flatten(screen.getByTestId(`activity.line.${index}`).props.style);
    const from=StyleSheet.flatten(screen.getByTestId(`activity.point.${index-1}`).props.style);
    const to=StyleSheet.flatten(screen.getByTestId(`activity.point.${index}`).props.style);
    expect(line.height).toBe(3);expect(line.left).toBe(from.left+2.5);
    expect(line.top+1.5).toBeCloseTo(from.top+2.5);
    expect(line.width).toBeCloseTo(Math.hypot(10,to.top-from.top));
  }
  for(const index of [0,2,6]){
    fireEvent(plot,'responderGrant',{nativeEvent:{locationX:(index+0.5)*10}});
    expect(screen.getByTestId(`activity.point.${index}`)).toHaveStyle({width:5,height:5,borderWidth:1,zIndex:1,borderColor:colorForScheme('primaryText',scheme),backgroundColor:colorForScheme('primaryText',scheme)});
    for(const other of [0,1,2,3,5,6].filter(value=>value!==index))expect(StyleSheet.flatten(screen.getByTestId(`activity.point.${other}`).props.style).zIndex).toBeUndefined();
  }
});

test('non-chart page touches reset every inspection while chart touch-up preserves it and controls remain actionable',()=>{
  const outside=jest.fn();render(<Screen>{charts()}<Pressable testID="outside.control" onPress={outside}><Text>Continue</Text></Pressable></Screen>);
  for(let page=0;page<3;page++){
    const id=page===0?'activity.total.inspect':`activity.plot.${page===1?'counts':'rate'}`;
    const plot=screen.getByTestId(id);fireEvent(plot,'layout',layout);
    fireEvent(plot,'responderGrant',{nativeEvent:{locationX:40}});
    fireEvent(plot,'responderRelease');
    expect(plot.props.accessibilityValue.text).not.toBe(page===0?'13':'Drag to inspect');
    const stopPropagation=jest.fn();fireEvent(plot,'touchStart',{stopPropagation});expect(stopPropagation).toHaveBeenCalledTimes(1);
    fireEvent(screen.getByTestId('screen.scroll'),'touchStart');
    expect(plot).toHaveAccessibilityValue({text:page===0?'13':'Drag to inspect'});
    expect(screen.getByTestId('legend.allowed')).toHaveStyle({opacity:1});
    expect(screen.getByTestId('legend.blocked')).toHaveStyle({opacity:1});
    fireEvent.press(screen.getByTestId('outside.control'));next();
  }
  expect(outside).toHaveBeenCalledTimes(3);
});

test('unavailable and measured-zero time bars are flat; missing and zero-rate feedback remain distinct',()=>{
  const data=[...buckets,{...buckets[2]!,start:4,label:'Noon',available:true}, {...buckets[2]!,start:5,label:'1 PM',allowed:2,available:true}];
  render(<ActivityCharts allowed={11} blocked={4} loaded uptime="1h" buckets={data} rangeKey="day" onInspect={haptic}/>);next();
  expect(screen.queryByTestId('activity.bucket.2.allowed')).toBeNull();
  expect(screen.queryByTestId('activity.bucket.2.blocked')).toBeNull();
  expect(screen.getByTestId('activity.bucket.3.allowed')).toHaveStyle({height:0});
  expect(screen.getByTestId('activity.bucket.3.blocked')).toHaveStyle({height:0});
  const counts=screen.getByTestId('activity.plot.counts');fireEvent(counts,'layout',layout);
  fireEvent(counts,'responderGrant',{nativeEvent:{locationX:150}});
  expect(counts).toHaveAccessibilityValue({text:'No data'});
  expect(screen.queryByTestId('activity.bucket.2.selection')).toBeNull();
  fireEvent(counts,'responderMove',{nativeEvent:{locationX:210}});
  expect(counts).toHaveAccessibilityValue({text:'Noon, 0 Allowed, 0 Blocked'});
  expect(screen.queryByTestId('activity.bucket.3.selection')).toBeNull();
  next();const plot=screen.getByTestId('activity.plot.rate');fireEvent(plot,'layout',layout);
  fireEvent(plot,'responderGrant',{nativeEvent:{locationX:150}});expect(haptic).toHaveBeenLastCalledWith('empty');
  expect(plot).toHaveAccessibilityValue({text:'No data'});
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:210}});expect(haptic).toHaveBeenLastCalledWith('empty');
  expect(plot).toHaveAccessibilityValue({text:'Noon, No requests'});
  fireEvent(plot,'responderMove',{nativeEvent:{locationX:290}});expect(haptic).toHaveBeenLastCalledWith('populated');
  expect(plot).toHaveAccessibilityValue({text:'1 PM, 0% blocked'});
  expect(screen.getByTestId('activity.point.0')).toHaveStyle({width:5,height:5});
  expect(screen.getByTestId('activity.line.1')).toHaveStyle({height:3});
});

test('all chart baselines share the fixed frame and top breathing room',()=>{
  render(charts());
  const height=StyleSheet.flatten(screen.getByTestId('activity.plot.total').props.style).height;
  const totalBottom=StyleSheet.flatten(screen.getByTestId('activity.total.content').props.style).height;
  next();const baseline=StyleSheet.flatten(screen.getByTestId('activity.baseline').props.style);
  expect(totalBottom).toBe(height-baseline.bottom);
  const countBar=StyleSheet.flatten(screen.getByTestId('activity.bucket.0.allowed').props.style).height;
  expect(countBar).toBeLessThan(totalBottom*7/10);
  next();expect(StyleSheet.flatten(screen.getByTestId('activity.baseline').props.style).bottom).toBe(baseline.bottom);
});

test('Total accessibility inspection follows the physical blocked-left order',()=>{
  render(charts());const plot=screen.getByTestId('activity.total.inspect');
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'increment'}});
  expect(plot).toHaveAccessibilityValue({text:'Blocked, 4'});
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'increment'}});
  expect(plot).toHaveAccessibilityValue({text:'Allowed, 9'});
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'decrement'}});
  expect(plot).toHaveAccessibilityValue({text:'Blocked, 4'});
});

test('a single outcome has no invisible second inspection target and Total remains keyboard accessible',()=>{
  render(<ActivityCharts allowed={0} blocked={4} loaded uptime="1h" buckets={[]} rangeKey="day" onInspect={haptic}/>);
  const plot=screen.getByTestId('activity.total.inspect');
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'increment'}});
  expect(plot).toHaveAccessibilityValue({text:'Blocked, 4'});
  fireEvent(plot,'accessibilityAction',{nativeEvent:{actionName:'increment'}});expect(haptic).toHaveBeenCalledTimes(1);
});

test('compact and full composition bars have straight internal ends under one outer contour',()=>{
  render(<ActivityFlowBar allowed={80} blocked={20} compact/>);
  const bar=screen.getByTestId('activity.flow-bar');fireEvent(bar,'layout',{nativeEvent:{layout:{width:303}}});
  expect(bar).toHaveStyle({overflow:'hidden',height:8,gap:3,direction:'ltr'});
  expect(bar.children.slice(0,2).map((child:{props:{testID:string}})=>child.props.testID)).toEqual(['activity.flow.blocked','activity.flow.allowed']);
  for(const part of ['allowed','blocked'])expect(StyleSheet.flatten(screen.getByTestId(`activity.flow.${part}`).props.style).borderRadius).toBeUndefined();
  expect(screen.getByTestId('activity.flow.allowed')).toHaveStyle({width:240});expect(screen.getByTestId('activity.flow.blocked')).toHaveStyle({width:60});
  screen.rerender(<ActivityFlowBar allowed={80} blocked={0}/>);
  expect(screen.getByTestId('activity.flow-bar')).toHaveStyle({height:14,gap:0});
  expect(screen.getByTestId('activity.flow.allowed')).toHaveStyle({width:303});expect(screen.queryByTestId('activity.flow.blocked')).toBeNull();
});
