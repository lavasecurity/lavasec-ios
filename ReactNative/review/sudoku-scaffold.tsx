import {memo,useContext,useMemo,type ComponentRef,type Ref} from 'react';
import {ActivityIndicator, Animated, Pressable, StyleSheet, View, type GestureResponderHandlers} from 'react-native';
import {Text, localized, localizedFormat,PresentationContext} from '../app/presentation';
import {LavaActionButton, LavaIconButton, type LavaIconAction} from '../src';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {Copy, Symbol} from './primitives';
import {cellLabel, keypadColumnGeometry, keypadGeometry, keypadShortSide, workingBoard, type SudokuGame} from './sudoku-model';
import {revealFontSize, revealLineHeight, revealTileOffset} from './sudoku-reveal';

// Gameplay keeps a stable native cell tree. Selection/preview changes update
// only affected memoized cells/keys; labels and counts follow game/locale changes.
type CellProps={index:number;cell:number;given:boolean;value:number;notes:readonly number[];active:boolean;lockedTrack:boolean;
  notesMode:boolean;assist:boolean;correct:boolean;loading:boolean;locked:boolean;label:string;onChoose:(index:number)=>void};
const SudokuCell=memo(function SudokuCell({index,cell,given,value,notes,active,lockedTrack,notesMode,assist,correct,loading,locked,label,onChoose}:CellProps){
  const fill=active?colors.safeGreen:lockedTrack||given?colors.secondaryText:notesMode&&!value&&notes.length?colors.softGreen:undefined;
  return <Pressable testID={`sudoku-cell-${index}`} accessibilityRole={given?'text':'button'} accessibilityLabel={label}
    accessibilityState={{selected:active,disabled:loading||locked&&!given}} disabled={loading} onPress={()=>onChoose(index)} style={[s.cell,{width:cell,height:cell}]}>
    {fill&&<View pointerEvents="none" style={[StyleSheet.absoluteFill,{backgroundColor:fill,opacity:active||lockedTrack?0.24:given?0.1:1}]}/>}
    {value!==0?<Text allowFontScaling={false} style={[s.numeral,{fontSize:cell*0.55,fontWeight:given?'700':'400',color:given?colors.ink:!assist||correct?colors.safeGreen:colors.lavaOrangeText}]}>{value}</Text>
      :notesMode&&notes.length>0&&<View style={[s.notes,{width:cell,height:cell}]}>{notes.map(digit=><Text key={digit} allowFontScaling={false} numberOfLines={1} adjustsFontSizeToFit minimumFontScale={0.18}
        style={[s.note,{fontSize:cell*0.55}]}>{digit}</Text>)}</View>}
    {(active||lockedTrack)&&<View pointerEvents="none" style={[StyleSheet.absoluteFill,{borderWidth:2.5,borderColor:active?colors.safeGreen:colors.secondaryText,opacity:active?1:0.72}]}/>}
  </Pressable>;
});
const SudokuGrid=memo(function SudokuGrid({side,cell}:{side:number;cell:number}) {
  return <>{Array.from({length:8},(_,index)=>index+1).map(line=>{
    const thick=line%3===0,size=thick?2.5:1;
    const style={position:'absolute' as const,backgroundColor:thick?colors.ink:colors.secondaryText,opacity:thick?0.85:0.35};
    return <View key={line} pointerEvents="none" style={StyleSheet.absoluteFill}>
      <View style={[style,{left:line*cell-size/2,top:0,width:size,height:side}]}/><View style={[style,{left:0,top:line*cell-size/2,width:side,height:size}]}/>
    </View>;
  })}</>;
});
export const SudokuBoard=memo(function SudokuBoard({game,side,selected,tracking,notesMode,assist,loading,ready,boardRef,onChoose,panHandlers,revealEmoji,revealTiles}:{
  game:SudokuGame;side:number;selected?:number;tracking?:number;notesMode:boolean;assist:boolean;loading:boolean;ready:boolean;
  boardRef:Ref<ComponentRef<typeof View>>;onChoose:(index:number)=>void;panHandlers:GestureResponderHandlers;
  revealEmoji?:string;revealTiles?:readonly {index:number;opacity:Animated.Value}[];
}) {
  const {locale}=useContext(PresentationContext);const cell=side/9;
  const state=useMemo(()=>{
    const board=workingBoard(game);
    return {board,locked:board.every((value,index)=>value===game.puzzle.solution[index]),complete:board.every(Boolean),filled:board.filter(Boolean).length,
      labels:board.map((_,index)=>cellLabel(game,index,notesMode,assist,localizedFormat))};
  },[game,notesMode,assist,locale]);
  return <View ref={boardRef} testID="sudoku-board" pointerEvents={loading?'none':'auto'}
    accessibilityElementsHidden={!ready} importantForAccessibility={ready?'auto':'no-hide-descendants'}
    style={[s.board,{width:side,height:side},!ready&&s.hiddenBoard]} {...panHandlers}>
    <View accessible accessibilityRole="text" accessibilityLabel={localized(state.locked?'Sudoku board, solved':state.complete?'Sudoku board, complete but with errors':'Sudoku board')}
      accessibilityValue={{text:localizedFormat('%lld of 81 cells filled',state.filled)}} style={s.boardDescription}/>
    {Array.from({length:9},(_,row)=><View key={row} style={s.row}>{Array.from({length:9},(_,col)=>{
      const index=row*9+col,given=game.puzzle.givens[index]!==0;
      return <SudokuCell key={index} index={index} cell={cell} given={given} value={state.board[index]!} notes={game.notes[index]!}
        active={selected===index} lockedTrack={tracking===index&&given} notesMode={notesMode} assist={assist}
        correct={state.board[index]===game.puzzle.solution[index]} loading={loading} locked={state.locked} label={state.labels[index]!} onChoose={onChoose}/>;
    })}</View>)}
    {revealEmoji!==undefined&&revealTiles!==undefined&&revealTiles.length>0&&
      // Opaque tiles sit between the cells and the grid so they cover the digit
      // (and the cell's given tint, reproduced below) while the grid lines and
      // outline stay on top. Pointer-transparent: the board responder owns the
      // gesture; nothing here changes gameplay rendering.
      <View pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={StyleSheet.absoluteFill}>
        {revealTiles.map(({index,opacity})=>{
          const col=index%9,row=Math.floor(index/9),given=game.puzzle.givens[index]!==0,offset=revealTileOffset(index,side);
          return <Animated.View key={index} testID={`sudoku-reveal-tile-${index}`} style={[s.revealTile,{left:col*cell,top:row*cell,width:cell,height:cell,opacity}]}>
            {given&&<View pointerEvents="none" style={[StyleSheet.absoluteFill,{backgroundColor:colors.secondaryText,opacity:0.1}]}/>}
            <View pointerEvents="none" style={{position:'absolute',left:offset.left,top:offset.top,width:side,height:side,justifyContent:'center'}}>
              <Text allowFontScaling={false} numberOfLines={1} style={[s.revealGlyph,{fontSize:revealFontSize(side),lineHeight:revealLineHeight(side)}]}>{revealEmoji}</Text>
            </View>
          </Animated.View>;
        })}
      </View>}
    <SudokuGrid side={side} cell={cell}/>
    <View pointerEvents="none" style={[StyleSheet.absoluteFill,s.boardOutline,{borderColor:state.locked?colors.safeGreen:state.complete?colors.lavaOrange:colors.ink,opacity:state.locked||state.complete?1:0.85}]}/>
  </View>;
});
const SudokuDigit=memo(function SudokuDigit({digit,noted,highlighted,canEnter,assist,remaining,notesMode,onEnter,size,column=false,inline=false,testIDPrefix='sudoku'}:{
  digit:number;noted:boolean;highlighted:boolean;canEnter:boolean;assist:boolean;remaining:number;notesMode:boolean;onEnter:(digit:number)=>void;
  size?:{width:number;height:number};column?:boolean;inline?:boolean;testIDPrefix?:string;
}) {
  useContext(PresentationContext);
  return <Pressable testID={`${testIDPrefix}-digit-${digit}`} accessibilityRole="button" accessibilityLabel={String(digit)}
    accessibilityValue={{text:assist?localizedFormat('%lld remaining',remaining):''}} accessibilityState={{disabled:!canEnter,selected:noted}}
    accessibilityHint={localizedFormat(notesMode?'Toggles candidate %lld in the selected cell':'Places %lld in the selected cell',digit)} disabled={!canEnter} onPress={()=>onEnter(digit)}
    style={[s.key,size?{width:size.width,height:size.height}:s.keyRow,inline&&{flexDirection:'row'},
      digit<9&&(column?s.keyDividerColumn:s.keyDividerRow),highlighted&&s.keyHighlighted]}>
    <Text allowFontScaling={false} style={[s.keyText,highlighted&&s.keyTextHighlighted,!canEnter&&s.keyTextDisabled]}>{digit}</Text>
    {assist&&<Text allowFontScaling={false} style={[s.remaining,highlighted&&s.keyTextHighlighted]}>{remaining}</Text>}
  </Pressable>;
});
export const SudokuKeypad=memo(function SudokuKeypad({game,width,height=0,layout='row',selected,notesMode,assist,trackedKey,canEnter,canErase,onEnter,onErase,panHandlers,testIDPrefix='sudoku',showsEraser=true,edge='trailing'}:{
  game:SudokuGame;width:number;height?:number;layout?:'row'|'column';selected?:number;notesMode:boolean;assist:boolean;trackedKey?:number;canEnter:boolean;canErase:boolean;
  onEnter:(digit:number)=>void;onErase:()=>void;panHandlers:GestureResponderHandlers;testIDPrefix?:string;showsEraser?:boolean;edge?:'leading'|'trailing';
}) {
  const {board,remaining}=useMemo(()=>{
    const board=workingBoard(game),counts=Array<number>(10).fill(0);
    for(const value of board)if(value)counts[value]=(counts[value]??0)+1;
    return {board,remaining:counts.map(count=>Math.max(0,9-count))};
  },[game]);
  const column=layout==='column';
  const leading=column&&edge==='leading';
  const rowGeometry=useMemo(()=>column?undefined:keypadGeometry(width),[column,width]);
  const columnGeometry=useMemo(()=>column?keypadColumnGeometry(height):undefined,[column,height]);
  const keyCenter=trackedKey===undefined?0:columnGeometry?columnGeometry.keyCenter(trackedKey):rowGeometry!.keyCenter(trackedKey);
  const bubbleCenter=Math.min(Math.max(keyCenter,34),(column?height:width)-34);
  const digits=Array.from({length:9},(_,index)=>index+1).map(digit=>{
    const noted=notesMode&&selected!==undefined&&board[selected]===0&&game.notes[selected]!.includes(digit);
    // A transposed key keeps the portrait key's short side and only stretches
    // along the column. Stacked assist counts no longer fit at phone heights,
    // so those keys place the digit and count side by side instead.
    const keyHeight=columnGeometry?.keyHeight??0;
    return <SudokuDigit key={digit} digit={digit} noted={noted} highlighted={trackedKey===digit||noted} canEnter={canEnter}
      assist={assist} remaining={remaining[digit]!} notesMode={notesMode} onEnter={onEnter} testIDPrefix={testIDPrefix}
      size={columnGeometry&&{width:sudokuMetrics.keyHeight,height:keyHeight}} column={column}
      inline={column&&keyHeight<foundation.type.heading.fontSize+foundation.type.caption.fontSize+foundation.space.xs}/>;
  });
  const eraseGlyph=<Symbol name="eraser" size={foundation.control.glyphSlot} pointSize={foundation.control.glyph} tone="primary"/>;
  return <View style={column?[s.keypadColumn,{height}]:s.keypad}>
    {showsEraser&&canErase&&trackedKey===undefined&&<Pressable testID={`${testIDPrefix}-eraser`} accessibilityRole="button" accessibilityLabel={localized('Erase selected cell')}
      onPress={onErase} style={({pressed})=>[column?s.eraseColumn:s.erase,
        column?{top:columnGeometry!.eraserTop,height:columnGeometry!.eraserHeight}:{left:rowGeometry!.eraserLeft,width:rowGeometry!.eraserWidth},
        pressed&&s.keyHighlighted]}>{eraseGlyph}</Pressable>}
    <View testID={`${testIDPrefix}-digit-group`} style={column?[s.column,leading&&s.columnLeading]:s.keys}>{digits}</View>
    <View testID={`${testIDPrefix}-keypad-touch`} accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
      pointerEvents={canEnter?'auto':'none'} style={column?[s.touchColumn,leading&&s.columnLeading]:s.touchLayer} {...panHandlers}/>
    {trackedKey!==undefined&&(column
      ? <View pointerEvents="none" accessibilityElementsHidden style={[s.bubbleColumn,leading&&s.bubbleColumnLeading,{top:bubbleCenter-34}]}>
        <View style={s.bubbleBodyColumn}><Text allowFontScaling={false} style={s.bubbleText}>{trackedKey}</Text></View>
        <View style={[s.bubbleTailColumn,leading&&s.bubbleTailColumnLeading,{transform:[{translateY:columnGeometry!.keyCenter(trackedKey)-bubbleCenter}]}]}/>
      </View>
      : <View pointerEvents="none" accessibilityElementsHidden style={[s.bubble,{left:bubbleCenter-34}]}>
        <View style={s.bubbleBody}><Text allowFontScaling={false} style={s.bubbleText}>{trackedKey}</Text></View>
        <View style={[s.bubbleTail,{transform:[{translateX:rowGeometry!.keyCenter(trackedKey)-bubbleCenter}]}]}/>
      </View>)}
  </View>;
});

