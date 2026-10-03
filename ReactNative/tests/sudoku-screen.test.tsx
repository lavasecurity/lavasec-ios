import {useState,type ComponentRef,type PropsWithChildren} from 'react';
import {AccessibilityInfo,Alert,Animated,AppState,PanResponder,Pressable,StyleSheet,Text,View} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {SudokuScreen} from '../review/SudokuScreen';
import {GuardScreen} from '../review/screens';
import {PrivacyScreen} from '../review/SettingsScreens';
import {ReviewContext} from '../review/ReviewContext';
import {AppearanceStore} from '../review/appearance-store';
import {initialPreviewDraft} from '../review/preview-model';
import {initialSession} from '../review/session';
import {editCell,freshPuzzle,keypadColumnGeometry,newGame,referencePuzzle,type SudokuGame} from '../review/sudoku-model';
import type {AppStore} from '../app/store';
import type {AppCommand} from '../app/contract';
import {configurePresentation,localized} from '../app/presentation';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors.ios';
// The palette stores scheme pairs; this environment renders the light scheme.
const safeControlGreen=(colors.safeControlGreen as unknown as {dynamic:{light:string;dark:string}}).dynamic.light;
import {REVEAL_EASING,REVEAL_EMOJI,REVEAL_FADE_MS,REVEAL_LINGER_MS} from '../review/sudoku-reveal';
import * as sudokuModel from '../review/sudoku-model';
import {SudokuBoard,SudokuKeypad,sudokuMetrics} from '../review/sudoku-scaffold';
import {Symbol} from '../review/primitives';
const mockNavigate=jest.fn(),mockGoBack=jest.fn(),mockSetOptions=jest.fn();
const tool=(id:string)=>screen.getByTestId(id);
const pressTool=(id:string)=>fireEvent.press(tool(id));
jest.mock('@react-navigation/native',()=>({usePreventRemove:jest.fn(),useNavigation:()=>({navigate:mockNavigate,goBack:mockGoBack,setOptions:mockSetOptions}),useScrollToTop:jest.fn(),useIsFocused:()=>true}));
jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View,SafeAreaView:require('react-native').View,
  useSafeAreaInsets:()=>{const {width,height}=require('react-native').useWindowDimensions();return width>height
    ?{top:0,bottom:21,left:59,right:59}:{top:59,bottom:34,left:0,right:0};},
  useSafeAreaFrame:()=>{const {width,height}=require('react-native').useWindowDimensions();return{x:0,y:0,width,height};}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{close:jest.fn(), getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'},aquamarine:{light:'#227B89',dark:'#6FD2DF'}})}}));

function Provider({children,solved=false,initialGame,app}:PropsWithChildren<{solved?:boolean;initialGame?:SudokuGame;app?:AppStore}>){
  const [session,setSession]=useState(()=>{
    const session=initialSession();
    if(initialGame)session.sudoku=initialGame;
    if(solved){
      let game=newGame();
      referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
      session.sudoku=game;
    }
    return session;
  });
  const [draft,setDraft]=useState(initialPreviewDraft);
  const [appearance]=useState(()=>new AppearanceStore({getSnapshot:async()=>({preference:'system',revision:0}),setPreference:async preference=>({preference,revision:1}),onSnapshot:()=>({remove(){}})}));
  return <ReviewContext.Provider value={{app,session,setSession,draft,setDraft,savedDraft:draft,setSavedDraft:setDraft,appearance,look:'original',setLook(){}}}>{children}</ReviewContext.Provider>;
}
beforeEach(()=>{jest.clearAllMocks();});
test('rounded board clipping keeps all four corner cells editable in the same measured square',()=>{
  const puzzle={...referencePuzzle,givens:Array<number>(81).fill(0)};
  render(<Provider initialGame={newGame(puzzle)}><SudokuScreen/></Provider>);
  const board=screen.getByTestId('sudoku-board');
  expect(board).toHaveStyle({borderRadius:foundation.radius.compact,overflow:'hidden'});
  for(const index of [0,8,72,80]){
    const cell=screen.getByTestId(`sudoku-cell-${index}`);
    fireEvent.press(cell);
    fireEvent.press(screen.getByTestId('sudoku-digit-1'));
    expect(screen.getByTestId(`sudoku-cell-${index}`)).toBe(cell);
    expect(cell).toHaveProp('accessibilityLabel',`Row ${Math.floor(index/9)+1}, column ${index%9+1}: 1`);
  }
  expect(screen.getByTestId('sudoku-board')).toBe(board);
});
test.each([
  ['de','Sudoku-Feld','40 von 81 Zellen ausgefüllt','Zeile 1, Spalte 1: leer','Zeile 1, Spalte 1: Notizen 1 3','Kandidat 1 in der ausgewählten Zelle umschalten'],
  ['ja','数独ボード','81マス中40マス記入済み','1行、1列：空き','1行、1列：候補 1 3','選択したセルの候補1を切り替え'],
])('Sudoku VoiceOver uses native %s labels and integer formats', (locale,board,filled,empty,notes,hint)=>{
  configurePresentation({locale,textScales:null});
  try {
    render(<Provider><SudokuScreen/></Provider>);
    expect(screen.getByLabelText(board)).toHaveAccessibilityValue({text:filled});
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel',empty);
    expect(tool('sudoku-notes-toggle')).toHaveProp('accessibilityLabel',localized('Notes mode off'));
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    pressTool('sudoku-notes-toggle');
    fireEvent.press(screen.getByTestId('sudoku-digit-1'));fireEvent.press(screen.getByTestId('sudoku-digit-3'));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel',notes);
    expect(screen.getByTestId('sudoku-digit-1')).toHaveProp('accessibilityHint',hint);
    expect(tool('sudoku-notes-toggle')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  } finally {configurePresentation();}
});
test('a solved board locks entry but New puzzle remains an ordinary action',()=>{
  render(<Provider solved><SudokuScreen /></Provider>);
  expect(screen.getByLabelText('Sudoku board, solved')).toBeOnTheScreen();
  expect(screen.getByLabelText('Correctly placed')).toBeOnTheScreen();
  expect(screen.getByTestId('sudoku-digit-1')).toBeDisabled();
  expect(tool('sudoku-refresh')).toHaveProp('accessibilityLabel','New puzzle');
  expect(tool('sudoku-refresh')).not.toBeDisabled();
  // Completion fills the next-game action with the same green treatment a
  // selected mode uses, but as a visual-only prominence: it must not publish
  // selection semantics to VoiceOver.
  expect(tool('sudoku-refresh')).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  expect(tool('sudoku-refresh')).toHaveStyle({backgroundColor:safeControlGreen});
});
test('a solved board keeps cells selectable and swipes trackable while entry and erasing lock',()=>{
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    // Entry and erasing are locked: digits disabled and the eraser key is absent.
    expect(screen.getByTestId('sudoku-digit-1')).toBeDisabled();
    expect(screen.queryByTestId('sudoku-eraser')).not.toBeOnTheScreen();
    // Tapping a cell still selects it; the completion lock is not a navigation lock.
    const cell=screen.getByTestId('sudoku-cell-0');
    fireEvent.press(cell);
    expect(cell).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    // A swipe still claims the board gesture and re-selects as it tracks.
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,step=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    expect(pan.onMoveShouldSetPanResponderCapture!({} as never,{dx:10,dy:0} as never)).toBe(true);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    act(()=>pan.onPanResponderMove!(at(100+step*3.5,200+step*.5),gesture));
    expect(screen.getByTestId('sudoku-cell-3')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>pan.onPanResponderRelease!(at(100+step*3.5,200+step*.5),gesture));
    // The solved board ignores edits even though selection moved.
    expect(screen.getByLabelText('Sudoku board, solved')).toBeOnTheScreen();
  } finally {measure.mockRestore();responder.mockRestore();}
});
test('a solved board brushes an opaque tile that lingers after release then clears',()=>{
  jest.useFakeTimers();
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  const timing=jest.spyOn(Animated,'timing').mockImplementation((()=>({start:()=>{}})) as never);
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    // A touch claims the board on a solved board and opens the glyph's window on cell 0.
    expect(pan.onStartShouldSetPanResponderCapture!({} as never,{} as never)).toBe(true);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    const tile=screen.getByTestId('sudoku-reveal-tile-0',{includeHiddenElements:true});
    expect(tile).toHaveStyle({backgroundColor:colors.groupedBackground,opacity:1});
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    // Release: the selector does not stick, the tile lingers through its hold.
    act(()=>pan.onPanResponderRelease!(at(101,201),gesture));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
    expect(screen.getByTestId('sudoku-reveal-tile-0',{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>jest.advanceTimersByTime(REVEAL_LINGER_MS));
    // The close uses the chosen swift curve at the fixed fade duration.
    expect(timing).toHaveBeenCalledWith(expect.anything(),expect.objectContaining({duration:REVEAL_FADE_MS,easing:REVEAL_EASING}));
    expect(screen.getByTestId('sudoku-reveal-tile-0',{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>jest.advanceTimersByTime(REVEAL_FADE_MS));
    expect(screen.queryByTestId('sudoku-reveal-tile-0',{includeHiddenElements:true})).not.toBeOnTheScreen();
  } finally {
    timing.mockRestore();measure.mockRestore();responder.mockRestore();jest.useRealTimers();
  }
});
test('a fast solved-board swipe interpolates the cells between move samples',()=>{
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,cell=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    // One move jumps from cell 0 to cell 20; the trail must cross 10, not skip it.
    act(()=>pan.onPanResponderMove!(at(100+cell*2.5,200+cell*2.5),gesture));
    for(const index of [0,10,20]) expect(screen.getByTestId(`sudoku-reveal-tile-${index}`,{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>pan.onPanResponderRelease!(at(100+cell*2.5,200+cell*2.5),gesture));
  } finally {measure.mockRestore();responder.mockRestore();}
});
test('a live board never mounts reveal tiles and keeps its sticky selection',()=>{
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  try {
    const puzzle={...referencePuzzle,givens:Array<number>(81).fill(0)};
    render(<Provider initialGame={newGame(puzzle)}><SudokuScreen /></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,cell=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    expect(pan.onStartShouldSetPanResponderCapture!({} as never,{} as never)).toBe(false);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    act(()=>pan.onPanResponderMove!(at(100+cell*3.5,200+cell*.5),gesture));
    expect(screen.queryAllByTestId(/sudoku-reveal-tile-/,{includeHiddenElements:true})).toHaveLength(0);
    act(()=>pan.onPanResponderRelease!(at(100+cell*3.5,200+cell*.5),gesture));
    // Normal gameplay keeps its selected cell after the finger lifts.
    expect(screen.getByTestId('sudoku-cell-3')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    expect(tool('sudoku-refresh')).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
    expect(tool('sudoku-refresh')).not.toHaveStyle({backgroundColor:safeControlGreen});
  } finally {measure.mockRestore();responder.mockRestore();}
});
test('a stroke that moves before measurement still reveals its opening segment',()=>{
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,cell=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    act(()=>pan.onPanResponderMove!(at(100+cell*2.5,200+cell*2.5),gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    for(const index of [0,10,20]) expect(screen.getByTestId(`sudoku-reveal-tile-${index}`,{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>pan.onPanResponderRelease!(at(100+cell*2.5,200+cell*2.5),gesture));
  } finally {measure.mockRestore();responder.mockRestore();}
});
test('a stroke that leaves the board revives the same cell on re-entry',()=>{
  jest.useFakeTimers();
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  const timing=jest.spyOn(Animated,'timing').mockImplementation((()=>({start:()=>{}})) as never);
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,cell=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    const center=at(100+cell*2.5,200+cell*2.5);
    act(()=>pan.onPanResponderGrant!(center,gesture));
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    expect(screen.getByTestId('sudoku-reveal-tile-20',{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>pan.onPanResponderMove!(at(100+side+cell*2,200+cell*2),gesture));
    act(()=>jest.advanceTimersByTime(REVEAL_LINGER_MS+REVEAL_FADE_MS));
    expect(screen.queryByTestId('sudoku-reveal-tile-20',{includeHiddenElements:true})).not.toBeOnTheScreen();
    act(()=>pan.onPanResponderMove!(center,gesture));
    expect(screen.getByTestId('sudoku-reveal-tile-20',{includeHiddenElements:true})).toBeOnTheScreen();
    act(()=>pan.onPanResponderRelease!(center,gesture));
  } finally {timing.mockRestore();measure.mockRestore();responder.mockRestore();jest.useRealTimers();}
});
test('accessible activation on a solved board clears its selection when the tile fades',()=>{
  jest.useFakeTimers();
  const timing=jest.spyOn(Animated,'timing').mockImplementation((()=>({start:()=>{}})) as never);
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const cell=screen.getByTestId('sudoku-cell-2');
    fireEvent.press(cell);
    expect(cell).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>jest.advanceTimersByTime(REVEAL_LINGER_MS+REVEAL_FADE_MS));
    expect(cell).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
    expect(screen.queryByTestId('sudoku-reveal-tile-2',{includeHiddenElements:true})).not.toBeOnTheScreen();
  } finally {timing.mockRestore();jest.useRealTimers();}
});
test('backgrounding during an accessible activation still clears its solved selection',()=>{
  const listeners:Array<(state:string)=>void>=[];
  // Direct capture/restore, not jest.spyOn: the RN preset's AppState mock is a
  // bare jest.fn and restoring the spy can leave later renders without a
  // subscription object.
  const originalAddEventListener=AppState.addEventListener;
  AppState.addEventListener=((type:string,handler:(state:string)=>void)=>{
    listeners.push(handler);
    return {remove:()=>{}};
  }) as typeof AppState.addEventListener;
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    const cell=screen.getByTestId('sudoku-cell-2');
    fireEvent.press(cell);
    expect(cell).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>{for(const listener of listeners)listener('background');});
    expect(cell).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  } finally {AppState.addEventListener=originalAddEventListener;}
});
test('a solved board haptics every cell, givens included',()=>{
  const command=jest.fn().mockResolvedValue(null);
  const givens=Array<number>(81).fill(0);
  givens[0]=referencePuzzle.solution[0]!;
  let solved=newGame({...referencePuzzle,givens});
  referencePuzzle.solution.forEach((digit,index)=>{if(!givens[index])solved=editCell(solved,index,digit);});
  render(<Provider initialGame={solved} app={{command} as unknown as AppStore}><SudokuScreen /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  expect(command).toHaveBeenCalledWith({type:'haptic',kind:'selected',controlID:expect.stringMatching(/^sudoku\.cell@/),value:'0'});
  command.mockClear();
  fireEvent.press(screen.getByTestId('sudoku-cell-2'));
  expect(command).toHaveBeenCalledWith({type:'haptic',kind:'selected',controlID:expect.stringMatching(/^sudoku\.cell@/),value:'2'});
});
test('the reveal emoji is one fixed image per game across opens and remounts',()=>{
  jest.useFakeTimers();
  const timing=jest.spyOn(Animated,'timing').mockImplementation((()=>({start:()=>{}})) as never);
  // A different random phase between opens must not matter: the image belongs
  // to the game, not to when the overlay is opened.
  const random=jest.spyOn(Math,'random').mockReturnValue(0);
  const glyph=()=>REVEAL_EMOJI.find(emoji=>screen.queryByText(emoji,{includeHiddenElements:true}));
  const open=()=>fireEvent.press(screen.getByTestId('sudoku-cell-2'));
  try {
    let game=newGame({...referencePuzzle,givens:Array<number>(81).fill(0)});
    referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,digit);});
    const view=render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    random.mockReturnValue(0);
    open();
    const first=glyph();
    expect(first).toBeDefined();
    // A later overlay open on the same board keeps the same image.
    act(()=>jest.advanceTimersByTime(REVEAL_LINGER_MS+REVEAL_FADE_MS));
    random.mockReturnValue(0.999);
    open();
    expect(glyph()).toBe(first);
    // A full remount on the same game still keeps the same image.
    view.unmount();
    render(<Provider initialGame={game}><SudokuScreen /></Provider>);
    open();
    expect(glyph()).toBe(first);
  } finally {random.mockRestore();timing.mockRestore();jest.useRealTimers();}
});
test('a live board keeps given-cell selection silent',()=>{
  const command=jest.fn().mockResolvedValue(null);
  const givens=Array<number>(81).fill(0);
  givens[0]=referencePuzzle.solution[0]!;
  render(<Provider initialGame={newGame({...referencePuzzle,givens})} app={{command} as unknown as AppStore}><SudokuScreen /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'haptic'}));
  fireEvent.press(screen.getByTestId('sudoku-cell-2'));
  expect(command).toHaveBeenCalledWith({type:'haptic',kind:'selected',controlID:expect.stringMatching(/^sudoku\.cell@/),value:'2'});
});
test('a completed board with errors shows its result even when assistance is off',()=>{
  let game=newGame();
  referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,index===0?1:digit);});
  render(<Provider initialGame={game}><SudokuScreen/></Provider>);
  expect(screen.getByLabelText('Sudoku board, complete but with errors')).toBeOnTheScreen();
  expect(screen.getByLabelText('Misplaced')).toBeOnTheScreen();
  expect(tool('sudoku-correctness-toggle')).toHaveProp('accessibilityLabel','Puzzle assistance off');
});
test('a pending native new game preserves board and cell identity until its numbers change',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  let resolve!:(game:SudokuGame)=>void;
  const command=jest.fn((command:AppCommand)=>command.type==='sudoku.new'?new Promise<SudokuGame>(yes=>{resolve=yes;}):Promise.resolve());
  render(<Provider initialGame={newGame()} app={{command} as unknown as AppStore}><SudokuScreen/></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  const board=screen.getByTestId('sudoku-board'),cell=screen.getByTestId('sudoku-cell-0');
  pressTool('sudoku-refresh');
  act(()=>alert.mock.lastCall![2]!.find(button=>button.text==='New puzzle')!.onPress!());
  expect(screen.getByTestId('sudoku-board')).toBe(board);
  expect(screen.getByTestId('sudoku-cell-0')).toBe(cell);
  expect(screen.getByLabelText('Row 1, column 1: 5')).toBeOnTheScreen();
  expect(screen.getByLabelText('Preparing puzzle')).toBeOnTheScreen();
  expect(tool('sudoku-refresh')).toBeDisabled();
  await act(async()=>resolve(newGame(freshPuzzle(referencePuzzle))));
  expect(screen.getByTestId('sudoku-board')).toBe(board);
  expect(screen.getByTestId('sudoku-cell-0')).toBe(cell);
  expect(screen.queryByLabelText('Preparing puzzle')).toBeNull();
  expect(screen.getByLabelText('Sudoku board')).toHaveAccessibilityValue({text:'40 of 81 cells filled'});
  alert.mockRestore();
});
test('five quick mascot taps open Sudoku, idle pauses reset the sequence, and a hold opens customization',()=>{
  jest.useFakeTimers();jest.setSystemTime(10000);
  AppState.currentState='active';
  render(<Provider><GuardScreen /></Provider>);
  const mascot=screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true});
  for(let count=0;count<4;count++)fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'tap'}});
  expect(mockNavigate).not.toHaveBeenCalled();
  act(()=>jest.advanceTimersByTime(1201));
  fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'tap'}});expect(mockNavigate).not.toHaveBeenCalled();
  for(let count=0;count<4;count++)fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'tap'}});
  expect(mockNavigate).toHaveBeenLastCalledWith('Sudoku');
  fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'reveal'}});expect(mockNavigate).toHaveBeenLastCalledWith('Guardian');
  fireEvent(screen.getByLabelText('Protection status'),'accessibilityAction',{nativeEvent:{actionName:'playSudoku'}});
  expect(mockNavigate).toHaveBeenLastCalledWith('Sudoku');
  jest.useRealTimers();
});
test('notes, placement, assistance and contextual erase follow native cell semantics',()=>{
  render(<Provider><SudokuScreen /></Provider>);
  expect(screen.getByTestId('sudoku-digit-1')).toBeDisabled();
  fireEvent.press(screen.getByTestId('sudoku-cell-1'));
  expect(screen.getByTestId('sudoku-digit-1')).toBeDisabled();
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  pressTool('sudoku-notes-toggle');
  fireEvent.press(screen.getByTestId('sudoku-digit-1'));fireEvent.press(screen.getByTestId('sudoku-digit-3'));
  expect(screen.getByLabelText('Row 1, column 1: notes 1 3')).toBeOnTheScreen();
  pressTool('sudoku-notes-toggle');
  expect(screen.getByLabelText('Row 1, column 1: empty')).toBeOnTheScreen();
  fireEvent.press(screen.getByTestId('sudoku-digit-5'));pressTool('sudoku-correctness-toggle');
  expect(screen.getByLabelText('Correctly placed')).toBeOnTheScreen();
  fireEvent.press(screen.getByTestId('sudoku-digit-1'));
  expect(screen.getByLabelText('Misplaced')).toBeOnTheScreen();
  fireEvent.press(screen.getByTestId('sudoku-eraser'));
  expect(screen.getByLabelText('Row 1, column 1: empty')).toBeOnTheScreen();
  expect(screen.queryByTestId('sudoku-eraser')).toBeNull();
});
test('reset and new puzzle require confirmation and cancel preserves the board',()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  render(<Provider><SudokuScreen /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  pressTool('sudoku-reset');
  expect(alert.mock.lastCall![0]).toBe('Reset puzzle?');
  expect(screen.getByLabelText('Row 1, column 1: 5')).toBeOnTheScreen();
  act(()=>alert.mock.lastCall![2]!.find(button=>button.text==='Reset')!.onPress!());
  expect(screen.getByLabelText('Row 1, column 1: empty')).toBeOnTheScreen();
  expect(screen.getByLabelText('Row 1, column 2: 3, given')).toBeOnTheScreen();
  pressTool('sudoku-refresh');
  expect(alert.mock.lastCall![0]).toBe('New puzzle');
  act(()=>alert.mock.lastCall![2]!.find(button=>button.text==='New puzzle')!.onPress!());
  expect(screen.getByLabelText('Sudoku board')).toHaveAccessibilityValue({text:'40 of 81 cells filled'});
  alert.mockRestore();
});
function ResumeHarness(){
  const [playing,setPlaying]=useState(true);
  return <><Pressable accessibilityRole="button" accessibilityLabel="Toggle game" onPress={()=>setPlaying(!playing)}><Text>Toggle game</Text></Pressable>{playing?<SudokuScreen />:<PrivacyScreen />}</>;
}
test('progress resumes in the review session and turning its log off clears it',()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  render(<Provider><ResumeHarness /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  fireEvent.press(screen.getByLabelText('Toggle game'));fireEvent.press(screen.getByLabelText('Toggle game'));
  expect(screen.getByLabelText('Row 1, column 1: 5')).toBeOnTheScreen();
  fireEvent.press(screen.getByLabelText('Toggle game'));
  fireEvent(screen.getByRole('switch',{name:'Lava Guard progress'}),'valueChange',false);
  expect(screen.getByRole('switch',{name:'Lava Guard progress'})).toBeChecked();
  expect(alert.mock.lastCall![0]).toBe('Turn off Lava Guard progress?');
  act(()=>alert.mock.lastCall![2]!.find(button=>button.text==='Turn off and clear progress')!.onPress!());
  fireEvent.press(screen.getByLabelText('Toggle game'));
  expect(screen.getByLabelText('Row 1, column 1: empty')).toBeOnTheScreen();
  alert.mockRestore();
});
test('clearing Lava Guard progress asks first and preserves the enabled setting',()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  render(<Provider><ResumeHarness /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  fireEvent.press(screen.getByLabelText('Toggle game'));
  fireEvent.press(screen.getByRole('button',{name:'Clear local logs'}));
  fireEvent.press(screen.getByRole('button',{name:'Clear Lava Guard progress'}));
  expect(alert.mock.lastCall![0]).toBe('Clear Lava Guard progress?');
  act(()=>alert.mock.lastCall![2]!.find(button=>button.text==='Clear progress')!.onPress!());
  expect(screen.getByRole('switch',{name:'Lava Guard progress'})).toBeChecked();
  fireEvent.press(screen.getByLabelText('Toggle game'));
  expect(screen.getByLabelText('Row 1, column 1: empty')).toBeOnTheScreen();
  alert.mockRestore();
});
test('Clear all logs retains the review boundary without claiming or performing a partial clear',()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const announcement=jest.spyOn(AccessibilityInfo,'announceForAccessibility').mockImplementation(()=>{});
  render(<Provider><ResumeHarness /></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  fireEvent.press(screen.getByLabelText('Toggle game'));
  fireEvent.press(screen.getByRole('button',{name:'Clear local logs'}));
  fireEvent.press(screen.getByRole('button',{name:'Clear all logs'}));
  expect(alert.mock.lastCall![0]).toBe('UI review build');
  expect(announcement).not.toHaveBeenCalled();
  fireEvent.press(screen.getByLabelText('Toggle game'));
  expect(screen.getByLabelText('Row 1, column 1: 5')).toBeOnTheScreen();
  alert.mockRestore();announcement.mockRestore();
});


