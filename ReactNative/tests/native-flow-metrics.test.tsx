import type {ReactNode} from 'react';
import {AppState,DynamicColorIOS,KeyboardAvoidingView,PixelRatio,Platform,PlatformColor,ScrollView,StyleSheet,View,type StyleProp,type ViewStyle} from 'react-native';
import {act,fireEvent,render,screen,within} from '@testing-library/react-native';
import {PresentationContext,Text,localized,type Presentation} from '../app/presentation';
import type {AppSnapshot} from '../app/contract';
import type {AppStore} from '../app/store';
import {useTextScale} from '../app/text-metrics';
import {windowLayout,useWindowLayout} from '../src/window-layout';
import {NativeFlowMetrics} from '../review/NativeFlowMetrics.ios';
import {AccountBackupFlowAdapter} from '../review/AccountBackupFlowAdapter.ios';
import {AccountBackupFlow} from '../src/flows/account-backup/AccountBackupFlow';
import {ImportFlow} from '../src/flows/import/ImportFlow';
import {FlowConsentToggle} from '../src/flows/FlowConsentToggle';
import {FlowInfo} from '../src/flows/FlowInfo';
import {Panel as NativeInfoPanel} from '../src/flows/info-ui.ios';
import {QAScreen,QADetailScreen} from '../src/flows/qa/QAScreens';
import type {QADetail} from '../src/flows/qa/contract';
import {DNSHelpScreen} from '../src/flows/dns-help/DNSHelpScreen';
import {ImportFlowAdapter} from '../review/ImportFlowAdapter.ios';
import {PasscodeFlowAdapter} from '../review/PasscodeFlowAdapter.ios';
import {QAFlowAdapter} from '../review/QAFlowAdapter.ios';
import {AutoSwitchScreen,DNSPatchScreen} from '../review/NativePageScreen';
import {Copy,Screen,Symbol} from '../review/primitives';
import {FlowSheet,FormParagraph} from '../review/form-scaffold';
import {Group,Panel as OrdinaryPanel,Search} from '../review/scaffold';
import {LavaAppearanceContext} from '../src/appearance';
import {colors} from '../src/colors';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {LavaSurface} from '../src/surface.ios';
import Decoration from '../specs/LavaDecorationNativeComponent';
import Inline from '../specs/LavaInlineSymbolTextNativeComponent';
import Configuration from '../specs/LavaQAConfigurationNativeComponent';
import SystemButton from '../specs/LavaSystemButtonNativeComponent';
import NativeSwitch from '../specs/LavaSwitchNativeComponent';
import NativeTextField from '../specs/LavaTextFieldNativeComponent';
import type {AccountBackupFlowState} from '../src/flows/account-backup/types';
import type {ImportState} from '../src/flows/import/contract';

let mockWindow={width:960,height:1280,scale:2,fontScale:1};
const mockNavigation={setOptions:jest.fn(),isFocused:()=>true,addListener:()=>()=>{}};
jest.mock('react-native/Libraries/Utilities/useWindowDimensions',()=>({__esModule:true,default:()=>mockWindow}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true,useRoute:()=>({params:{}}),
  NavigationContainer:({children}:any)=>children,NavigationIndependentTree:({children}:any)=>children,
  DefaultTheme:{},DarkTheme:{},usePreventRemove:jest.fn(),useNavigationContainerRef:()=>({isReady:()=>false})}));