export function SudokuOutcome({outcome}:{outcome?:boolean}) {
  return outcome!==undefined?<View accessible accessibilityRole="image" testID="sudoku-correctness-outcome" accessibilityLabel={localized(outcome?'Correctly placed':'Misplaced')}>
    <Symbol name={outcome?'checkmark.circle.fill':'xmark.circle.fill'} size={foundation.control.target} pointSize={foundation.type.heading.fontSize} tone={outcome?'green':'orange'}/>
  </View>:null;
}
export function SudokuFeedback({loading,error,outcome,onRetry,column=false,testID='sudoku-feedback-band'}:{loading:boolean;error?:string;outcome?:boolean;onRetry:()=>void;column?:boolean;testID?:string}) {
  return <View style={column?s.outcomeBandColumn:s.outcomeBand} testID={testID}>
    {loading?<View style={s.loadMessage}>{error?<><Copy role="supporting" center>{error}</Copy><LavaActionButton title="Try again" role="secondary" onPress={onRetry}/></>:<ActivityIndicator accessibilityLabel={localized('Preparing puzzle')}/>}</View>
      :<SudokuOutcome outcome={outcome}/>}
  </View>;
}

// The rail has one layout and one set of controls. Only its axis changes:
// Close stays at the leading edge, and the tools stay at the trailing edge.
// Landscape adds the two-player control directly after Close: the six controls
// then spread at one uniform distance (the flexible spacer is dropped), and only
// the minimum gap is enforced when a short band cannot host that spacing.
export type SudokuTool={id:string;label:string;icon:LavaIconAction;selected?:boolean;prominent?:boolean;disabled:boolean;onPress:()=>void;onLongPress?:()=>void;longPressDelayMs?:number};
export function SudokuRail({tools,onClose,landscape=false,availableHeight,onStartTwoPlayer,flash}:{
  tools:readonly SudokuTool[];onClose:()=>void;landscape?:boolean;availableHeight?:number;onStartTwoPlayer?:()=>void;
  flash?:{id:string;opacity:Animated.Value};
}) {
  // Six 44pt targets plus the rail's own padding are the physical floor for the
  // two-player control. Below it the control is omitted rather than shrinking a
  // target under the accessibility minimum; every supported device clears it.
  const fitsTwoPlayer=availableHeight===undefined
    ||availableHeight>=(tools.length+2)*foundation.control.target+2*foundation.space.sm;
  const showsTwoPlayer=landscape&&onStartTwoPlayer!==undefined&&fitsTwoPlayer;
  // The spacer is a flex child, so portrait's five controls create five gaps.
  // Compress those gaps only when a short landscape viewport cannot fit 12pt spacing.
  const controls=tools.length+1+(showsTwoPlayer?1:0);
  const gap=landscape&&availableHeight!==undefined
    ? Math.max(0,Math.min(foundation.space.md,(availableHeight-controls*foundation.control.target-2*foundation.space.sm)/controls))
    : undefined;
  return <View testID="sudoku-rail" style={[s.rail,landscape?s.railColumn:s.railRow,showsTwoPlayer&&s.railEven,gap!==undefined&&{gap}]}>
    <LavaIconButton title="Close" icon="close" shape="rounded" onPress={onClose} testID="sudoku-close"/>
    {showsTwoPlayer&&onStartTwoPlayer&&<LavaIconButton title="Two-player mode" icon="twoPeople" shape="rounded" onPress={onStartTwoPlayer} testID="sudoku-two-player"/>}
    {!showsTwoPlayer&&<View style={s.flexible}/>}
    {tools.map(tool=><View key={tool.id} style={s.toolSlot}>
      <LavaIconButton title={tool.label} icon={tool.icon} shape="rounded" selected={tool.selected??false} prominent={tool.prominent??false} disabled={tool.disabled} onPress={tool.onPress} onLongPress={tool.onLongPress} longPressDelayMs={tool.longPressDelayMs} testID={tool.id}/>
      {flash?.id===tool.id&&<Animated.View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[s.toolFlash,{opacity:flash.opacity}]}/>}
    </View>)}
  </View>;
}