test('mascot native contact lifecycle preserves the existing authorization gate and cancels background reveal',async()=>{
  AppState.currentState='active';
  let authorize!:()=>void;
  const command=jest.fn((value:AppCommand)=>value.type==='navigation.authorize'?new Promise<void>(resolve=>{authorize=resolve;}):Promise.resolve());
  const listeners:((state:import('react-native').AppStateStatus)=>void)[]=[];
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{listeners.push(listener);return{remove:jest.fn()};});
  render(<Provider app={{command} as unknown as AppStore}><GuardScreen/></Provider>);
  const mascot=screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true});
  const gesture=(value:string)=>fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:value}});
  gesture('start');gesture('end');
  expect(command).toHaveBeenCalledWith({type:'guard.gesture',gesture:'start'});
  expect(command).not.toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  gesture('start');gesture('reveal');gesture('reveal');
  expect(command.mock.calls.filter(([value])=>value.type==='navigation.authorize')).toHaveLength(1);
  expect(mockNavigate).not.toHaveBeenCalled();
  act(()=>listeners.forEach(listener=>listener('background')));
  expect(screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true})).toHaveProp('guardianGestures',false);
  await act(async()=>authorize());expect(mockNavigate).not.toHaveBeenCalled();
  gesture('reveal');expect(command.mock.calls.filter(([value])=>value.type==='navigation.authorize')).toHaveLength(1);
  act(()=>listeners.forEach(listener=>listener('active')));
  expect(screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true})).toHaveProp('guardianGestures',true);
  gesture('start');gesture('reveal');await act(async()=>authorize());
  expect(mockNavigate).toHaveBeenCalledTimes(1);expect(mockNavigate).toHaveBeenLastCalledWith('Guardian');
  subscription.mockRestore();
});