jest.mock('@react-navigation/elements',()=>({HeaderHeightContext:require('react').createContext(undefined),useHeaderHeight:()=>0}));
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>({Navigator:({children}:any)=>children,Screen:({children}:any)=>typeof children==='function'?children():children})}));
jest.mock('react-native-safe-area-context',()=>({...require('react-native-safe-area-context/jest/mock').default,useSafeAreaInsets:()=>({top:0,left:0,bottom:0,right:0})}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/NativeLavaAppearance',()=>({__esModule:true,default:{getSnapshot:jest.fn(async()=>({preference:'system',revision:0})),onSnapshot:jest.fn(()=>({remove(){}}))}}));
jest.mock('../specs/NativeLavaApp',()=>({__esModule:true,default:{command:jest.fn(async()=>JSON.stringify({}))}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:'NativeDecoration'}));
jest.mock('../specs/LavaInlineSymbolTextNativeComponent',()=>({__esModule:true,default:'NativeInlineSymbolText'}));
jest.mock('../specs/LavaBackupCredentialsNativeComponent',()=>({__esModule:true,default:'NativeBackupCredentials'}));
jest.mock('../specs/LavaPasscodeInputNativeComponent',()=>({__esModule:true,default:'NativePasscodeInput'}));
jest.mock('../specs/LavaImportScannerNativeComponent',()=>({__esModule:true,default:'NativeImportScanner'}));
jest.mock('../specs/LavaQAConfigurationNativeComponent',()=>({__esModule:true,default:'NativeQAConfiguration'}));
jest.mock('../specs/LavaSystemButtonNativeComponent',()=>({__esModule:true,default:'NativeSystemButton'}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:'NativeTextField'}));
jest.mock('../specs/LavaSwitchNativeComponent',()=>({__esModule:true,default:'NativeSwitch'}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));

const originalState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
beforeEach(()=>{mockWindow={width:960,height:1280,scale:2,fontScale:1};mockNavigation.setOptions.mockClear();});
const backup:AccountBackupFlowState={kind:'backupSetup',title:'Set Up Encrypted Backup',busy:false,canBack:false,canClose:true,success:false,connections:[],deleting:false,
  step:'overview',error:'',copied:false,canContinue:false,supportsPasskey:true,selectedPasskey:false,saved:false,understands:false,uploading:false,uploadError:'',
  mode:'deviceKey',modes:[],status:null,review:null,resolverConfirmationRequired:false,resolverConfirmed:false};
const qa={id:'qa-visit',search:'',sections:[],formsVisible:true,hasConfiguration:false,staging:false,probeSuffix:'',canaryIP:'',hasResult:false};
function fixture(children:ReactNode,textScales:Record<string,number>|null=null,detail?:QADetail,nativeTextMetrics?:Presentation['nativeTextMetrics'],nativeSymbolMetrics?:Presentation['nativeSymbolMetrics']){
  const live={schema:1,fullApp:true,revision:1,qaTools:true,qa:{...qa,...(detail?{detail}:{})},dnsPatch:{state:'enabled'},session:initialSession(),
    backgroundPrivacyCoverRequired:false,security:{ownerRevision:'native-owner',readRevision:1}} as unknown as AppSnapshot;
  const app={command:jest.fn(async()=>null),subscribe:()=>()=>{},getSnapshot:()=>({snapshot:live}),getReadEpoch:()=>1,
    getPresentationHydration:()=>({required:false,epoch:0})} as unknown as AppStore;
  return <PresentationContext.Provider value={{locale:'en',textScales,nativeTextMetrics,nativeSymbolMetrics}}><ReviewContext.Provider value={{app,live,session:live.session} as unknown as ReviewState}>
    <Copy role="body" testID="responsive.sibling">Lava Security</Copy>{children}
  </ReviewContext.Provider></PresentationContext.Provider>;
}
const font=(text:string)=>StyleSheet.flatten(screen.getByText(text).props.style).fontSize;
const sibling=(scale=1)=>expect(StyleSheet.flatten(screen.getByTestId('responsive.sibling').props.style).fontSize).toBeCloseTo(17*1.4*scale);

test('original SF Image layout requires an explicit glyph opt-in and migrated native-flow context',()=>{
  render(fixture(<>
    <Symbol name="play.rectangle" size={24} pointSize={17} responsive={false} nativeLayout="swiftui"/>
    <NativeFlowMetrics>
      <Symbol name="play.rectangle" size={24} pointSize={17} responsive={false}/>
      <Symbol name="play.rectangle" size={24} pointSize={17} responsive={false} nativeLayout="swiftui"/>
    </NativeFlowMetrics>
  </>));
  const glyphs=screen.UNSAFE_getAllByType(Decoration);
  expect(glyphs.map(node=>node.props.symbol)).toEqual(['play.rectangle','play.rectangle','swiftui.sf:play.rectangle']);
  for(const glyph of glyphs){
    expect(glyph.props).toMatchObject({fontPointSize:17,fontWeight:'regular',tone:'green',accessible:false,accessibilityElementsHidden:true});
    expect(StyleSheet.flatten(glyph.props.style)).toEqual({width:24,height:24});
  }
});

test('the native SF Image leaf receives the measured semantic point size without scaling its authored slot',()=>{
  render(fixture(<NativeFlowMetrics><Symbol name="play.rectangle" size={24} pointSize={17} weight="semibold" tone="secondary"
    dynamicTypeRamp="body" responsive={false} nativeLayout="swiftui"/></NativeFlowMetrics>,{body:3},undefined,
    {body:{fontSize:53,lineHeight:63,leading:0}}));
  const glyph=screen.UNSAFE_getByType(Decoration);
  expect(glyph.props).toMatchObject({symbol:'swiftui.sf:play.rectangle',fontPointSize:53,fontWeight:'semibold',tone:'secondary'});
  expect(StyleSheet.flatten(glyph.props.style)).toEqual({width:24,height:24});
});

test.each([0,-1,Number.NaN,Number.POSITIVE_INFINITY])('invalid SF point size %s cannot enable the scoped native Image renderer',pointSize=>{
  render(fixture(<NativeFlowMetrics><Symbol name="play.rectangle" size={24} pointSize={pointSize} responsive={false} nativeLayout="swiftui"/></NativeFlowMetrics>));
  expect(screen.UNSAFE_getByType(Decoration).props.symbol).toBe('play.rectangle');
});

test('real backup renderer retains native point fonts, panel insets and full proposed width on a roomy window',()=>{
  render(fixture(<AccountBackupFlowAdapter id="backup-visit" state={backup}/>));
  expect(font('Encrypted on this device. Only you can unlock your backup.')).toBe(15);
  expect(font('This device')).toBe(17);expect(font('A local unlock key stays on this device.')).toBe(17);
  expect(font(localized('Set up with Passkey'))).toBe(17);
  const introduction=screen.UNSAFE_getAllByType(Group).find(node=>node.props.tone==='green')!;
  expect(within(introduction).getByText('Encrypted on this device. Only you can unlock your backup.')).toBeTruthy();
  expect(introduction.findAllByType(Symbol)).toHaveLength(0);
  expect(screen.UNSAFE_getByType(ScrollView).props.contentContainerStyle).toMatchObject({maxWidth:960,paddingHorizontal:18});
  sibling();
});

test('migrated iOS information panels keep native optional borders and canonical geometry without changing ordinary RN panels',()=>{
  render(fixture(<NativeFlowMetrics>
    <FlowInfo title="Review import" description="The selected filter keeps its name. Review the content changes below."/>
    <FlowInfo title="Explicit warning" warning/>
    <NativeInfoPanel accent={colors.errorText}><View/></NativeInfoPanel>
    <OrdinaryPanel><View/></OrdinaryPanel>
  </NativeFlowMetrics>));
  const panels:ReturnType<typeof screen.getByTestId>[]=screen.UNSAFE_getAllByType(LavaSurface).filter(node=>node.props.role==='panel');
  expect(panels).toHaveLength(4);
  const viewStyles=(panel:{findAllByType:(type:typeof View)=>{props:{style?:StyleProp<ViewStyle>}}[]})=>panel.findAllByType(View).map(node=>StyleSheet.flatten(node.props.style) as ViewStyle|undefined);
  const colorsByPanel=panels.map(panel=>viewStyles(panel).filter((style):style is ViewStyle=>style?.borderWidth!==undefined).map(style=>style.borderColor));
  // LavaTokens203–205 draws the panel outline only for an explicit borderTint.
  expect(colorsByPanel[0]).toEqual([]);
  expect(colorsByPanel[1]).toEqual([colors.lavaOrange]);
  expect(colorsByPanel[2]).toEqual([colors.errorText]);
  expect(colorsByPanel[3]).toEqual([colors.panelStroke]);
  for(const panel of panels){
    expect(panel.props.contentStyle).toEqual({paddingHorizontal:16,paddingVertical:12});
    const fill=viewStyles(panel).find(style=>style?.backgroundColor!==undefined)!;
    expect(fill).toMatchObject({borderRadius:24,borderCurve:'continuous',overflow:'hidden',backgroundColor:colors.panelBackground});
  }
});

test.each([
  {category:'extraSmall',fontSize:14,naturalHeight:17,cardHeight:58},
  {category:'large',fontSize:17,naturalHeight:61/3,cardHeight:58},
  {category:'multiline',fontSize:17,naturalHeight:64,cardHeight:88},
])('native information panel floors and centers only short content at $category',({fontSize,naturalHeight,cardHeight})=>{
  render(fixture(<NativeFlowMetrics><FlowInfo title="Ready after sign-in"/></NativeFlowMetrics>,{headline:fontSize/17}));
  let header=screen.UNSAFE_getByType(Inline);
  expect(header.props.fontSize).toBeCloseTo(fontSize);
  fireEvent(header,'layout',{nativeEvent:{layout:{width:300,height:22*fontSize/17}}});
  header=screen.UNSAFE_getByType(Inline);
  fireEvent(header,'sizeChange',{nativeEvent:{measurementID:header.props.measurementID,width:300,height:naturalHeight}});
  header=screen.UNSAFE_getByType(Inline);
  expect(StyleSheet.flatten(header.props.style).height).toBe(naturalHeight);
  let body=header.parent;
  while(body&&StyleSheet.flatten(body.props.style)?.minHeight===undefined)body=body.parent;
  const bodyStyle=StyleSheet.flatten(body!.props.style);
  expect(bodyStyle).toEqual({minHeight:34,justifyContent:'center'});
  const panel=screen.UNSAFE_getByType(LavaSurface);
  expect(panel.props.contentStyle).toEqual({paddingHorizontal:16,paddingVertical:12});
  // ec1b LavaInfoCard533 uses LavaRowHeight.standard58, vertically centered.
  // The real inline atom's measured size remains authoritative above that floor.
  expect(Math.max(bodyStyle.minHeight,naturalHeight)+2*panel.props.contentStyle.paddingVertical).toBeCloseTo(cardHeight);
});

test('real import completion keeps its fixed result glyph and semantic type while its viewport can rotate',()=>{
  const state:ImportState={stage:'completed',stageID:'stage',direction:'forward',code:'',error:'',cameraDenied:false,checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:'',completed:{message:'Filter imported',unavailable:''}};
  const content=()=>fixture(<ImportFlowAdapter id="import-visit" state={state}/>);
  const view=render(content());
  const glyph=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='checkmark.circle.fill')!;
  expect(glyph.props.fontPointSize).toBe(56);expect(glyph.props.fontWeight).toBe('regular');
  // iOS 27 UIHostingController + UIImage agree on 66pt natural regular56 geometry.
  expect(StyleSheet.flatten(glyph.props.style)).toMatchObject({width:66,height:66});
  expect(font('Done')).toBe(17);
  mockWindow={...mockWindow,width:1280,height:960};view.rerender(content());
  expect(font('Done')).toBe(17);
  expect(screen.UNSAFE_getByType(ScrollView).props.contentContainerStyle.maxWidth).toBe(1280);
  sibling();
});