// Sudoku is a diagram, so its numerals scale with its cells, not Dynamic Type.
// Its toolbars, state feedback and keypad use the same foundation as other pages.
// Portrait measures the keypad and rail as bands; landscape swaps their axes.
export const sudokuMetrics={keypadHeight:140,keyHeight:keypadShortSide,eraserGap:18,minimumSide:297,feedbackHeight:44,verticalChrome:204,
  landscapeMaximumSide:560,landscapePadding:foundation.space.sm};
const numberOffset=sudokuMetrics.keypadHeight-sudokuMetrics.keyHeight;
const eraserOffset=numberOffset-foundation.control.target-sudokuMetrics.eraserGap;
const bubbleOffset=numberOffset-76; // 66pt preview and 10pt tail end at the digit group.
export const sudokuStyles=StyleSheet.create({
  root:{flex:1,backgroundColor:colors.groupedBackground},
  content:{width:'100%',alignSelf:'center',maxWidth:foundation.layout.readingWidth,paddingHorizontal:foundation.space.screenHorizontal,paddingBottom:foundation.space.lg},
  flexible:{flex:1},
  outcomeBand:{flex:1,minHeight:sudokuMetrics.feedbackHeight,alignItems:'center',justifyContent:'center'},
  loadMessage:{alignItems:'center',gap:foundation.space.sm},
  // Clip cell fills to the same curve as the inside outline. The measured
  // square and per-cell hit rectangles remain unchanged.
  board:{alignSelf:'center',borderRadius:foundation.radius.compact,overflow:'hidden'},
  hiddenBoard:{opacity:0},
  row:{flexDirection:'row'},
  cell:{alignItems:'center',justifyContent:'center'},
  boardDescription:{position:'absolute',width:1,height:1},
  // Opaque reveal window: the board surface colour so the tile hides the digit
  // without looking like a sticker, clipped to the cell.
  revealTile:{position:'absolute',overflow:'hidden',backgroundColor:colors.groupedBackground},
  revealGlyph:{textAlign:'center'},
  numeral:{fontFamily:'ui-rounded'},
  notes:{flexDirection:'row',alignItems:'center'},
  note:{flex:1,textAlign:'center',fontFamily:'ui-rounded',fontStyle:'italic',color:colors.secondaryText},
  boardOutline:{borderRadius:foundation.radius.compact,borderWidth:3},
  keypad:{height:sudokuMetrics.keypadHeight,paddingTop:foundation.space.md},
  erase:{position:'absolute',top:eraserOffset,height:foundation.control.target,borderRadius:foundation.radius.control,backgroundColor:colors.cardBackground,alignItems:'center',justifyContent:'center'},
  keys:{position:'absolute',left:0,right:0,top:numberOffset,height:sudokuMetrics.keyHeight,flexDirection:'row',borderRadius:foundation.radius.control,borderCurve:'continuous',overflow:'hidden',backgroundColor:colors.cardBackground},
  key:{height:sudokuMetrics.keyHeight,alignItems:'center',justifyContent:'center',gap:foundation.space.xs},
  keyDividerRow:{borderRightWidth:1,borderRightColor:colors.separator},
  keyDividerColumn:{borderBottomWidth:1,borderBottomColor:colors.separator},
  // Flex belongs only to row keys; retaining it in the column collapses their Yoga height to zero.
  keyRow:{flex:1},
  keyHighlighted:{backgroundColor:colors.safeControlGreen},
  keyText:{fontSize:foundation.type.heading.fontSize,fontWeight:'700',color:colors.primaryText},
  keyTextHighlighted:{color:colors.actionForeground},
  keyTextDisabled:{color:colors.secondaryText},
  remaining:{fontSize:foundation.type.caption.fontSize,fontVariant:['tabular-nums'],color:colors.secondaryText},
  touchLayer:{position:'absolute',left:0,right:0,top:numberOffset,height:sudokuMetrics.keyHeight},
  bubble:{position:'absolute',top:bubbleOffset,width:68,alignItems:'center'},
  bubbleBody:{width:68,height:66,borderRadius:foundation.radius.control,borderCurve:'continuous',backgroundColor:colors.cardBackground,alignItems:'center',justifyContent:'center'},
  bubbleText:{fontFamily:'ui-rounded',fontSize:foundation.type.metric.fontSize,fontWeight:'700',color:colors.primaryText},
  bubbleTail:{marginTop:-1,width:0,height:0,borderLeftWidth:9,borderRightWidth:9,borderTopWidth:10,borderLeftColor:'transparent',borderRightColor:'transparent',borderTopColor:colors.cardBackground},
  // Landscape is the portrait composition transposed: every fixed measurement
  // keeps its value and only moves to the other axis. The board stays square.
  outcomeBandColumn:{width:sudokuMetrics.feedbackHeight,alignItems:'center',justifyContent:'center'},
  keypadColumn:{width:sudokuMetrics.keypadHeight,paddingLeft:foundation.space.md,alignSelf:'center'},
  column:{position:'absolute',top:0,bottom:0,left:numberOffset,width:sudokuMetrics.keyHeight,flexDirection:'column',borderRadius:foundation.radius.control,borderCurve:'continuous',overflow:'hidden',backgroundColor:colors.cardBackground},
  columnLeading:{left:0},
  // P2's preview grows toward the board, away from the safe-area edge.
  bubbleColumnLeading:{left:sudokuMetrics.keyHeight,flexDirection:'row-reverse'},
  bubbleTailColumnLeading:{marginLeft:0,marginRight:-1,borderLeftWidth:0,borderRightWidth:10,borderLeftColor:'transparent',borderRightColor:colors.cardBackground},
  eraseColumn:{position:'absolute',left:eraserOffset,width:foundation.control.target,borderRadius:foundation.radius.control,backgroundColor:colors.cardBackground,alignItems:'center',justifyContent:'center'},
  touchColumn:{position:'absolute',top:0,bottom:0,left:numberOffset,width:sudokuMetrics.keyHeight},
  bubbleColumn:{position:'absolute',left:bubbleOffset,height:68,flexDirection:'row',alignItems:'center'},
  bubbleBodyColumn:{width:66,height:68,borderRadius:foundation.radius.control,borderCurve:'continuous',backgroundColor:colors.cardBackground,alignItems:'center',justifyContent:'center'},
  bubbleTailColumn:{marginLeft:-1,width:0,height:0,borderTopWidth:9,borderBottomWidth:9,borderLeftWidth:10,borderTopColor:'transparent',borderBottomColor:'transparent',borderLeftColor:colors.cardBackground},
  // The same 44pt rail occupies the top in portrait and the left in landscape.
  landscapeRow:{flex:1,flexDirection:'row'},
  // The held-key preview floats over feedback in the neighboring gutter.
  landscapeLeftChrome:{width:sudokuMetrics.keypadHeight,alignSelf:'stretch',zIndex:1},
  landscapeRailLayer:{position:'absolute',left:0,right:0,top:0,bottom:0,alignItems:'flex-start'},
  landscapeKeypadLayer:{position:'absolute',left:0,right:0,top:0,bottom:0,justifyContent:'center'},
  landscapeCenter:{flex:1,alignItems:'center',justifyContent:'center'},
  landscapeBoardRow:{width:'100%',flexDirection:'row',alignItems:'center'},
  landscapeGutter:{flex:1,alignSelf:'stretch',alignItems:'center',justifyContent:'center'},
  // The leading keypad reserves preview space beyond its visible digit rail. Center
  // feedback between the visible rail and board, without moving either layout frame.
  landscapeOutcomeGutter:{transform:[{translateX:-numberOffset/2}]},
  landscapeOverlay:{position:'absolute',left:0,right:0,top:0,bottom:0,alignItems:'center',justifyContent:'center'},
  // The quiet two-player caption hangs just below the board, outside its layout,
  // so the board never moves when it appears or fades.
  twoPlayerCaption:{position:'absolute',left:0,right:0,alignItems:'center'},
  twoPlayerCaptionText:{fontSize:foundation.type.caption.fontSize,color:colors.secondaryText,textAlign:'center'},
  rail:{alignSelf:'stretch',alignItems:'center',justifyContent:'flex-start',gap:foundation.space.md},
  // A fixed slot keeps the rail spacing intact while an accepted long-press paints the
  // challenge flash over the control; the flash is pointer-transparent and fades out.
  toolSlot:{width:foundation.control.target,height:foundation.control.target},
  toolFlash:{position:'absolute',top:0,left:0,width:foundation.control.target,height:foundation.control.target,borderRadius:foundation.radius.circle,backgroundColor:colors.lavaOrange},
  // Six controls at one uniform distance: the flexible spacer is replaced by
  // even distribution, and `gap` stays the minimum for short bands.
  railEven:{justifyContent:'space-between'},
  railRow:{height:foundation.control.target,flexDirection:'row',width:'100%',maxWidth:foundation.layout.readingWidth,
    alignSelf:'center',paddingHorizontal:foundation.space.screenHorizontal},
  railColumn:{flex:1,width:foundation.control.target,flexDirection:'column',paddingVertical:foundation.space.sm},
});

const s=sudokuStyles;