test('one Sudoku rail owns the controls and close action in portrait',()=>{
  render(<Provider><SudokuScreen/></Provider>);
  const rail=screen.getByTestId('sudoku-rail');
  expect(rail).toHaveStyle({height:foundation.control.target,flexDirection:'row',width:'100%',maxWidth:foundation.layout.readingWidth,
    alignSelf:'center',paddingHorizontal:foundation.space.screenHorizontal});
  expect(tool('sudoku-close')).toHaveStyle({borderRadius:foundation.radius.control});
  expect(screen.getByTestId('sudoku-digit-group')).toHaveStyle({flexDirection:'row',borderRadius:foundation.radius.control,overflow:'hidden'});
  expect(screen.getByTestId('sudoku-digit-1')).toHaveStyle({borderRightWidth:1});
  expect(screen.getByTestId('sudoku-digit-9')).not.toHaveStyle({borderRightWidth:1});
  expect([...new Set(rail.findAll((node:{props:{accessibilityRole?:string}})=>node.props.accessibilityRole==='button').map((node:{props:{testID?:string}})=>node.props.testID))])
    .toEqual(['sudoku-close','sudoku-notes-toggle','sudoku-correctness-toggle','sudoku-reset','sudoku-refresh']);
  pressTool('sudoku-notes-toggle');pressTool('sudoku-correctness-toggle');
  expect(tool('sudoku-notes-toggle')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  expect(tool('sudoku-notes-toggle')).toHaveProp('accessibilityLabel','Notes mode on');
  expect(tool('sudoku-correctness-toggle')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  expect(tool('sudoku-correctness-toggle')).toHaveProp('accessibilityLabel','Puzzle assistance on');
  pressTool('sudoku-close');
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test('portrait digits grow toward the eraser while keeping the keypad outer edge fixed',()=>{
  render(<Provider><SudokuScreen/></Provider>);
  expect(screen.getByTestId('sudoku-digit-group')).toHaveStyle({top:62,height:78});
  expect(screen.getByTestId('sudoku-keypad-touch',{includeHiddenElements:true})).toHaveStyle({top:62,height:78});
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  expect(screen.getByTestId('sudoku-eraser')).toHaveStyle({top:0,height:foundation.control.target});
});

test('Eye renders the native correctness glyph through repeated independent mode selections',()=>{
  render(<Provider><SudokuScreen/></Provider>);
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));
  fireEvent.press(screen.getByTestId('sudoku-digit-5'));
  const result=()=>screen.queryByTestId('sudoku-correctness-outcome');
  const expectGlyph=(name:string,tone:string)=>{
    const glyph=result()!.findByType(Symbol);
    expect(glyph.props).toMatchObject({name,tone,size:foundation.control.target,pointSize:foundation.type.heading.fontSize});
    // The old assertion covered only the accessible wrapper. Check the native
    // leaf receives a visible, nonzero slot and the correct SF Symbol as well.
    expect(glyph.findByProps({symbol:name}).props).toMatchObject({tone,style:{width:foundation.control.target,height:foundation.control.target}});
  };
  expect(result()).toBeNull();
  pressTool('sudoku-correctness-toggle');expectGlyph('checkmark.circle.fill','green');
  pressTool('sudoku-notes-toggle');expectGlyph('checkmark.circle.fill','green');
  pressTool('sudoku-correctness-toggle');expect(result()).toBeNull();
  pressTool('sudoku-correctness-toggle');expectGlyph('checkmark.circle.fill','green');
  pressTool('sudoku-notes-toggle');expectGlyph('checkmark.circle.fill','green');
  fireEvent.press(screen.getByTestId('sudoku-digit-1'));expectGlyph('xmark.circle.fill','orange');
  fireEvent.press(screen.getByTestId('sudoku-eraser'));expect(result()).toBeNull();
  fireEvent.press(screen.getByTestId('sudoku-cell-1'));expect(result()).toBeNull();
});

test('selection and digit preview updates retain unaffected cell callbacks and cached labels/counts',()=>{
  const labels=jest.spyOn(sudokuModel,'cellLabel'),boards=jest.spyOn(sudokuModel,'workingBoard');
  const game=newGame(),onChoose=jest.fn(),onEnter=jest.fn(),onErase=jest.fn(),panHandlers={};
  const props={game,side:360,notesMode:false,assist:false,loading:false,ready:true,boardRef:null,onChoose,panHandlers};
  const view=render(<SudokuBoard {...props} selected={0}/>);
  const unrelated=screen.getByTestId('sudoku-cell-80').props.onPress;
  expect(labels).toHaveBeenCalledTimes(81);labels.mockClear();boards.mockClear();
  view.rerender(<SudokuBoard {...props} selected={2}/>);
  expect(labels).not.toHaveBeenCalled();expect(boards).not.toHaveBeenCalled();
  expect(screen.getByTestId('sudoku-cell-80').props.onPress).toBe(unrelated);
  expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  expect(screen.getByTestId('sudoku-cell-2')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  view.unmount();
  const keypad={game,width:360,selected:0,notesMode:false,assist:true,canEnter:true,canErase:true,onEnter,onErase,panHandlers};
  const keys=render(<SudokuKeypad {...keypad}/>);
  const untouched=screen.getByTestId('sudoku-digit-9').props.onPress;boards.mockClear();
  keys.rerender(<SudokuKeypad {...keypad} trackedKey={4}/>);
  expect(boards).not.toHaveBeenCalled();expect(screen.getByTestId('sudoku-digit-9').props.onPress).toBe(untouched);
  expect(screen.queryByTestId('sudoku-eraser')).toBeNull(); // No erase target underneath a drag preview.
  keys.rerender(<SudokuKeypad {...keypad}/>);
  expect(screen.getByTestId('sudoku-eraser')).toBeOnTheScreen();
  labels.mockRestore();boards.mockRestore();
});

test('digit scrubbing commits only its final release once and cancels outside or on interruption',()=>{
  const responder=jest.spyOn(PanResponder,'create');
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue({width:390,height:844,scale:3,fontScale:1});
  const command=jest.fn().mockResolvedValue(null);
  render(<Provider initialGame={newGame()} app={{command} as unknown as AppStore}><SudokuScreen/></Provider>);
  const keypad=responder.mock.calls[1]![0];
  fireEvent.press(screen.getByTestId('sudoku-cell-0'));pressTool('sudoku-notes-toggle');command.mockClear();
  const width=390-foundation.space.screenHorizontal*2;
  const at=(digit:number,y=26)=>({nativeEvent:{locationX:sudokuModel.keypadGeometry(width).keyCenter(digit),locationY:y}} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[0]);
  const gesture={} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[1];
  act(()=>keypad.onPanResponderGrant!(at(1),gesture));
  act(()=>keypad.onPanResponderMove!(at(4),gesture));
  act(()=>keypad.onPanResponderMove!(at(4),gesture));
  expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: empty');
  expect(command.mock.calls.filter(([value])=>value.kind==='selected')).toHaveLength(2);
  act(()=>keypad.onPanResponderRelease!(at(6),gesture));
  expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: notes 6'); // A duplicate release would toggle the note back off.
  act(()=>keypad.onPanResponderGrant!(at(2),gesture));
  act(()=>keypad.onPanResponderRelease!(at(2,-1),gesture));
  expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: notes 6');
  act(()=>keypad.onPanResponderGrant!(at(3),gesture));
  act(()=>keypad.onPanResponderTerminate!(at(3),gesture));
  expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: notes 6');
  responder.mockRestore();dimensions.mockRestore();
});

test('board drag selects from a fresh root-relative origin after its position changes',()=>{
  const callbacks:Array<Parameters<ComponentRef<typeof View>['measure']>[0]>=[];
  const measure=jest.spyOn(View.prototype,'measure').mockImplementation(callback=>{
    callbacks.push(callback as Parameters<ComponentRef<typeof View>['measure']>[0]);
  });
  const responder=jest.spyOn(PanResponder,'create');
  try {
    const puzzle={...referencePuzzle,givens:Array<number>(81).fill(0)};
    render(<Provider initialGame={newGame(puzzle)}><SudokuScreen/></Provider>);
    const board=screen.getByTestId('sudoku-board');
    const side=StyleSheet.flatten(board.props.style).width as number,cell=side/9;
    const pan=responder.mock.calls[0]![0],gesture={} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[1];
    const at=(x:number,y:number)=>({nativeEvent:{pageX:x,pageY:y}} as Parameters<NonNullable<typeof pan.onPanResponderGrant>>[0]);
    act(()=>pan.onPanResponderGrant!(at(101,201),gesture));
    expect(callbacks).toHaveLength(1);
    act(()=>callbacks.shift()!(0,0,side,side,100,200));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>pan.onPanResponderRelease!(at(101,201),gesture));

    const target=at(200+cell*2.5,300+cell*2.5);
    act(()=>pan.onPanResponderGrant!(at(201,301),gesture));
    act(()=>pan.onPanResponderMove!(target,gesture));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>callbacks.shift()!(0,0,side,side,200,300));
    expect(screen.getByTestId('sudoku-cell-20')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>pan.onPanResponderRelease!(target,gesture));

    const final=at(300+cell*8.5,400+cell*.5);
    act(()=>pan.onPanResponderGrant!(at(301,401),gesture));
    act(()=>pan.onPanResponderRelease!(final,gesture));
    expect(screen.getByTestId('sudoku-cell-20')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    act(()=>callbacks.shift()!(0,0,side,side,300,400));
    expect(screen.getByTestId('sudoku-cell-8')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  } finally {measure.mockRestore();responder.mockRestore();}
});

const landscapeDimensions={width:844,height:390,scale:3,fontScale:1};
// Settled landscape frame and insets arrive together from the safe-area provider.
const landscapeSide=390-(Math.max(0,21,foundation.space.md)+foundation.space.md)*2-foundation.space.sm*2;

test('the portrait board budget includes the shared rail on a short screen',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue({width:390,height:680,scale:3,fontScale:1});
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const available=680-(59+foundation.space.md)-34-foundation.control.target;
    const side=available-204;
    expect(screen.getByTestId('sudoku-screen')).toHaveStyle({paddingTop:59+foundation.space.md,paddingBottom:34});
    expect(screen.getByTestId('sudoku-rail')).toHaveStyle({height:foundation.control.target});
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:side,height:side});
  } finally {dimensions.mockRestore();}
});