test('real import menu and replacement rows retain the native twelve-point accessory slot and font',()=>{
  const base:ImportState={stage:'chooseMethod',stageID:'menu',direction:'forward',code:'',error:'',cameraDenied:false,checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:''};
  const view=render(fixture(<ImportFlowAdapter id="import-menu" state={base}/>));
  const check=(symbols:string[])=>{
    const accessories=screen.UNSAFE_getAllByType(Decoration).filter(node=>symbols.includes(node.props.symbol));
    expect(accessories).toHaveLength(symbols.length);
    for(const glyph of accessories){
      expect(glyph.props.fontPointSize).toBe(12);expect(glyph.props.fontWeight).toBe('regular');
      expect(StyleSheet.flatten(glyph.props.style)).toMatchObject({width:12,height:glyph.props.symbol==='chevron.right'?38/3:41/3});
      let parent=glyph.parent;
      while(parent&&StyleSheet.flatten(parent.props.style)?.minWidth===undefined)parent=parent.parent;
      expect(StyleSheet.flatten(parent!.props.style)).toMatchObject({minWidth:12,alignItems:'center'});
    }
  };
  check(['chevron.right','chevron.right','chevron.right']);
  view.unmount();
  render(fixture(<ImportFlowAdapter id="import-menu" state={{...base,stage:'chooseReplace',stageID:'targets',targets:[
    {id:'active',name:'In-effect filter',summary:'100 rules',locked:false},
    {id:'locked',name:'Locked filter',summary:'Locked',locked:true},
  ]}}/>));
  check(['chevron.right','lock.fill']);
  sibling();
});

test.each(['light','dark'] as const)('native-flow groups use semantic dividers in %s appearance while ordinary RN groups retain their paint',scheme=>{
  const content=(separators=true)=>fixture(<LavaAppearanceContext.Provider value={scheme}>
    <Group testID="ordinary.group"><View/><View/></Group>
    <NativeFlowMetrics><Group testID="native.group" dividerInset={24} separators={separators}><View/><View/></Group></NativeFlowMetrics>
  </LavaAppearanceContext.Provider>);
  const view=render(content());
  const native=screen.getByTestId('native.group');
  const lines=native.findAllByType(Decoration);
  expect(lines).toHaveLength(1);
  const line=lines[0]!;
  expect(line.props).toMatchObject({symbol:'form.separator',colorScheme:scheme,guardianGestures:false,pointerEvents:'none',accessible:false,
    accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  expect(StyleSheet.flatten(line.props.style)).toEqual({height:StyleSheet.hairlineWidth,backgroundColor:'transparent',marginHorizontal:16,marginLeft:24});
  const ordinary=screen.getByTestId('ordinary.group');
  expect(ordinary.findAllByType(Decoration)).toHaveLength(0);
  expect(within(ordinary).UNSAFE_getAllByType(View).some(node=>StyleSheet.flatten(node.props.style)?.backgroundColor===colors.separator)).toBe(true);
  view.rerender(content(false));
  expect(screen.getByTestId('native.group').findAllByType(Decoration)).toHaveLength(0);
});

test.each(['backupSetup','backupRestore'] as const)('%s success retains the measured native regular56 glyph geometry',kind=>{
  render(fixture(<AccountBackupFlowAdapter id="complete-visit" state={{...backup,kind,success:true}}/>));
  const glyph=screen.UNSAFE_getByType(Decoration);
  expect(glyph.props.fontPointSize).toBe(56);expect(glyph.props.fontWeight).toBe('regular');
  expect(StyleSheet.flatten(glyph.props.style)).toMatchObject({width:66,height:66});
});

test('account and backup semantic glyph fonts follow their native Dynamic Type ramps without enlarging slots',()=>{
  const scales={headline:1.8,body:1.6,title3:1.4,subheadline:1.5};
  const view=render(fixture(<AccountBackupFlowAdapter id="backup-visit" state={backup}/>,scales));
  const fact=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='key')!;
  expect(fact.props.fontPointSize).toBeCloseTo(17*1.8);expect(StyleSheet.flatten(fact.props.style)).toMatchObject({width:24,height:24});
  view.rerender(fixture(<AccountBackupFlowAdapter id="account-visit" state={{...backup,kind:'account',connections:[{provider:'apple',title:'Apple account'},{provider:'google',title:'Google account'}]}}/>,scales));
  const glyph=(symbol:string)=>screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol===symbol)!;
  for(const symbol of ['apple.logo','rectangle.portrait.and.arrow.right','trash']){
    expect(glyph(symbol).props.fontPointSize).toBeCloseTo(20*1.4);expect(StyleSheet.flatten(glyph(symbol).props.style)).toMatchObject({width:28,height:28});
  }
  expect(glyph('google.signin').props.fontPointSize).toBe(20);
  view.rerender(fixture(<AccountBackupFlowAdapter id="restore-visit" state={{...backup,kind:'backupRestore',mode:'passkey'}}/>,scales));
  expect(glyph('person.badge.key').props.fontPointSize).toBeCloseTo(15*1.5);
  expect(StyleSheet.flatten(glyph('person.badge.key').props.style)).toMatchObject({width:20,height:20});
  sibling(1.6);
});

