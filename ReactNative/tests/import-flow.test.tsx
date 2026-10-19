import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {Text,View} from 'react-native';
// Native inline glyph metrics have their own wrapping/measurement suite.
jest.mock('../src/flows/InlineSymbolText.ios',()=>({InlineSymbolText:({title}:any)=>{const {Text}=require('react-native');return <Text>{title}</Text>;}}));
import {ImportFlow} from '../src/flows/import/ImportFlow';
import type {ImportState} from '../src/flows/import/contract';

jest.mock('../src/index',()=>({LavaActionButton:({title,onPress,disabled}:any)=>{
  const {Pressable,Text}=require('react-native');return <Pressable accessibilityRole="button" accessibilityLabel={title} disabled={disabled} accessibilityState={{disabled}} onPress={onPress}><Text>{title}</Text></Pressable>;
}}));
jest.mock('../review/primitives',()=>{const {Text,View}=require('react-native');return ({Copy:({children}:any)=><Text>{children}</Text>,Symbol:()=>null,
  Section:({title,children}:any)=><View><Text>{title}</Text>{children}</View>});});
jest.mock('../review/scaffold',()=>{const {Text,View}=require('react-native');return ({Group:({children}:any)=><View>{children}</View>,Panel:({children}:any)=><View>{children}</View>,
  Info:({title,description}:any)=><View><Text>{title}</Text><Text>{description}</Text></View>,
  ListRow:({title,subtitle,onPress,disabled}:any)=>{const {Pressable}=require('react-native');return onPress?<Pressable accessibilityRole="button" accessibilityLabel={title} disabled={disabled} accessibilityState={{disabled}} onPress={onPress}><Text>{title}</Text><Text>{subtitle}</Text></Pressable>:<View><Text>{title}</Text><Text>{subtitle}</Text></View>;}});});
jest.mock('../review/form-scaffold',()=>{const {Text,View}=require('react-native');return ({FlowSheet:({children,footer}:any)=><View>{children}{footer}</View>,FormPanel:({children}:any)=><View>{children}</View>,
  FormParagraph:({children}:any)=><Text>{children}</Text>,FormField:({title,value,onChangeText,editable}:any)=>{const {TextInput}=require('react-native');return <TextInput accessibilityLabel={title} value={value} onChangeText={onChangeText} editable={editable}/>;}});});
jest.mock('../review/navigation-scaffold',()=>({useCrossFadePreference:()=>false}));
jest.mock('../app/presentation',()=>{const {Text}=require('react-native');return ({Text:({children,...props}:any)=><Text {...props}>{children}</Text>,localized:(value:string)=>value});});

function state(stage:ImportState['stage'],extra:Partial<ImportState>={}):ImportState{
  return {stage,stageID:stage,direction:'forward',code:'',error:'',cameraDenied:false,checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:'alert',...extra};
}
function show(value:ImportState,command:jest.Mock=jest.fn(async()=>null)){
  render(<ImportFlow state={value} port={{command,scanner:<View testID="system.camera"/>}}/>);return command;
}

test('all entry methods send typed intent and photo decoding blocks only its row',async()=>{
  const command=show(state('chooseMethod',{decodingPhoto:true}));
  expect(screen.getByRole('button',{name:'Import from Photo'}).props.accessibilityState.disabled).toBe(true);
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'Enter a code'}));});
  expect(command).toHaveBeenCalledWith({type:'import.method',method:'code'});
});
test('Continue submits the current pasted link and duplicate presses share one command',async()=>{
  let finish!:(value:null)=>void;const command=jest.fn((action:any)=>action.type==='import.continue'?new Promise<null>(resolve=>{finish=resolve;}):Promise.resolve(null));
  show(state('enterCode'),command);
  fireEvent.changeText(screen.getByLabelText('Setup code'),'https://lava.example/a-current-code');
  fireEvent.press(screen.getByRole('button',{name:'Continue'}));fireEvent.press(screen.getByRole('button',{name:'Continue'}));
  expect(command.mock.calls.filter(([action])=>action.type==='import.continue')).toEqual([[{type:'import.continue',value:'https://lava.example/a-current-code'}]]);
  await act(async()=>finish(null));
});
test('camera recovery retains native scanning and offers Settings when access is denied',async()=>{
  const command=show(state('scanCode',{cameraDenied:true}));
  expect(screen.queryByTestId('system.camera')).toBeNull();
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'Open the Settings app'}));});
  expect(command).toHaveBeenCalledWith({type:'import.cameraSettings'});
});
test('catalog failure withholds Add and offers the original retry path',async()=>{
  const command=show(state('confirm',{catalogCheckFailed:true,review:{blocked:[],allowed:null,canImport:true,showUpgrade:false,upgradeRows:[],warnings:[]}}));
  expect(screen.getByRole('button',{name:'Add as a new filter'}).props.accessibilityState.disabled).toBe(true);
  expect(screen.queryByRole('button',{name:'Replace a filter instead'})).toBeNull();
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'Try again'}));});expect(command).toHaveBeenCalledWith({type:'import.retry'});
});
test('review displays the entire planned blocked/allowed subset and skipped-list notice',()=>{
  show(state('confirm',{review:{blocked:[{id:'one',title:'A list',metadata:'100 rules',verbatim:false},{id:'two',title:'blocked.example',metadata:'',verbatim:true}],
    allowed:['allowed.example','child.allowed.example'],canImport:true,showUpgrade:false,upgradeRows:[],warnings:[{message:'1 list wasn’t imported because it’s no longer available.',quiet:true}]}}));
  for(const title of ['A list','blocked.example','allowed.example','child.allowed.example'])expect(screen.getByText(title)).toBeTruthy();
  expect(screen.getByText('1 list wasn’t imported because it’s no longer available.')).toBeTruthy();
  expect(screen.getByText('Allowed exceptions include subdomains and can let blocked sites through. Review every entry.')).toBeTruthy();
});
test('target selection sends only the native identity, then review displays removals and additions',async()=>{
  const command=show(state('chooseReplace',{targets:[{id:'active',name:'My filter',summary:'100 rules · In effect',locked:false}]}));
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'My filter'}));});expect(command).toHaveBeenCalledWith({type:'import.target',target:'active'});
});
test('replacement review requests native consent without providing replacement content',async()=>{
  const command=show(state('reviewReplacement',{replacement:{name:'My filter',removed:'Removed: 1 blocklist',groups:[{title:'Blocked domains',removed:['old.example'],added:['new.example']}]}}));
  expect(screen.getByText('old.example')).toBeTruthy();expect(screen.getByText('new.example')).toBeTruthy();
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'Replace a filter'}));});expect(command).toHaveBeenCalledWith({type:'import.replace'});
});
test('accepted applying has no editable control and completion requires Done',()=>{
  const command=show(state('applying',{canDismiss:false}));expect(screen.queryAllByRole('button')).toHaveLength(0);expect(command).not.toHaveBeenCalled();
});
test('completion shows the confirmed local name and unavailable notice until acknowledgement',async()=>{
  const command=show(state('completed',{canDismiss:false,completed:{message:'The shared filter was imported as “Shared filter 2” in Your filters.',unavailable:'2 lists weren’t imported because they’re no longer available.'}}));
  expect(screen.getByText('The shared filter was imported as “Shared filter 2” in Your filters.')).toBeTruthy();expect(command).not.toHaveBeenCalled();
  await act(async()=>{fireEvent.press(screen.getByRole('button',{name:'Done'}));});expect(command).toHaveBeenCalledWith({type:'import.done'});
});