test('rotation uses the matching safe-area frame and insets',()=>{
  let window={width:390,height:844,scale:3,fontScale:1};
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockImplementation(()=>window);
  try {
    const view=render(<Provider><SudokuScreen/></Provider>);
    window={...landscapeDimensions};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:landscapeSide,height:landscapeSide});
    window={width:390,height:844,scale:3,fontScale:1};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    const portraitSide=390-foundation.space.screenHorizontal*2;
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:portraitSide,height:portraitSide});
  } finally {dimensions.mockRestore();}
});

test('the status bar is shown in portrait and hidden only in landscape',()=>{
  let window={width:390,height:844,scale:3,fontScale:1};
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockImplementation(()=>window);
  try {
    const view=render(<Provider><SudokuScreen/></Provider>);
    expect(mockSetOptions).toHaveBeenLastCalledWith({statusBarHidden:false});
    window={...landscapeDimensions};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(mockSetOptions).toHaveBeenLastCalledWith({statusBarHidden:true});
    window={width:390,height:844,scale:3,fontScale:1};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(mockSetOptions).toHaveBeenLastCalledWith({statusBarHidden:false});
  } finally {dimensions.mockRestore();}
});

test('window rotation waits for the matching safe-area frame instead of squeezing the board with old insets',()=>{
  let frame={x:0,y:0,width:390,height:844};
  let insets={top:59,bottom:34,left:0,right:0};
  let window={width:390,height:844,scale:3,fontScale:1};
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockImplementation(()=>window);
  const safeArea=require('react-native-safe-area-context');
  const safeFrame=jest.spyOn(safeArea,'useSafeAreaFrame').mockImplementation(()=>frame);
  const safeInsets=jest.spyOn(safeArea,'useSafeAreaInsets').mockImplementation(()=>insets);
  try {
    const view=render(<Provider><SudokuScreen/></Provider>);
    const portraitSide=390-foundation.space.screenHorizontal*2;
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:portraitSide,height:portraitSide});
    window={...landscapeDimensions};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(screen.getByTestId('sudoku-rail')).toHaveStyle({flexDirection:'row'});
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:portraitSide,height:portraitSide});
    frame={x:0,y:0,width:844,height:390};
    insets={top:0,bottom:21,left:59,right:59};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(screen.getByTestId('sudoku-rail')).toHaveStyle({flexDirection:'column'});
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:landscapeSide,height:landscapeSide});
  } finally {safeInsets.mockRestore();safeFrame.mockRestore();dimensions.mockRestore();}
});