test('real passcode renderer preserves Dynamic Type without a window multiplier or enlarged native glyph',()=>{
  render(fixture(<PasscodeFlowAdapter state={{id:'passcode-visit',authenticating:true,title:'Enter Passcode',subtitle:'Unlock Lava',message:'Wrong passcode'}}/>,{title1:1.5,subheadline:1.6,footnote:1.7,body:1.6}));
  expect(screen.getByTestId('passcode.title').props.fontSize).toBeCloseTo(28*1.5);
  expect(screen.getByTestId('passcode.subtitle').props.fontSize).toBeCloseTo(15*1.6);
  expect(screen.getByTestId('passcode.message').props.fontSize).toBeCloseTo(13*1.7);
  const glyph=screen.UNSAFE_getByType(Decoration);
  expect(glyph.props.fontPointSize).toBe(44);expect(glyph.props.fontWeight).toBe('semibold');
  // The original Image's actual layout is47×51⅓pt. Isolated hosting's
  // sizeThatFits rounds this up; that ceiling must not size the surrounding stack.
  const slot=StyleSheet.flatten(glyph.props.style);expect(slot.width).toBe(47);expect(slot.height).toBeCloseTo(154/3);
  sibling(1.6);
});

test.each([{width:402,height:874},{width:960,height:1280}])('passcode uses its native fixed-font symbol slot at maximum Dynamic Type in a $width pt window',viewport=>{
  mockWindow={...mockWindow,...viewport};
  render(fixture(<PasscodeFlowAdapter state={{id:'passcode-visit',authenticating:true,title:'Enter Passcode',subtitle:'Unlock Lava',message:''}}/>,
    {title1:58/28,subheadline:49/15,body:53/17},undefined,undefined,{passcodeLock:{fontSize:44,width:48,height:52}}));
  const glyph=screen.UNSAFE_getByType(Decoration);
  expect(glyph.props).toMatchObject({symbol:'lock.shield.fill',fontPointSize:44,fontWeight:'semibold'});
  // Public symbol metrics can vary across OS/display assets. Use the admitted
  // natural dimensions rather than scaling them with either text or the window.
  expect(StyleSheet.flatten(glyph.props.style)).toEqual({width:48,height:52});
  expect(screen.getByTestId('passcode.title').props.fontSize).toBeCloseTo(58);
  expect(screen.getByTestId('passcode.subtitle').props.fontSize).toBeCloseTo(49);
});

test.each([
  {fontSize:43,width:48,height:52},
  {fontSize:NaN,width:48,height:52},
  {fontSize:44,width:0,height:52},
  {fontSize:44,width:Infinity,height:52},
  {fontSize:44,width:48,height:-1},
  {fontSize:44,width:48,height:NaN},
])('passcode ignores stale or invalid natural symbol metrics (%j)',passcodeLock=>{
  render(fixture(<PasscodeFlowAdapter state={{id:'passcode-visit',authenticating:true,title:'Enter Passcode',subtitle:'Unlock Lava',message:''}}/>,
    null,undefined,undefined,{passcodeLock}));
  const glyph=screen.UNSAFE_getByType(Decoration);
  expect(glyph.props.fontPointSize).toBe(44);
  expect(StyleSheet.flatten(glyph.props.style)).toEqual({width:47,height:154/3});
});

test('QA adapter hooks inherit native metrics before configuring native text fields and system buttons',()=>{
  render(fixture(<QAFlowAdapter id={qa.id}/>,{body:1.6,headline:1.8,footnote:1.7,title3:1.3}));
  // QA uses the shared Screen directly, without a native View above its scroll.
  const page=screen.getByTestId('device-qa-page');
  expect(page.type).toBe('RCTScrollView');
  expect(screen.UNSAFE_getByType(Screen).props.testID).toBe('device-qa-page');
  expect(screen.queryByTestId('qa.surface')).toBeNull();
  expect(screen.UNSAFE_getByType(Configuration).props.fontSize).toBeCloseTo(13*1.7);
  expect(screen.UNSAFE_getAllByType(SystemButton).find(node=>node.props.title==='Stage upstream')!.props.fontSize).toBeCloseTo(17*1.6);
  expect(screen.UNSAFE_getByType(Inline).props.fontSize).toBeCloseTo(17*1.8);
  const detailGlyph=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='swiftui.sf:doc.on.clipboard')!;
  expect(detailGlyph.props.fontPointSize).toBeCloseTo(20*1.3);
  expect(screen.getByText('Stage upstream from .conf').props.numberOfLines).toBeUndefined();
  sibling(1.6);
});

test('Device QA retains the native system navigation title and compact diagnostic search anatomy',()=>{
  render(fixture(<QAFlowAdapter id={qa.id}/>,{body:1.6,subheadline:1.4}));
  const options=mockNavigation.setOptions.mock.calls.map(([value])=>value).find(value=>value.title==='Device QA');
  expect(options).toMatchObject({headerTitleStyle:{color:PlatformColor('label')},headerLargeTitleStyle:{color:PlatformColor('label')}});
  const field=screen.UNSAFE_getAllByType(NativeTextField).find(node=>node.props.placeholder==='Search Device QA')!;
  expect(field.props).toMatchObject({kind:'localLogSearch',keyboardType:'url',clearButtonMode:'never',
    placeholderTextColor:PlatformColor('placeholderText'),fontPointSize:17*1.6,autoCapitalize:'none',autoCorrect:false});
  const search=screen.UNSAFE_getAllByType(LavaSurface).find(node=>node.props.cornerRadius===16)!;
  expect(StyleSheet.flatten(search.props.contentStyle)).toMatchObject({height:48,minHeight:48,paddingHorizontal:16,gap:10,borderRadius:16,backgroundColor:colors.panelBackground});
  expect(search.props.borderColor).toEqual(DynamicColorIOS({light:'rgba(199,212,197,0.65)',dark:'rgba(69,69,69,0.65)'}));
  const magnifier=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='magnifyingglass')!;
  expect(magnifier.props).toMatchObject({fontPointSize:15*1.4,fontWeight:'semibold',tone:'secondary'});
  expect(StyleSheet.flatten(magnifier.props.style)).toMatchObject({width:18,height:18});
  const borders=search.findAllByType(View).map((node:ReturnType<typeof screen.getByTestId>)=>StyleSheet.flatten(node.props.style) as ViewStyle|undefined).filter((style:ViewStyle|undefined)=>style?.borderWidth===1);
  expect(borders).toHaveLength(1);expect(borders[0]).toMatchObject({borderRadius:16,borderCurve:'continuous',overflow:'hidden'});
  act(()=>field.props.onChange({nativeEvent:{text:'network'}}));
  const typed=screen.UNSAFE_getAllByType(NativeTextField).find(node=>node.props.placeholder==='Search Device QA')!;
  expect(typed.props.value).toBe('network');
  const revision=typed.props.resetRevision;
  const clearGlyph=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='xmark.circle.fill')!;
  expect(clearGlyph.props).toMatchObject({fontPointSize:17*1.6,fontWeight:'semibold',tone:'secondary'});
  fireEvent.press(screen.getByRole('button',{name:'Clear search'}));
  const cleared=screen.UNSAFE_getAllByType(NativeTextField).find(node=>node.props.placeholder==='Search Device QA')!;
  expect(cleared.props.value).toBe('');expect(cleared.props.resetRevision).toBeGreaterThan(revision);
  expect(screen.queryByRole('button',{name:'Clear search'})).toBeNull();
  sibling(1.6);
});

