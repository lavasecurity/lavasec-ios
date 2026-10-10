import {ActivityIndicator,Animated,Pressable,StyleSheet,useColorScheme,type StyleProp,type ViewStyle} from 'react-native';
import {act,fireEvent, render, screen, userEvent,within} from '@testing-library/react-native';
import {LavaActionButton, LavaIconButton, LavaSelectionAccessory, LavaText, LavaToggleRow} from '../src';
import {LavaComponentGallery} from '../gallery/LavaComponentGallery';
import {colors, colorForScheme} from '../src/colors.ios';
import {LavaAppearanceContext} from '../src/appearance';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {foundation} from '../src/foundation';
import {lavaTokens} from '../src/generated/tokens';
import Decoration from '../specs/LavaDecorationNativeComponent';
import NativeSwitch from '../specs/LavaSwitchNativeComponent';

jest.mock('../specs/LavaChoiceNativeComponent', () => require('./native-choice-mock'));
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true,useNavigation:()=>({setOptions:jest.fn()})}));
jest.mock('react-native/Libraries/Utilities/useColorScheme',()=>({__esModule:true,default:jest.fn(()=> 'light')}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:function MockDecoration(props:Record<string,unknown>){
  return require('react').createElement(require('react-native').View,props);
}}));

describe('native Lava control contracts', () => {
  it('owns a toggle gesture before a synchronous owner publication can reenter its native callback',async()=>{
    let finish!:()=>void;
    const changed=jest.fn(()=>{
      fireEvent(screen.getByRole('switch'),'valueChange',true);
      return new Promise<void>(resolve=>{finish=resolve;});
    });
    render(<LavaToggleRow title="Feedback" value={false} optimistic onValueChange={changed}/>);
    fireEvent(screen.getByRole('switch'),'valueChange',true);
    expect(changed).toHaveBeenCalledTimes(1);
    expect(screen.UNSAFE_getByType(NativeSwitch).props.pending).toBe(true);
    await act(async()=>finish());
    expect(screen.UNSAFE_getByType(NativeSwitch).props.pending).toBe(false);
  });
  it('requests a toggle change but displays only the value supplied by its owner', () => {
    const changed = jest.fn();
    const props = {title: 'Protection feedback', value: false, onValueChange: changed};
    render(<LavaToggleRow {...props} />);
    fireEvent(screen.getByRole('switch', {name: props.title}), 'valueChange', true);
    expect(changed).toHaveBeenCalledWith(true);
    expect(screen.getByRole('switch')).toHaveProp('value', false);
    screen.rerender(<LavaToggleRow {...props} value />);
    expect(screen.getByRole('switch')).toHaveProp('value', true);
  });

  it('lets the visible label request the same toggle action without another VoiceOver stop', () => {
    const changed = jest.fn();
    render(<LavaToggleRow testID="feedback" title="Feedback" value onValueChange={changed} />);
    fireEvent.press(screen.getByText('Feedback'));
    expect(changed).toHaveBeenCalledTimes(1);
    expect(changed).toHaveBeenCalledWith(false);
    expect(screen.getByText('Feedback')).toHaveProp('accessible', false);
    expect(screen.getByTestId('feedback.label')).toHaveProp('accessible', false);
    expect(screen.getAllByRole('switch')).toHaveLength(1);
    expect(screen.queryByRole('button')).toBeNull();
  });

  it('blocks pending input without dimming the switch or its label, then resumes the same control',()=>{
    const changed=jest.fn();
    const content=(pending:boolean)=><LavaToggleRow title="Feedback" testID="busy-feedback" value pending={pending} onValueChange={changed}/>;
    render(content(false));
    const native=screen.UNSAFE_getByType(NativeSwitch);
    const label=screen.getByText('Feedback');const style=label.props.style;
    screen.rerender(content(true));
    expect(screen.UNSAFE_getByType(NativeSwitch)).toBe(native);
    expect(native.props).toMatchObject({pending:true,disabled:false,value:true,pointerEvents:'none'});
    expect(screen.getByText('Feedback').props.style).toEqual(style);
    fireEvent.press(screen.getByTestId('busy-feedback.label'));
    fireEvent(screen.getByRole('switch',{name:'Feedback'}),'valueChange',false);
    expect(changed).not.toHaveBeenCalled();
    screen.rerender(content(false));
    expect(native.props).toMatchObject({pending:false,disabled:false,value:true,pointerEvents:'auto'});
    fireEvent.press(screen.getByTestId('busy-feedback.label'));expect(changed).toHaveBeenCalledWith(false);
  });
  it('does not execute disabled controls from either label or native control', async () => {
    const changed = jest.fn();
    const pressed = jest.fn();
    render(<>
      <LavaToggleRow title="Feedback" value={false} onValueChange={changed} disabled />
      <LavaActionButton title="Apply" disabled onPress={pressed} />
    </>);
    await userEvent.press(screen.getByText('Feedback'));
    await userEvent.press(screen.getByRole('button', {name: 'Apply'}));
    expect(screen.getByRole('switch')).toBeDisabled();
    expect(changed).not.toHaveBeenCalled();
    expect(pressed).not.toHaveBeenCalled();
    expect(screen.getByRole('button')).toBeDisabled();
  });

  it('keeps one native switch and one pending intent across label taps, native events and rejection',async()=>{
    let reject!:(error:Error)=>void;
    const changed=jest.fn(()=>new Promise<void>((_resolve,no)=>{reject=no;}));
    render(<LavaToggleRow testID="pending-toggle" title="Protection feedback" summary="No backup" value={false} optimistic onValueChange={changed}/>);
    const native=screen.UNSAFE_getByType(NativeSwitch);
    const initialReset=native.props.resetRevision;
    act(()=>{
      native.props.onValueChange({nativeEvent:{value:true}});
      native.props.onValueChange({nativeEvent:{value:false}});
    });
    fireEvent.press(screen.getByTestId('pending-toggle.label'));
    expect(changed).toHaveBeenCalledTimes(1);
    expect(changed).toHaveBeenCalledWith(true);
    expect(native.props).toMatchObject({pending:true,value:true,optimistic:true,pointerEvents:'none'});
    expect(screen.getAllByRole('switch')).toHaveLength(1);
    expect(screen.getByText('No backup')).toHaveProp('accessible',false);
    await act(async()=>reject(new Error('Rejected')));
    expect(screen.UNSAFE_getByType(NativeSwitch)).toBe(native);
    expect(native.props).toMatchObject({pending:false,value:false,pointerEvents:'auto',resetRevision:initialReset+1});
    fireEvent.press(screen.getByTestId('pending-toggle.label'));
    expect(changed).toHaveBeenCalledTimes(2);
    await act(async()=>reject(new Error('Rejected again')));
  });

  it('passes confirmed mode to UIKit and accepts only authoritative changes while asynchronous intent is pending',async()=>{
    let finish!:()=>void;
    const changed=jest.fn(()=>new Promise<void>(resolve=>{finish=resolve;}));
    const row=(value:boolean)=><LavaToggleRow title="Enable backup" value={value} onValueChange={changed} accessibilityHint="Review changes first"/>;
    render(row(false));
    const native=screen.UNSAFE_getByType(NativeSwitch);
    fireEvent(screen.getByRole('switch'),'valueChange',true);
    expect(changed).toHaveBeenCalledWith(true);
    expect(native.props).toMatchObject({pending:true,optimistic:false,value:false,accessibilityHint:'Review changes first',label:'Enable backup',accessible:false});
    screen.rerender(row(true));
    expect(native.props).toMatchObject({pending:true,value:true});
    await act(async()=>finish());
    expect(native.props).toMatchObject({pending:false,value:true});
  });

  it('uses the switch intrinsic measurement without accepting invalid dimensions or remounting the control',()=>{
    render(<LavaToggleRow title="Feedback" value={false} onValueChange={()=>{}}/>);
    const native=screen.UNSAFE_getByType(NativeSwitch);
    act(()=>native.props.onSizeChange({nativeEvent:{width:68,height:38}}));
    expect(native.props.style).toEqual({width:68,height:38});
    for(const dimensions of [{width:0,height:38},{width:68,height:-1},{width:NaN,height:38},{width:68,height:Infinity}]){
      act(()=>native.props.onSizeChange({nativeEvent:dimensions}));
      expect(native.props.style).toEqual({width:68,height:38});
    }
    expect(screen.UNSAFE_getByType(NativeSwitch)).toBe(native);
  });

  it('keeps quiet state and failure details on the single native accessibility control while preserving an explicit hint',()=>{
    const toggle=(summary:string,accessibilityHint?:string)=><LavaToggleRow title="Enable backup" summary={summary} accessibilityHint={accessibilityHint} value={false} onValueChange={()=>{}}/>;
    render(toggle('No backup'));
    const control=screen.getByRole('switch',{name:'Enable backup'});
    expect(control).toHaveProp('accessibilityHint','No backup');
    expect(screen.getByText('No backup')).toHaveProp('accessible',false);
    screen.rerender(toggle('Upload was not confirmed. Try again.'));
    expect(screen.getByRole('switch')).toBe(control);
    expect(control).toHaveProp('accessibilityHint','Upload was not confirmed. Try again.');
    screen.rerender(toggle('No backup','Review changes first'));
    expect(control).toHaveProp('accessibilityHint','Review changes first');
    screen.rerender(toggle('No backup',''));
    expect(control).toHaveProp('accessibilityHint','');
    expect(screen.getAllByRole('switch')).toHaveLength(1);
    expect(screen.queryAllByRole('button')).toHaveLength(0);
  });

  it('exposes the semantic button action and hint once', () => {
    const pressed = jest.fn();
    render(<LavaActionButton title="Apply" accessibilityHint="Review changes first" onPress={pressed} />);
    fireEvent.press(screen.getByRole('button', {name: 'Apply'}));
    expect(pressed).toHaveBeenCalledTimes(1);
    expect(screen.getByRole('button')).toHaveProp('accessibilityHint', 'Review changes first');
  });

  it.each([1100,250])('settles outline transitions into static paint before disabled controls reattach (duration=%s)',duration=>{
    const motions:Array<{configuration:{toValue:unknown;duration?:number;useNativeDriver:boolean};finish?: (result:{finished:boolean})=>void;stop:jest.Mock}>=[];
    const timing=jest.spyOn(Animated,'timing').mockImplementation((_value,configuration)=>{
      const motion={configuration,finish:undefined as ((result:{finished:boolean})=>void)|undefined,stop:jest.fn()};motions.push(motion);
      return {start:finish=>{motion.finish=finish;},stop:motion.stop,reset:jest.fn()};
    });
    try{
      const pressed=jest.fn();
      const content=(whiteOutline:boolean,disabled=false)=><LavaActionButton title="Next step" onPress={pressed} whiteOutline={whiteOutline} outlineTransitionDuration={duration} disabled={disabled}/>;
      render(content(true));
      const button=screen.getByRole('button',{name:'Next step'});
      type PaintNode={type:unknown;props:{style?:StyleProp<ViewStyle>}};
      const paint=()=>button.findAll((node:PaintNode)=>node.type==='View'&&StyleSheet.flatten(node.props.style)?.position==='absolute').map((node:PaintNode)=>StyleSheet.flatten(node.props.style));
      act(()=>motions.at(-1)!.finish?.({finished:true}));
      expect(button).toHaveStyle({backgroundColor:'transparent'});
      expect(paint()).toEqual([expect.objectContaining({borderColor:'white',borderWidth:1.5})]);
      expect(paint()[0].opacity).toBeUndefined();

      // Welcome -> Meet -> Permissions (disabled) -> mock installation. The
      // target stays filled while the native paint views are absent.
      screen.rerender(content(false));const exit=motions.at(-1)!;
      expect(exit.configuration).toMatchObject({toValue:1,duration,useNativeDriver:true});
      expect(paint()).toHaveLength(2);
      screen.rerender(content(false,true));expect(button).toBeDisabled();
      expect(button).toHaveStyle({backgroundColor:colors.disabledSurface});
      expect(paint()).toHaveLength(0);fireEvent.press(button);expect(pressed).not.toHaveBeenCalled();
      // Native Animated cancels when disabling detaches its last paint child.
      // There is no later successful completion for this animation.
      act(()=>exit.finish?.({finished:false}));
      screen.rerender(content(false));
      expect(screen.getByRole('button',{name:'Next step'})).toBe(button);
      expect(button).toHaveStyle({backgroundColor:colors.safeControlGreen});
      expect(screen.getByText('Next step')).toHaveStyle({color:colors.actionForeground});
      expect(paint()).toHaveLength(0);expect(motions).toHaveLength(2);
      fireEvent.press(button);expect(pressed).toHaveBeenCalledTimes(1);
      screen.rerender(content(false,true));screen.rerender(content(false));
      expect(button).toHaveStyle({backgroundColor:colors.safeControlGreen});expect(paint()).toHaveLength(0);

      // Back to Welcome owns a fresh transition; an earlier completion cannot
      // retire its live paint or restore the previous filled endpoint.
      screen.rerender(content(true));const back=motions.at(-1)!;
      expect(exit.stop).toHaveBeenCalled();expect(back.configuration).toMatchObject({toValue:0,duration,useNativeDriver:true});
      act(()=>exit.finish?.({finished:false}));expect(paint()).toHaveLength(2);
      act(()=>back.finish?.({finished:true}));
      expect(button).toHaveStyle({backgroundColor:'transparent'});
      expect(paint()).toEqual([expect.objectContaining({borderColor:'white',borderWidth:1.5})]);
      expect(paint()[0].opacity).toBeUndefined();
    }finally{timing.mockRestore();}
  });

  it('uses the canonical circular import action without changing its callback',()=>{
    const onPress=jest.fn();
    render(<LavaIconButton title="Import a filter" icon="import" onPress={onPress}/>);
    const button=screen.getByRole('button',{name:'Import a filter'});
    expect(button).toHaveStyle({width:44,height:44,borderRadius:999});
    expect(screen.UNSAFE_getByType(Decoration).props.symbol).toBe('square.and.arrow.down');
    fireEvent.press(button);expect(onPress).toHaveBeenCalledTimes(1);
  });

  it('keeps confirmation circular while its pending and disabled states change', async () => {
    const confirm = jest.fn();
    const content=(disabled=false)=><LavaIconButton title="Review changes" icon="confirm" selected disabled={disabled} onPress={confirm}/>;
    render(content());
    const button=screen.getByRole('button',{name:'Review changes'});
    expect(button).toHaveStyle({width:44,height:44,borderRadius:999,backgroundColor:colorForScheme('safeControlGreen','light')});
    fireEvent.press(button);
    expect(confirm).toHaveBeenCalledTimes(1);
    screen.rerender(content(true));
    expect(screen.getByRole('button')).toHaveStyle({width:44,height:44,borderRadius:999,backgroundColor:colorForScheme('cardBackground','light')});
    await userEvent.press(screen.getByRole('button'));
    expect(confirm).toHaveBeenCalledTimes(1);
  });

  it.each(['light','dark'] as const)('pins circle and native glyph to app-selected %s appearance', scheme => {
    const localScheme = scheme==='light'?'dark':'light';
    jest.mocked(useColorScheme).mockReturnValue(localScheme);
    const content = (selected=false,disabled=false)=><LavaAppearanceContext.Provider value={scheme}>
      <LavaIconButton title="Back" icon="back" selected={selected} disabled={disabled} onPress={()=>{}}/>
    </LavaAppearanceContext.Provider>;
    render(content());
    const button = screen.getByRole('button',{name:'Back'});
    expect(button).toHaveStyle({backgroundColor:colorForScheme('cardBackground',scheme)});
    // Static token resolution cannot be reinterpreted by a UIKit ancestor.
    expect(typeof button.props.style.backgroundColor).toBe('string');
    expect(screen.UNSAFE_getByType(Decoration).props.colorScheme).toBe(scheme);
    expect(screen.UNSAFE_getByType(Decoration).props.tone).toBe('primary');
    screen.rerender(content(true));
    expect(button).toHaveStyle({backgroundColor:colorForScheme('safeControlGreen',scheme)});
    expect(screen.UNSAFE_getByType(Decoration).props.tone).toBe('white');
    screen.rerender(content(true,true));
    expect(button).toHaveStyle({backgroundColor:colorForScheme('cardBackground',scheme)});
    expect(screen.UNSAFE_getByType(Decoration).props.tone).toBe('tertiary');
    jest.mocked(useColorScheme).mockReturnValue('light');
  });

  it('updates both parts when system appearance changes without an app override',()=>{
    jest.mocked(useColorScheme).mockReturnValue('light');
    const content=()=> <LavaIconButton title="Back" icon="back" onPress={()=>{}}/>;
    render(content());
    expect(screen.getByRole('button')).toHaveStyle({backgroundColor:colorForScheme('cardBackground','light')});
    expect(screen.UNSAFE_getByType(Decoration).props.colorScheme).toBe('light');
    jest.mocked(useColorScheme).mockReturnValue('dark');
    screen.rerender(content());
    expect(screen.getByRole('button')).toHaveStyle({backgroundColor:colorForScheme('cardBackground','dark')});
    expect(screen.UNSAFE_getByType(Decoration).props.colorScheme).toBe('dark');
    jest.mocked(useColorScheme).mockReturnValue(null);
    screen.rerender(content());
    expect(screen.UNSAFE_getByType(Decoration).props.colorScheme).toBe('light');
    jest.mocked(useColorScheme).mockReturnValue('light');
  });

  it('announces in-progress work without replacing the button or its label', () => {
    render(<LavaActionButton title="Apply" onPress={()=>{}}/>);
    const button=screen.getByRole('button',{name:'Apply'});
    screen.rerender(<LavaActionButton title="Apply" busy disabled onPress={()=>{}}/>);
    expect(screen.getByRole('button',{name:'Apply'})).toBe(button);
    expect(button).toHaveProp('accessibilityState',{busy:true,disabled:true});
    expect(screen.getAllByText('Apply')).toHaveLength(1);
  });

  it('keeps loading indicators next to centered labels for ordinary and pill actions', () => {
    const content=(stablePill:boolean)=><LavaActionButton title="Turn On" stablePill={stablePill} busy disabled onPress={()=>{}}/>;
    render(content(false));
    const label=()=>screen.getByText('Turn On');
    const indicator=()=>screen.UNSAFE_getByType(ActivityIndicator);
    const ordinaryLabelStyle=StyleSheet.flatten(label().props.style);
    const ordinaryAccessoryStyle=indicator().parent!.props.style;
    screen.rerender(content(true));
    expect(StyleSheet.flatten(label().props.style)).toEqual(ordinaryLabelStyle);
    expect(StyleSheet.flatten(label().props.style).flex).toBeUndefined();
    expect(indicator().parent!.props.style).toEqual(ordinaryAccessoryStyle);
    expect(screen.getByRole('button',{name:'Turn On'})).toHaveProp('accessibilityState',{busy:true,disabled:true});
  });

  it('keeps Dynamic Type enabled for semantic labels and fixed only for the native metric role', () => {
    render(<><LavaText testID="label">Title</LavaText><LavaText testID="metric" role="metricNumeral">42</LavaText></>);
    expect(screen.getByTestId('label')).toHaveProp('allowFontScaling', true);
    expect(screen.getByTestId('label')).toHaveProp('dynamicTypeRamp', 'subheadline');
    expect(screen.getByTestId('metric')).toHaveProp('allowFontScaling', false);
    expect(screen.getByTestId('metric')).toHaveStyle({fontVariant: ['tabular-nums']});
  });

  it('mounts the deterministic gallery and delivers its interactive state', () => {
    render(<LavaComponentGallery />);
    fireEvent.press(screen.getByRole('button', {name: 'primary action'}));
    expect(screen.getByText('Actions received: 1')).toBeOnTheScreen();
    fireEvent(screen.getByRole('switch', {name: 'Protection feedback'}), 'valueChange', true);
    expect(screen.getByRole('switch', {name: 'Protection feedback'})).toHaveProp('value', true);
  });

  it('keeps gallery content inside safe edges while preserving its full scroll viewport and state on rotation',()=>{
    const content=(left:number,right:number)=><SafeAreaInsetsContext.Provider value={{top:0,bottom:21,left,right}}><LavaComponentGallery/></SafeAreaInsetsContext.Provider>;
    render(content(59,44));const scroll=screen.getByTestId('lava-component-gallery'),action=screen.getByRole('button',{name:'primary action'});
    const style=StyleSheet.flatten(scroll.props.contentContainerStyle);
    expect(style).toMatchObject({maxWidth:foundation.layout.readingWidth+103,paddingLeft:lavaTokens.spacing.screenHorizontal+59,paddingRight:lavaTokens.spacing.screenHorizontal+44});
    expect(StyleSheet.flatten(scroll.props.style)).not.toMatchObject({paddingLeft:expect.anything()});
    expect(scroll.props.contentInsetAdjustmentBehavior).toBe('automatic');
    fireEvent.press(action);screen.rerender(content(0,0));
    expect(screen.getByTestId('lava-component-gallery')).toBe(scroll);expect(screen.getByRole('button',{name:'primary action'})).toBe(action);
    expect(screen.getByText('Actions received: 1')).toBeOnTheScreen();
    expect(StyleSheet.flatten(scroll.props.contentContainerStyle)).toMatchObject({maxWidth:foundation.layout.readingWidth,paddingHorizontal:lavaTokens.spacing.screenHorizontal});
  });

  it('demonstrates shared selection changes, disabled retention and a separately tappable locked choice',async()=>{
    render(<LavaComponentGallery/>);
    const choices=within(screen.getByTestId('gallery.selection'));
    const states=()=>choices.UNSAFE_getAllByType(LavaSelectionAccessory).map(mark=>mark.props.state);
    expect(choices.getAllByRole('button')).toHaveLength(4);
    expect(states()).toEqual(['selected','unselected','selected','locked']);
    fireEvent.press(choices.getByRole('button',{name:'Balanced'}));
    expect(choices.getByRole('button',{name:'Core',selected:false})).toBeOnTheScreen();
    expect(choices.getByRole('button',{name:'Balanced',selected:true})).toBeOnTheScreen();
    expect(states()).toEqual(['unselected','selected','selected','locked']);
    await userEvent.press(choices.getByRole('button',{name:'Disabled selection'}));
    expect(choices.getByRole('button',{name:'Disabled selection',selected:true})).toBeDisabled();
    expect(choices.getByRole('button',{name:'Balanced',selected:true})).toBeOnTheScreen();
    fireEvent.press(choices.getByRole('button',{name:'Locked option',selected:false}));
    expect(choices.getByText('Requests: 1')).toBeOnTheScreen();
    expect(states()).toEqual(['unselected','selected','selected','locked']);
  });

  it('uses native metric ink by default and preserves explicit tone overrides', () => {
    render(<>
      <LavaText testID="metric" role="metricNumeral">42</LavaText>
      <LavaText testID="override" role="metricNumeral" tone="primary">42</LavaText>
      <LavaText testID="row">Title</LavaText>
    </>);
    expect(screen.getByTestId('metric')).toHaveStyle({color: colors.ink});
    expect(screen.getByTestId('override')).toHaveStyle({color: colors.primaryText});
    expect(screen.getByTestId('row')).toHaveStyle({color: colors.primaryText});
  });
});


test('an inline icon action has one accessible target and cannot activate its parent row', async () => {
  const row=jest.fn();const remove=jest.fn();
  const stopPropagation=jest.fn();
  const content=(disabled=false)=><Pressable accessibilityRole="button" accessibilityLabel="Filter" onPress={row}><LavaIconButton testID="remove-action" title="Remove" icon="remove" role="destructive" item="My list" disabled={disabled} onPress={remove}/></Pressable>;
  render(content());
  const target=screen.getByTestId('remove-action');
  fireEvent.press(target,{stopPropagation});
  expect(stopPropagation).toHaveBeenCalledTimes(1);
  expect(remove).toHaveBeenCalledTimes(1);
  expect(row).not.toHaveBeenCalled();
  expect(target).toHaveProp('accessibilityValue',{text:'My list'});
  screen.rerender(content(true));
  await userEvent.press(screen.getByTestId('remove-action'));
  expect(remove).toHaveBeenCalledTimes(1);
});

jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