test('landscape centers the surface around the home indicator and clears the top gesture edge',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  const insets=jest.spyOn(require('react-native-safe-area-context'),'useSafeAreaInsets')
    .mockReturnValue({top:0,bottom:21,left:59,right:59});
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const padding=21+foundation.space.md,side=390-padding*2-foundation.space.sm*2;
    expect(screen.getByTestId('sudoku-screen')).toHaveStyle({paddingTop:padding,paddingBottom:padding,paddingLeft:59,paddingRight:59});
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:side,height:side});
    expect(screen.getByTestId('sudoku-digit-1')).toHaveStyle({height:side/9});
  } finally {insets.mockRestore();dimensions.mockRestore();}
});

test('the landscape rail tightens its gaps to keep all five buttons in a short viewport',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions')
    .mockReturnValue({width:700,height:320,scale:3,fontScale:1});
  const insets=jest.spyOn(require('react-native-safe-area-context'),'useSafeAreaInsets')
    .mockReturnValue({top:0,bottom:21,left:59,right:59});
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const band=320-2*(21+foundation.space.md);
    const gap=(band-5*foundation.control.target-2*foundation.space.sm)/5;
    expect(screen.getByTestId('sudoku-rail')).toHaveStyle({gap});
    expect(gap).toBeLessThan(foundation.space.md);
  } finally {insets.mockRestore();dimensions.mockRestore();}
});