test('diagnostic clear and external resets each reset the native buffer even when revision values repeat',()=>{
  const onChange=jest.fn();
  const content=(value:string,resetRevision:number)=><NativeFlowMetrics><Search surface="localLog" label="Search Device QA" value={value} resetRevision={resetRevision} onChange={onChange}/></NativeFlowMetrics>;
  const view=render(fixture(content('first',5)));
  const input=()=>screen.UNSAFE_getByType(NativeTextField);
  const start=input().props.resetRevision;
  fireEvent.press(screen.getByRole('button',{name:'Clear search'}));
  expect(onChange).toHaveBeenCalledWith('');expect(input().props.resetRevision).toBeGreaterThan(start);
  const clear=input().props.resetRevision;
  view.rerender(fixture(content('second',4)));
  expect(input().props.resetRevision).toBeGreaterThan(clear);expect(input().props.value).toBe('second');
  const reset=input().props.resetRevision;
  view.rerender(fixture(content('third',5)));
  expect(input().props.resetRevision).toBeGreaterThan(reset);expect(input().props.value).toBe('third');
});

test('diagnostic clear uses measured native symbol bounds at maximum text size while magnifier keeps its18pt slot',()=>{
  const content=<NativeFlowMetrics><Search surface="localLog" label="Search Device QA" value="network" onChange={()=>{}}/></NativeFlowMetrics>;
  render(fixture(content,{body:53/17,subheadline:49/15},undefined,undefined,{searchClear:{fontSize:53,width:190/3,height:190/3}}));
  const clear=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='xmark.circle.fill')!;
  expect(clear.props.fontPointSize).toBe(53);
  expect(StyleSheet.flatten(clear.props.style)).toEqual({width:190/3,height:190/3});
  const magnifier=screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='magnifyingglass')!;
  expect(magnifier.props.fontPointSize).toBe(49);expect(StyleSheet.flatten(magnifier.props.style).width).toBe(18);
});

test('shared QA and ordinary searches retain their existing platform defaults without an iOS search port',()=>{
  const send=jest.fn();
  render(fixture(<><QAScreen state={qa} port={{send,configuration:null,glyph:()=>null,fieldBackground:'transparent',localize:text=>text,textScale:1}}/>
    <Search label="Search domains" value="" onChange={()=>{}}/>
  </>));
  for(const label of ['Search Device QA','Search domains']){
    const field=screen.UNSAFE_getAllByType(NativeTextField).find(node=>node.props.placeholder===label)!;
    expect(field.props).toMatchObject({kind:'search',clearButtonMode:'while-editing',placeholderTextColor:colors.secondaryText});
    expect(field.props.keyboardType).toBeUndefined();
  }
  expect(screen.UNSAFE_getAllByType(LavaSurface).filter(node=>node.props.cornerRadius===16)).toHaveLength(0);
  const field=screen.UNSAFE_getAllByType(NativeTextField).find(node=>node.props.placeholder==='Search Device QA')!;
  act(()=>field.props.onChange({nativeEvent:{text:'network'}}));
  expect(send).toHaveBeenCalledWith({action:'search',value:'network'});
});

test('real DNS help keeps native scrolling and the shared tablet reading band',()=>{
  render(fixture(<DNSPatchScreen/>));
  expect(screen.UNSAFE_getByType(Screen)).toBeTruthy();
  expect(screen.UNSAFE_queryByType(KeyboardAvoidingView)).toBeNull();
  const scroll=screen.UNSAFE_getByType(ScrollView);
  expect(scroll.props.contentInsetAdjustmentBehavior).toBe('automatic');
  expect(StyleSheet.flatten(scroll.props.contentContainerStyle)).toMatchObject({width:'100%',maxWidth:880,paddingHorizontal:18*1.4,paddingTop:28,paddingBottom:44});
  expect(screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='checkmark.circle.fill')!.props.fontPointSize).toBe(20*1.4);
  sibling();
});

test('ordinary Screen callers retain their existing content clearances without an override',()=>{
  render(fixture(<NativeFlowMetrics><Screen><View testID="ordinary.page"/></Screen></NativeFlowMetrics>));
  expect(StyleSheet.flatten(screen.UNSAFE_getByType(ScrollView).props.contentContainerStyle)).toMatchObject({maxWidth:960,paddingHorizontal:18,paddingTop:16,paddingBottom:96});
  expect(screen.UNSAFE_queryByType(KeyboardAvoidingView)).toBeNull();
  sibling();
});

test('native flow metrics survive fitted-sheet viewport measurement without falsifying dimensions or orientation',()=>{
  function Probe(){const layout=useWindowLayout(),textScale=useTextScale('body');return <View testID="native.metrics" accessibilityValue={{text:JSON.stringify({...layout,textScale})}}/>;}
  render(fixture(<NativeFlowMetrics><FlowSheet><Probe/></FlowSheet></NativeFlowMetrics>,{body:1.6}));
  const metrics=()=>JSON.parse(screen.getByTestId('native.metrics').props.accessibilityValue.text);
  expect(metrics()).toMatchObject({width:960,height:1280,readingWidth:960,scale:1,spacingScale:1,insetScale:1,textScale:1.6,landscape:false});
  fireEvent(screen.UNSAFE_getByType(KeyboardAvoidingView),'layout',{nativeEvent:{layout:{width:624,height:500,x:0,y:0}}});
  expect(metrics()).toMatchObject({width:624,height:500,readingWidth:624,scale:1,spacingScale:1,insetScale:1,textScale:1.6,landscape:true});
  sibling(1.6);
});