test('landscape transposes the same rail, feedback and keypad around a full-height board',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const rail=screen.getByTestId('sudoku-rail');
    expect(rail).toHaveStyle({width:foundation.control.target,flexDirection:'column',paddingVertical:foundation.space.sm});
    expect(screen.getByTestId('sudoku-left-chrome')).toHaveStyle({width:sudokuMetrics.keypadHeight,zIndex:1});
    expect(screen.getByTestId('sudoku-digit-group')).toHaveStyle({flexDirection:'column',borderRadius:foundation.radius.control,overflow:'hidden'});
    expect(screen.getByTestId('sudoku-digit-group')).toHaveStyle({left:62,width:78});
    expect(screen.getByTestId('sudoku-keypad-touch',{includeHiddenElements:true})).toHaveStyle({left:62,width:78});
    expect(screen.getByTestId('sudoku-digit-1')).toHaveStyle({borderBottomWidth:1});
    expect(screen.getByTestId('sudoku-digit-9')).not.toHaveStyle({borderBottomWidth:1});
    expect([...new Set(rail.findAll((node:{props:{accessibilityRole?:string}})=>node.props.accessibilityRole==='button').map((node:{props:{testID?:string}})=>node.props.testID))])
      .toEqual(['sudoku-close','sudoku-two-player','sudoku-notes-toggle','sudoku-correctness-toggle','sudoku-reset','sudoku-refresh']);
    expect(screen.getByTestId('sudoku-close')).toBeOnTheScreen();
    for(const id of ['sudoku-notes-toggle','sudoku-correctness-toggle','sudoku-reset','sudoku-refresh'])
      expect(screen.getByTestId(id)).toBeOnTheScreen();
    expect(screen.getByTestId('sudoku-board')).toHaveStyle({width:landscapeSide,height:landscapeSide});
    expect(screen.getByTestId('sudoku-feedback-band')).toHaveStyle({width:foundation.control.target});
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    fireEvent.press(screen.getByTestId('sudoku-digit-5'));
    expect(screen.getByTestId('sudoku-eraser')).toHaveStyle({left:0,width:foundation.control.target});
    fireEvent.press(screen.getByTestId('sudoku-close'));
    expect(mockGoBack).toHaveBeenCalled();
  } finally {dimensions.mockRestore();}
});

test('landscape centers both outcome glyphs between the visible 2P rail and board',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const outcomeGutter=screen.getByTestId('sudoku-outcome-gutter');
    const balanceGutter=screen.getByTestId('sudoku-balance-gutter');
    expect(outcomeGutter).toHaveStyle({flex:1,alignItems:'center',justifyContent:'center',
      transform:[{translateX:-(sudokuMetrics.keypadHeight-sudokuMetrics.keyHeight)/2}]});
    expect(balanceGutter).toHaveStyle({flex:1,alignItems:'center',justifyContent:'center'});
    expect(outcomeGutter.findAllByProps({testID:'sudoku-feedback-band'}).length).toBeGreaterThan(0);
    expect(screen.getByTestId('sudoku-feedback-band')).not.toHaveStyle({alignSelf:'stretch'});
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    fireEvent.press(screen.getByTestId('sudoku-correctness-toggle'));
    expect(screen.getByTestId('sudoku-correctness-toggle')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
    fireEvent.press(screen.getByTestId('sudoku-digit-5'));
    expect(screen.getByLabelText('Correctly placed')).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('sudoku-digit-1'));
    expect(screen.getByLabelText('Misplaced')).toBeOnTheScreen();
    expect(screen.getByTestId('sudoku-outcome-gutter')).toBe(outcomeGutter);
    fireEvent.press(screen.getByTestId('sudoku-notes-toggle'));
    expect(screen.getByTestId('sudoku-notes-toggle')).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  } finally {dimensions.mockRestore();}
});

test('landscape scrub tracks the key column and the eraser keeps its transposed place',()=>{
  const responder=jest.spyOn(PanResponder,'create');
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider initialGame={newGame()}><SudokuScreen/></Provider>);
    const keypad=responder.mock.calls[1]![0];
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    const geometry=keypadColumnGeometry(landscapeSide);
    const at=(digit:number,x=26)=>({nativeEvent:{locationX:x,locationY:geometry.keyCenter(digit)}} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[0]);
    const gesture={} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[1];
    act(()=>keypad.onPanResponderGrant!(at(1),gesture));
    act(()=>keypad.onPanResponderMove!(at(4),gesture));
    act(()=>keypad.onPanResponderRelease!(at(6),gesture));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: 6');
    expect(screen.getByTestId('sudoku-eraser')).toHaveStyle({top:geometry.eraserTop,height:geometry.eraserHeight});
    fireEvent.press(screen.getByTestId('sudoku-eraser'));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: empty');
    for(const x of [-1,sudokuMetrics.keyHeight]) {
      act(()=>keypad.onPanResponderGrant!(at(2),gesture));
      act(()=>keypad.onPanResponderRelease!(at(3,x),gesture));
      expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: empty');
    }
  } finally {responder.mockRestore();dimensions.mockRestore();}
});

test.each([1,9])('both landscape preview pointers meet digit %i and keep their bodies toward the board',trackedKey=>{
  const height=landscapeSide;
  const geometry=keypadColumnGeometry(height);
  const keyCenter=geometry.keyCenter(trackedKey);
  const bubbleCenter=Math.min(Math.max(keyCenter,34),height-34);
  const props={game:newGame(),width:360,height,layout:'column' as const,selected:0,
    notesMode:false,assist:false,trackedKey,canEnter:true,canErase:false,
    onEnter:jest.fn(),onErase:jest.fn(),panHandlers:{}};
  for(const edge of ['leading','trailing'] as const){
    const view=render(<SudokuKeypad {...props} edge={edge}/>);
    const bubble=screen.root.findAll((node:{type:unknown;props:{pointerEvents?:string;accessibilityElementsHidden?:boolean}})=>node.type==='View'&&node.props.pointerEvents==='none'&&node.props.accessibilityElementsHidden)[0]!;
    const body=bubble.findAll((node:{type:unknown})=>node.type==='View')[1]!;
    const tail=bubble.findAll((node:{type:unknown})=>node.type==='View')[2]!;
    expect(body.findAllByType(Text)[0]!.props.children).toBe(trackedKey);
    expect(bubble).toHaveStyle({top:bubbleCenter-34,flexDirection:edge==='leading'?'row-reverse':'row'});
    expect(tail).toHaveStyle({transform:[{translateY:keyCenter-bubbleCenter}]});
    if(edge==='leading'){
      expect(screen.getByTestId('sudoku-digit-group')).toHaveStyle({left:0,width:sudokuMetrics.keyHeight});
      expect(screen.getByTestId('sudoku-keypad-touch',{includeHiddenElements:true})).toHaveStyle({left:0,width:sudokuMetrics.keyHeight});
      expect(bubble).toHaveStyle({left:sudokuMetrics.keyHeight});
      expect(tail).toHaveStyle({borderLeftWidth:0,borderRightWidth:10,borderRightColor:colors.cardBackground});
    }else{
      expect(bubble).toHaveStyle({left:sudokuMetrics.keypadHeight-sudokuMetrics.keyHeight-76});
      expect(tail).toHaveStyle({borderLeftWidth:10,borderLeftColor:colors.cardBackground});
      expect(StyleSheet.flatten(tail.props.style).borderRightWidth??0).toBe(0);
    }
    view.unmount();
  }
});

test('landscape spreads the six rail controls at one uniform distance',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider><SudokuScreen/></Provider>);
    const band=landscapeDimensions.height-2*(Math.max(0,21,foundation.space.md)+foundation.space.md);
    const gap=Math.max(0,Math.min(foundation.space.md,(band-6*foundation.control.target-2*foundation.space.sm)/6));
    expect(screen.getByTestId('sudoku-rail')).toHaveStyle({justifyContent:'space-between',gap});
    expect(tool('sudoku-two-player')).toHaveStyle({borderRadius:foundation.radius.control});
    expect(screen.queryByTestId('sudoku-p2-digit-group')).toBeNull();
  } finally {dimensions.mockRestore();}
});

test('a landscape band too short for six targets keeps the five-control rail',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue({width:700,height:320,scale:3,fontScale:1});
  try {
    render(<Provider><SudokuScreen/></Provider>);
    expect(tool('sudoku-rail')).toBeOnTheScreen();
    expect(screen.queryByTestId('sudoku-two-player')).toBeNull();
  } finally {dimensions.mockRestore();}
});

// The native-driver Jest preset completes after 16ms without updating opacity.
// Model the real rail lifetime so tests can inspect both halves of the fade.
function mockRailFade(){
  jest.useFakeTimers();
  const timing=Animated.timing;
  return jest.spyOn(Animated,'timing').mockImplementation((value,config)=>{
    if(config.duration!==240||config.toValue!==1||!config.useNativeDriver)return timing(value,config);
    let timer:ReturnType<typeof setTimeout>|undefined;
    return {
      start:callback=>{timer=setTimeout(()=>{(value as Animated.Value).setValue(1);callback?.({finished:true});},240);},
      stop:()=>{if(timer)clearTimeout(timer);},
      reset:()=>{if(timer)clearTimeout(timer);(value as Animated.Value).setValue(0);},
    };
  });
}
test('starting two-player swaps the rail for a digits-only left keypad and flashes the exit caption',()=>{
  const animation=mockRailFade();
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider initialGame={newGame()}><SudokuScreen/></Provider>);
    // Both modes reserve identical chrome, so fading the rails cannot move the board.
    expect(screen.getByTestId('sudoku-left-chrome')).toHaveStyle({width:sudokuMetrics.keypadHeight});
    const board=screen.getByTestId('sudoku-board');
    pressTool('sudoku-two-player');
    act(()=>jest.advanceTimersByTime(240));
    expect(screen.queryByTestId('sudoku-rail')).toBeNull();
    expect(screen.getByTestId('sudoku-left-chrome')).toHaveStyle({width:sudokuMetrics.keypadHeight});
    expect(screen.getByTestId('sudoku-board')).toBe(board);
    expect(board).toHaveStyle({width:landscapeSide,height:landscapeSide});
    expect(screen.getByTestId('sudoku-p2-digit-group')).toHaveStyle({left:0,flexDirection:'column',borderRadius:foundation.radius.control,overflow:'hidden'});
    expect(screen.getByTestId('sudoku-p2-keypad-touch',{includeHiddenElements:true})).toHaveStyle({left:0});
    expect(screen.getByTestId('sudoku-p2-digit-9')).toBeOnTheScreen();
    expect(screen.getByTestId('sudoku-digit-group')).toBeOnTheScreen();
    expect(screen.queryByTestId('sudoku-p2-eraser')).toBeNull();
    expect(screen.getByText('2P mode until landscape mode ends',{includeHiddenElements:true})).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    pressTool('sudoku-p2-digit-5');
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: 5');
    pressTool('sudoku-digit-1');
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: 1');
    // Erase stays on P1's pad even while the left pad is live.
    expect(tool('sudoku-eraser')).toBeOnTheScreen();
  } finally {animation.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});