test.each([false,true])('account and backup use only native-authored system label colors through iOS injection %s',ios=>{
  jest.useFakeTimers();try{
  const label=ios?PlatformColor('label'):colors.primaryText;
  const secondary=ios?PlatformColor('secondaryLabel'):colors.secondaryText;
  const paint=(text:string)=>StyleSheet.flatten(screen.getByText(text).props.style).color;
  const content=(state:AccountBackupFlowState)=>fixture(ios?<AccountBackupFlowAdapter id="color-visit" state={state}/>
    :<NativeFlowMetrics><AccountBackupFlow state={state} command={()=>{}} confirmAccountDeletion={()=>{}}/></NativeFlowMetrics>);
  const view=render(content(backup));
  // BackupSetupFactRow uses .primary; its helper retains Lava's secondary ink.
  expect(paint('This device')).toEqual(label);
  expect(paint('A local unlock key stays on this device.')).toEqual(colors.secondaryText);
  if(ios)expect(paint('Encrypted on this device. Only you can unlock your backup.')).toEqual(colors.primaryText);
  else expect(screen.UNSAFE_getByType(Inline).props.textColor).toEqual(colors.ink);
  view.rerender(content({...backup,kind:'account',connections:[{provider:'apple',title:'private@example.com'}]}));
  expect(paint('private@example.com')).toEqual(label);
  expect(paint(localized('Sign out of all accounts'))).toEqual(colors.primaryText);
  expect(screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='apple.logo')!.props.tone).toBe('primary');
  view.rerender(content({...backup,kind:'backupRestore',mode:'passkey'}));
  expect(paint(localized('Use your saved passkey'))).toEqual(label);
  expect(screen.UNSAFE_getAllByType(Decoration).find(node=>node.props.symbol==='person.badge.key')!.props.tone).toBe(ios?'label':'primary');
  view.rerender(content({...backup,kind:'backupRestore',review:[
    {id:'settings',rows:[{title:'Primary DNS',before:'Device',after:'Private',notes:['Added: 1: added.example']}],notes:[]},
    {id:'filter',rows:[{title:'Filters',before:'Before',after:'After'}],notes:[{text:'Saved list content will change for: My list',role:'contentChange'},
      {text:'Cached rules may be replaced or unavailable.',role:'cacheWarning'}]},
  ]}));
  expect(paint('Current → Backup')).toEqual(secondary);
  expect(paint('Primary DNS')).toEqual(label);expect(paint('Device → Private')).toEqual(secondary);
  expect(paint('Filters')).toEqual(label);expect(paint('Before → After')).toEqual(secondary);
  expect(paint('Added: 1: added.example')).toEqual(label);
  expect(paint('Saved list content will change for: My list')).toEqual(label);
  // .lavaQuietNoteText remains the app's secondary, distinct from .secondary.
  expect(paint('Cached rules may be replaced or unavailable.')).toEqual(colors.secondaryText);
  view.rerender(content({...backup,success:true}));
  expect(paint(localized('Backup is ready'))).toEqual(colors.primaryText);
  expect(paint('Your encrypted backup is set up on this device.')).toEqual(colors.secondaryText);
  view.unmount();
  }finally{jest.clearAllTimers();jest.useRealTimers();}
});

test.each([false,true])('replacement import preserves platform label injection %s and explicit Lava information/success colors',ios=>{
  jest.useFakeTimers();try{
  const label=ios?PlatformColor('label'):colors.primaryText;
  const paint=(text:string)=>StyleSheet.flatten(screen.getByText(text).props.style).color;
  const state:ImportState={stage:'reviewReplacement',stageID:'review',direction:'forward',code:'',error:'',cameraDenied:false,checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:'',
    replacement:{name:'My private filter',removed:'Removed: 1 blocklist',groups:[{title:'Blocked domains',removed:['old.example'],added:['new.example']}]}};
  const content=(value:ImportState)=>fixture(ios?<ImportFlowAdapter id="import-color" state={value}/>
    :<NativeFlowMetrics><ImportFlow state={value} port={{command:async()=>null,scanner:null}}/></NativeFlowMetrics>);
  const view=render(content(state));
  // The unstyled native review name, labels and selectable values use .primary.
  for(const text of ['My private filter','Removed','Added','old.example','new.example'])expect(paint(text)).toEqual(label);
  expect(paint('Removed: 1 blocklist')).toEqual(colors.secondaryText);
  expect(screen.UNSAFE_getByType(Inline).props.textColor).toEqual(colors.ink);
  view.rerender(content({...state,stage:'completed',stageID:'complete',completed:{message:'Imported successfully',unavailable:''}}));
  expect(paint(localized('Filter imported'))).toEqual(colors.primaryText);
  expect(paint('Imported successfully')).toEqual(colors.secondaryText);
  view.unmount();
  }finally{jest.clearAllTimers();jest.useRealTimers();}
});


test('backup setup keeps its padded15pt consent rows while restore uses the native plain17pt toggle anatomy',()=>{
  const first='I have saved my recovery phrase in a secure, accessible place';
  const second='I understand that if I lose every unlock method, I may not be able to restore my backup';
  const view=render(fixture(<AccountBackupFlowAdapter id="setup-consent" state={{...backup,step:'recoveryPhrase'}}/>));
  for(const text of [first,second])expect(StyleSheet.flatten(screen.getByText(localized(text)).props.style)).toMatchObject({fontSize:15,fontWeight:'600',color:PlatformColor('label')});
  const controls=screen.UNSAFE_getAllByType(NativeSwitch);expect(controls).toHaveLength(2);
  expect(controls.every(control=>control.props.optimistic===false)).toBe(true);
  view.rerender(fixture(<AccountBackupFlowAdapter id="restore-consent" state={{...backup,kind:'backupRestore',review:[],resolverConfirmationRequired:true}}/>,{body:1.5}));
  const row=StyleSheet.flatten(screen.getByTestId('backup.restore.consent.row').props.style);
  expect(row).toEqual({flexDirection:'row',alignItems:'center',gap:8});
  expect(StyleSheet.flatten(screen.getByTestId('backup.restore.consent.title').props.style)).toMatchObject({fontSize:25.5,fontWeight:'400',color:PlatformColor('label')});
  expect(screen.UNSAFE_getByType(NativeSwitch).props.optimistic).toBe(false);
});

test('plain form consent shares one flight across label and native gestures and never claims the unconfirmed value',async()=>{
  let finish!:()=>void;const pending=new Promise<void>(resolve=>{finish=resolve;});const onChange=jest.fn(()=>pending);
  const content=(value=false,disabled=false)=><FlowConsentToggle title="I confirm these DNS changes" value={value} disabled={disabled} onChange={onChange} labelColor={PlatformColor('label')} testID="consent"/>;
  const view=render(content());
  fireEvent.press(screen.getByTestId('consent.label'));
  fireEvent(screen.getByTestId('consent'),'valueChange',{nativeEvent:{value:true}});
  expect(onChange.mock.calls).toEqual([[true]]);
  expect(screen.getByTestId('consent').props).toMatchObject({value:false,pending:true,optimistic:false});
  await act(async()=>finish());
  expect(screen.getByTestId('consent').props.value).toBe(false);
  view.rerender(content(true,true));
  fireEvent.press(screen.getByTestId('consent.label'));
  fireEvent(screen.getByTestId('consent'),'valueChange',{nativeEvent:{value:false}});
  expect(onChange).toHaveBeenCalledTimes(1);
  expect(screen.getByTestId('consent').props).toMatchObject({value:true,disabled:true});
});

test('QA verification retains its native plain body label and platform label paint without a list-row floor',()=>{
  const step='Verify this procedure step on the active tunnel before recording an outcome.';
  const detail:QADetail={id:'check',kind:'check',title:'Guided check',steps:[step],prepared:true,configurationMatches:true,verified:false};
  const view=render(fixture(<QAFlowAdapter id={qa.id}/>,{body:1.5},detail));
  for(const row of screen.getAllByTestId('qa.verified.row'))expect(StyleSheet.flatten(row.props.style)).toEqual({flexDirection:'row',alignItems:'center',gap:8});
  for(const title of screen.getAllByTestId('qa.verified.title'))expect(StyleSheet.flatten(title.props.style)).toMatchObject({fontSize:25.5,fontWeight:'400',color:PlatformColor('label')});
  // ec1b AdminQAView437–441 → LavaCondensedListItem's default titleLineLimit2.
  for(const title of screen.getAllByText(step))expect(title.props.numberOfLines).toBe(2);
  const controls=screen.UNSAFE_getAllByType(NativeSwitch);expect(controls.length).toBeGreaterThan(0);
  for(const control of controls)expect(control.props).toMatchObject({value:false,optimistic:false,disabled:false});
  view.unmount();
  const send=jest.fn();
  const content=(prepared=true)=><QADetailScreen state={{...detail,prepared}} port={{send,configuration:null,glyph:()=>null,fieldBackground:colors.cardBackground,localize:text=>text,textScale:1}}/>;
  const shared=render(fixture(content()));
  expect(StyleSheet.flatten(screen.getByTestId('qa.verified.title').props.style).color).toBe(colors.primaryText);
  fireEvent.press(screen.getByTestId('qa.verified.label'));
  expect(send).toHaveBeenCalledWith({action:'verified',value:true});
  expect(screen.getByTestId('qa.verified').props.value).toBe(false);
  shared.rerender(fixture(content(false)));
  fireEvent.press(screen.getByTestId('qa.verified.label'));
  fireEvent(screen.getByTestId('qa.verified'),'valueChange',{nativeEvent:{value:true}});
  expect(send).toHaveBeenCalledTimes(1);
});

test('QA condensed root and scenario titles share their original two-line limit while staging titles stay unlimited',()=>{
  const send=jest.fn();const port={send,configuration:null,glyph:()=>null,fieldBackground:colors.cardBackground,localize:(text:string)=>text,textScale:1};
  const detail:QADetail={id:'suite',kind:'suite',title:'Guided checks',name:'Guided checks',rows:[{id:'scenario',title:'A long guided network scenario title',subtitle:'Not run'}]};
  render(fixture(<><QAScreen state={{...qa,sections:[{title:'Checks',rows:[{id:'root',title:'A long QA menu action title',subtitle:'Explanation'}]}]}} port={port}/><QADetailScreen state={detail} port={port}/></>));
  expect(screen.getByText('A long QA menu action title').props.numberOfLines).toBe(2);
  expect(screen.getByText('A long guided network scenario title').props.numberOfLines).toBe(2);
});

test('shared DNS copy outside the migrated iOS context retains ordinary RN defaults',()=>{
  mockWindow={...mockWindow,width:390,height:844};
  render(fixture(<DNSHelpScreen profileEnabled={false} port={{openDNS(){},openVPN(){},openSettings(){},openSupport(){},profileGlyph:null}}/>));
  expect(screen.UNSAFE_getByType(FlowSheet)).toBeTruthy();
  expect(screen.UNSAFE_getByType(KeyboardAvoidingView)).toBeTruthy();
  const paragraph=screen.getByText('To keep Lava effective, choose one of these options.');
  expect(StyleSheet.flatten(paragraph.props.style).fontSize).toBe(15);
  expect(StyleSheet.flatten(paragraph.props.style).lineHeight).toBeUndefined();
  expect(paragraph.props.lineBreakStrategyIOS).toBeUndefined();
  expect(screen.queryByTestId('dns.instruction.row')).toBeNull();
  const rows=screen.UNSAFE_getAllByType(View).filter(node=>StyleSheet.flatten(node.props.style)?.alignItems==='baseline');
  expect(rows).toHaveLength(9);
});