test('the menu and leading keypad overlap throughout a native opacity cross-fade',()=>{
  const animation=mockRailFade();
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider initialGame={newGame()}><SudokuScreen/></Provider>);
    const board=screen.getByTestId('sudoku-board');
    pressTool('sudoku-two-player');
    expect(animation).toHaveBeenCalledWith(expect.any(Animated.Value),{toValue:1,duration:240,useNativeDriver:true});
    const menu=screen.getByTestId('sudoku-menu-rail-layer',{includeHiddenElements:true});
    const pad=screen.getByTestId('sudoku-p2-rail-layer',{includeHiddenElements:true});
    expect(menu).toHaveStyle({position:'absolute',left:0,right:0,top:0,bottom:0});
    expect(pad).toHaveStyle({position:'absolute',left:0,right:0,top:0,bottom:0});
    expect(menu).toHaveProp('pointerEvents','none');
    expect(menu).toHaveProp('accessibilityElementsHidden',true);
    const mix=animation.mock.calls.find(([,config])=>config.duration===240&&config.toValue===1)![0] as Animated.Value;
    act(()=>{jest.advanceTimersByTime(120);mix.setValue(0.5);});
    expect(screen.getByTestId('sudoku-menu-rail-layer',{includeHiddenElements:true})).toBeOnTheScreen();
    expect(screen.getByTestId('sudoku-board')).toBe(board);
    expect(menu).toHaveStyle({opacity:0.5});
    expect(pad).toHaveStyle({opacity:0.5});
    act(()=>jest.advanceTimersByTime(200));
    expect(screen.queryByTestId('sudoku-menu-rail-layer',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByTestId('sudoku-p2-digit-group')).toHaveStyle({left:0});
  } finally {animation.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});

test.each(['en','ja'])('starting two-player announces the localized exit instruction once in %s',locale=>{
  const animation=mockRailFade();
  const announcement=jest.spyOn(AccessibilityInfo,'announceForAccessibility').mockImplementation(()=>{});
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  configurePresentation({locale,textScales:null});
  try {
    render(<Provider initialGame={newGame()}><SudokuScreen/></Provider>);
    expect(announcement).not.toHaveBeenCalled();
    pressTool('sudoku-two-player');
    act(()=>jest.advanceTimersByTime(240));
    expect(announcement).toHaveBeenCalledTimes(1);
    expect(announcement).toHaveBeenCalledWith(localized('2P mode until landscape mode ends'));
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    pressTool('sudoku-p2-digit-5');
    expect(announcement).toHaveBeenCalledTimes(1);
  } finally {animation.mockRestore();configurePresentation();announcement.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});

test('the left keypad scrubs with its own preview and commits into the shared selection',()=>{
  const animation=mockRailFade();
  const responder=jest.spyOn(PanResponder,'create');
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockReturnValue(landscapeDimensions);
  try {
    render(<Provider initialGame={newGame()}><SudokuScreen/></Provider>);
    pressTool('sudoku-two-player');
    act(()=>jest.advanceTimersByTime(240));
    const keypad=responder.mock.calls[2]![0];
    fireEvent.press(screen.getByTestId('sudoku-cell-0'));
    const geometry=keypadColumnGeometry(landscapeSide);
    const at=(digit:number,x=26)=>({nativeEvent:{locationX:x,locationY:geometry.keyCenter(digit)}} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[0]);
    const gesture={} as Parameters<NonNullable<typeof keypad.onPanResponderGrant>>[1];
    act(()=>keypad.onPanResponderGrant!(at(1),gesture));
    act(()=>keypad.onPanResponderMove!(at(4),gesture));
    // The preview belongs to the pad under the finger; the other pad stays quiet.
    expect(screen.getByTestId('sudoku-p2-digit-4')).toHaveStyle({backgroundColor:colors.safeControlGreen});
    expect(screen.getByTestId('sudoku-digit-4')).not.toHaveStyle({backgroundColor:colors.safeControlGreen});
    act(()=>keypad.onPanResponderRelease!(at(7),gesture));
    expect(screen.getByTestId('sudoku-cell-0')).toHaveProp('accessibilityLabel','Row 1, column 1: 7');
  } finally {animation.mockRestore();responder.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});

test('leaving landscape ends two-player mode and the next landscape entry starts single-player',()=>{
  const animation=mockRailFade();
  let window={width:844,height:390,scale:3,fontScale:1};
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockImplementation(()=>window);
  try {
    const view=render(<Provider><SudokuScreen/></Provider>);
    pressTool('sudoku-two-player');
    act(()=>jest.advanceTimersByTime(240));
    expect(screen.queryByTestId('sudoku-rail')).toBeNull();
    window={width:390,height:844,scale:3,fontScale:1};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(tool('sudoku-rail')).toBeOnTheScreen();
    expect(screen.queryByTestId('sudoku-p2-digit-group')).toBeNull();
    window={width:844,height:390,scale:3,fontScale:1};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(tool('sudoku-rail')).toBeOnTheScreen();
    expect(tool('sudoku-two-player')).toBeOnTheScreen();
    expect(screen.queryByTestId('sudoku-p2-digit-group')).toBeNull();
  } finally {animation.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});

test('rotation during the rail fade cancels it and restores the single-player menu',()=>{
  const animation=mockRailFade();
  let window={...landscapeDimensions};
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions').mockImplementation(()=>window);
  try {
    const view=render(<Provider><SudokuScreen/></Provider>);
    pressTool('sudoku-two-player');
    act(()=>jest.advanceTimersByTime(100));
    window={width:390,height:844,scale:3,fontScale:1};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    act(()=>jest.advanceTimersByTime(300));
    expect(tool('sudoku-rail')).toBeOnTheScreen();
    window={...landscapeDimensions};
    view.rerender(<Provider><SudokuScreen/></Provider>);
    expect(tool('sudoku-two-player')).toBeOnTheScreen();
    expect(screen.queryByTestId('sudoku-p2-rail-layer',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByTestId('sudoku-menu-rail-layer')).toHaveStyle({opacity:1});
  } finally {animation.mockRestore();dimensions.mockRestore();jest.useRealTimers();}
});