// iOS27 detached SwiftUI Text("Ag", "Ag\\nAg", "Ag\\nAg\\nAg") at3x:
// native-text-metrics-preferred.log. UIFont's semantic leading is negative atAX5.
const measuredText={
  normal:{
    title1:{fontSize:28,lineHeight:33.4140625,leading:.5859375},
    subheadline:{fontSize:15,lineHeight:17.900390625,leading:2.099609375},
    body:{fontSize:17,lineHeight:20.287109375,leading:1.712890625},
    headline:{fontSize:17,lineHeight:20.287109375,leading:1.712890625},
    footnote:{fontSize:13,lineHeight:15.513671875,leading:2.486328125},
  },
  accessibility5:{
    title1:{fontSize:58,lineHeight:69.21484375,leading:-1.21484375},
    subheadline:{fontSize:49,lineHeight:58.474609375,leading:-.474609375},
    body:{fontSize:53,lineHeight:63.248046875,leading:-1.248046875},
    headline:{fontSize:53,lineHeight:63.248046875,leading:-1.248046875},
    footnote:{fontSize:44,lineHeight:52.5078125,leading:-.5078125},
  },
};
test.each([[390,844],[1194,834],[834,1194],[420,1032]])('DNS and Auto-switch share typography at %i by %i, including accessibility text',(width,height)=>{
  mockWindow={...mockWindow,width,height};
  const scale=windowLayout(mockWindow).scale;
  const content=(textScale:number)=>fixture(<><DNSPatchScreen/><AutoSwitchScreen/></>,{body:textScale,subheadline:textScale,headline:textScale},undefined,measuredText.normal);
  render(content(1));
  for(const textScale of [1,1.6,3]){
    screen.rerender(content(textScale));
    const dns=font('Open DNS settings and configure System DNS.');
    const auto=font('In Shortcuts, create an automation for a time, place, or event.');
    expect(dns).toBeCloseTo(15*scale*textScale);
    expect(dns).toBe(auto);
    expect(font('To keep Lava effective, choose one of these options.')).toBe(dns);
  }
});
test.each(['normal','accessibility5'] as const)('migrated iOS semantic text keeps measured first/last boxes and multiline advances at %s',category=>{
  const pixelRatio=jest.spyOn(PixelRatio,'get').mockReturnValue(3);
  try{
    const metrics=measuredText[category];
    const scales=Object.fromEntries(Object.entries(metrics).map(([ramp,metric])=>[ramp,metric.fontSize/(ramp==='title1'?28:ramp==='subheadline'?15:ramp==='footnote'?13:17)]));
    const content=(explicitScales:Record<string,number>|null)=>fixture(<>
      <AccountBackupFlowAdapter id="measured-overview" state={backup}/>
      <NativeFlowMetrics><Copy role="row" testID="measured.row">A wrapping row title</Copy><Copy role="caption" testID="measured.note">A wrapping error message</Copy>
        <FormParagraph textRole="body" testID="measured.paragraph">A wrapping native paragraph</FormParagraph>
        <Text testID="measured.title" dynamicTypeRamp="title1" style={{fontSize:28,fontWeight:'700'}}>A wrapping native title</Text></NativeFlowMetrics>
    </>,explicitScales,undefined,metrics);
    const approximateScales=Object.fromEntries(Object.entries(scales).map(([ramp,value])=>[ramp,value+.003]));
    const view=render(content(approximateScales));
    const check=(node:ReturnType<typeof screen.getByTestId>,ramp:keyof typeof metrics)=>{
      const metric=metrics[ramp],style=StyleSheet.flatten(node.props.style),actualLine=style.lineHeight;
      const natural=Math.ceil(metric.lineHeight*3)/3,advance=metric.lineHeight+metric.leading;
      expect(style.fontSize).toBeCloseTo(metric.fontSize);
      expect(actualLine).toBeCloseTo(advance);expect(node.props.lineBreakStrategyIOS).toBe('standard');
      expect(node.props.allowFontScaling).toBe(false);
      for(const count of [1,2,3])expect(actualLine*count+2*style.marginVertical).toBeCloseTo(natural+advance*(count-1));
    };
    for(const explicit of [true,false]){
      if(!explicit)view.rerender(content(null));
      check(screen.getByText('This device'),'headline');
      check(screen.getByText('A local unlock key stays on this device.'),'body');
      check(screen.getByTestId('measured.row'),'subheadline');
      check(screen.getByTestId('measured.note'),'footnote');
      check(screen.getByTestId('measured.paragraph'),'body');
      check(screen.getByTestId('measured.title'),'title1');
      // An existing RN sibling consumes only its original viewport/text scaling.
      sibling(explicit?approximateScales.body:1);
      expect(StyleSheet.flatten(screen.getByTestId('responsive.sibling').props.style).lineHeight).toBeUndefined();
    }
  }finally{pixelRatio.mockRestore();}
});

test('native paragraph policy preserves explicit typography and never enters Android or ordinary RN siblings',()=>{
  const content=()=>fixture(<NativeFlowMetrics>
    <Text testID="explicit.line" dynamicTypeRamp="subheadline" style={{fontSize:15,lineHeight:31,marginVertical:4}}>Explicit line metrics</Text>
    <Text testID="monospace" dynamicTypeRamp="footnote" style={{fontSize:13,fontFamily:'Menlo'}}>Monospaced</Text>
    <Text testID="fixed.font" allowFontScaling={false} dynamicTypeRamp="subheadline" style={{fontSize:15}}>Fixed font</Text>
    <Text testID="unknown.title" dynamicTypeRamp="title2" style={{fontSize:22}}>Result heading</Text>
    <Text testID="explicit.break" lineBreakStrategyIOS="none" dynamicTypeRamp="subheadline" style={{fontSize:15}}>Custom breaks</Text>
    <FormParagraph testID="explicit.paragraph" style={{lineHeight:28,marginVertical:2}}>Explicit paragraph</FormParagraph>
  </NativeFlowMetrics>,null,undefined,measuredText.normal);
  const view=render(content());
  expect(StyleSheet.flatten(screen.getByTestId('explicit.line').props.style)).toEqual({fontSize:15,lineHeight:31,marginVertical:4});
  expect(StyleSheet.flatten(screen.getByTestId('explicit.paragraph').props.style)).toMatchObject({lineHeight:28,marginVertical:2});
  for(const id of ['monospace','fixed.font','unknown.title']){
    expect(StyleSheet.flatten(screen.getByTestId(id).props.style).lineHeight).toBeUndefined();
    expect(screen.getByTestId(id).props.lineBreakStrategyIOS).toBeUndefined();
  }
  expect(screen.getByTestId('explicit.break').props.lineBreakStrategyIOS).toBe('none');
  const android=jest.replaceProperty(Platform,'OS','android');
  try{
    view.rerender(content());
    expect(StyleSheet.flatten(screen.getByTestId('explicit.break').props.style).lineHeight).toBeUndefined();
    // Existing FormParagraph's Android recipe remains unchanged.
    expect(StyleSheet.flatten(screen.getByTestId('explicit.paragraph').props.style)).toMatchObject({lineHeight:28,marginVertical:2});
  }finally{android.restore();}
});

test('backup activation retains its page and credentials while loading in the button, then shows Done',()=>{
  const command=jest.fn();
  const state={...backup,step:'recoveryPhrase' as const,saved:true,understands:true,canContinue:true};
  const content=(value:AccountBackupFlowState)=>fixture(<AccountBackupFlow state={value} command={command} credentials={<View testID="retained-credentials"/>} confirmAccountDeletion={()=>{}}/>);
  const view=render(content(state));
  const credentials=screen.getByTestId('retained-credentials');
  const scroll=screen.UNSAFE_getByType(ScrollView);
  fireEvent.press(screen.getByRole('button',{name:localized('Turn On Backup')}));
  expect(command).toHaveBeenLastCalledWith({action:'setup.finish'});
  view.rerender(content({...state,step:'upload',busy:true,uploading:true}));
  expect(screen.getByTestId('retained-credentials')).toBe(credentials);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expect(screen.getByRole('button',{name:localized('Turn On Backup')})).toHaveProp('accessibilityState',{busy:true,disabled:true});
  expect(screen.queryByText(localized('Set up on this device. Your online backup is pending.'))).toBeNull();
  expect(screen.queryByRole('button',{name:localized('Retry upload')})).toBeNull();
  view.rerender(content({...state,step:'upload',busy:false,uploading:false,uploadError:'Network unavailable'}));
  expect(screen.getByTestId('retained-credentials')).toBe(credentials);
  fireEvent.press(screen.getByRole('button',{name:localized('Turn On Backup')}));
  expect(command).toHaveBeenLastCalledWith({action:'setup.retry'});
  view.rerender(content({...state,success:true,step:'upload'}));
  expect(screen.queryByTestId('retained-credentials')).toBeNull();
  expect(screen.getByText('Backup is ready')).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Done'}));
  expect(command).toHaveBeenLastCalledWith({action:'close'});
});
