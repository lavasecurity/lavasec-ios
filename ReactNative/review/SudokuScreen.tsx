import {mayInteractWithPresentation,presentationOwnerScope} from '../app/read-cache';
import {useRouteViewState} from '../app/use-route-view-state';
import {usePresentationAuthority,usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useScrollInteractionController,useScrollInteractionLock} from '../src/interaction-lock';
import {Alert, Text, localized} from '../app/presentation';
import {useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ComponentRef} from 'react';
import {AccessibilityInfo, Animated, AppState, PanResponder, ScrollView, View, type ScrollViewInstance} from 'react-native';
import {SafeAreaProvider, useSafeAreaFrame, useSafeAreaInsets} from 'react-native-safe-area-context';
import {useNavigation} from '@react-navigation/native';
import {foundation} from '../src/foundation';
import {SudokuBoard, SudokuFeedback, SudokuKeypad, SudokuRail, sudokuMetrics, sudokuStyles as styles, type SudokuTool} from './sudoku-scaffold';
import {useFeedback} from '../src/feedback';
import {useReview} from './ReviewContext';
import {cellAt, editCell, freshChallengePuzzle, freshPuzzle, isComplete, isSolved, keyAt, keyAtColumn, newGame, workingBoard, type SudokuGame} from './sudoku-model';
import {REVEAL_EASING, REVEAL_FADE_MS, REVEAL_LINGER_MS, cellsBetween, revealEmojiFor} from './sudoku-reveal';

/// Quiet lifetime of the two-player caption: long enough to read once, short
/// enough that it never competes with play.
const TWO_PLAYER_CAPTION_HOLD_MS = 2200;
const TWO_PLAYER_CROSS_FADE_MS = 240;
// Hidden challenge gesture: hold New puzzle for three seconds. The flash and
// caption use the same quiet lifetime as the two-player caption.
const CHALLENGE_LONG_PRESS_MS = 3000;
const CHALLENGE_FLASH_MS = 700;
const CHALLENGE_CAPTION_HOLD_MS = 2600;

export function SudokuScreen() {
  return <SafeAreaProvider><SudokuContent /></SafeAreaProvider>;
}
function SudokuContent() {
  const {session,setSession,app} = useReview();
  const authoritative=usePresentationAuthority(app);
  const readEpoch=app?.getReadEpoch?.();
  const isCurrentAction=()=>!app?.getSnapshot||(mayInteractWithPresentation(app)&&app.getReadEpoch()===readEpoch);
  const generationOwner=useRef({mounted:true,revocation:0});
  useEffect(()=>{
    const owner=generationOwner.current;owner.mounted=true;
    const unsubscribe=app?.subscribe?.(()=>{if(!app.getSnapshot().snapshot)owner.revocation++;});
    return()=>{owner.mounted=false;unsubscribe?.();};
  },[app]);
  const generationAcceptance=()=>{const owner=generationOwner.current,revocation=owner.revocation;
    const snapshot=app?.getSnapshot?.().snapshot,scope=snapshot?presentationOwnerScope(snapshot):undefined;
    return()=>{const current=app?.getSnapshot?.().snapshot;
      return owner.mounted&&owner.revocation===revocation&&(!app?.getSnapshot||(AppState.currentState==='active'&&!!current&&presentationOwnerScope(current)===scope));
    };
  };
  const navigation = useNavigation();
  const onLayout=usePresentationNativeLayout();
  const insets = useSafeAreaInsets();
  // The provider sends frame and insets together. Using the window size here
  // can briefly pair a new orientation with the previous orientation's insets.
  const frame = useSafeAreaFrame();
  const [game,setGame] = useState(() => session.sudoku ?? newGame());
  const [generationError,setGenerationError] = useState<string>();
  const [generation,setGeneration] = useState(0);
  const initialGeneration=useRef<{app:NonNullable<typeof app>}|null>(null);
  const [generationSettled,setGenerationSettled]=useState(0);
  const feedback=useFeedback();
  const feedbackSession=useId();
  const editSequence=useRef(0);
  const [loading,setLoading] = useState(!!app&&!session.sudoku);
  const [ready,setReady] = useState(!app||!!session.sudoku);
  // Native may finish the first generation while this visit is covered. Admit
  // its current saved game without generating again, while ordinary same-puzzle
  // snapshots must not replace local input once preparation has finished.
  useEffect(()=>{
    if(app&&authoritative&&session.sudoku&&(!ready||session.sudoku.puzzle.givens.join('')!==game.puzzle.givens.join(''))) {
      setGame(session.sudoku);clearSelection();setReady(true);setLoading(false);setGenerationError(undefined);
    }
  },[app,authoritative,session.sudoku,ready]);
  useEffect(() => {
    if (!app || !authoritative || ready || session.sudoku || initialGeneration.current?.app===app) return;
    // Detached native work can still publish a saved game after authority is
    // restored. Wait for that work rather than queueing a replacement behind it.
    const flight={app};initialGeneration.current=flight;
    let current=true;const accepted=generationAcceptance();setGenerationError(undefined);setLoading(true);
    void app.command<SudokuGame>({type:'sudoku.new'}).then(next=>{if(current&&accepted()){setGame(next);clearSelection();setReady(true);setLoading(false);}})
      .catch(error=>{if(current&&accepted())setGenerationError(error.message);})
      .finally(()=>{
        if(initialGeneration.current!==flight)return;
        initialGeneration.current=null;
        // Recheck the current native projection when an interrupted request
        // settles. Progress off can retry; a published saved game wins instead.
        if(generationOwner.current.mounted&&(!current||!accepted()))setGenerationSettled(value=>value+1);
      });
    return()=>{current=false;};
  // Restore unfinished preparation only when native authority returns or Retry
  // is requested. A successful read-revision advance is not a new preparation.
  },[app,generation,authoritative,generationSettled]);
  const [selected,setSelected,resetSelection] = useRouteViewState<number|undefined>(undefined);
  const selectedRef=useRef(selected);selectedRef.current=selected;
  const [tracking,setTracking] = useState<number>();
  const [notesMode,setNotesMode,resetNotesMode] = useRouteViewState(false);
  const [assist,setAssist] = useRouteViewState(false);
  const [trackedKey,setTrackedKey] = useState<number>();
  const trackedKeyRef = useRef<number>(undefined);
  // Two-player mode is a landscape affordance with exactly one exit: leaving
  // landscape. The rail is replaced by a second, digits-only keypad, and rotating
  // back to portrait clears the mode so the next landscape entry starts 1P.
  const [twoPlayer,setTwoPlayer,resetTwoPlayer] = useRouteViewState(false);
  const [showsMenuRail,setShowsMenuRail] = useState(true);
  const twoPlayerMix = useRef(new Animated.Value(0)).current;
  const [twoPlayerTrackedKey,setTwoPlayerTrackedKey] = useState<number>();
  const twoPlayerTrackedKeyRef = useRef<number>(undefined);
  const [showsTwoPlayerCaption,setShowsTwoPlayerCaption] = useState(false);
  const twoPlayerCaptionOpacity = useRef(new Animated.Value(0)).current;
  const twoPlayerCaptionAnimation = useRef<Animated.CompositeAnimation|null>(null);
  // Hidden challenge mode: a held New-puzzle press flashes the control and shows a
  // quiet below-board caption. Per-board and transient — the fresh board is an
  // ordinary game, so nothing is persisted and a normal New puzzle clears it.
  const [showsChallengeCaption,setShowsChallengeCaption] = useState(false);
  const challengeFlash = useRef(new Animated.Value(0)).current;
  const challengeCaptionOpacity = useRef(new Animated.Value(0)).current;
  const challengeCaptionAnimation = useRef<Animated.CompositeAnimation|null>(null);
  const trackingRef = useRef<number>(undefined);
  const boardRef = useRef<ComponentRef<typeof View>>(null);
  const boardGesture = useRef<{point:{x:number;y:number};start:{x:number;y:number};origin?:{x:number;y:number};side:number;released:boolean}|null>(null);
  useEffect(()=>()=>{boardGesture.current=null;},[]);
  const landscape = frame.width>frame.height;
  // Portrait keeps the status bar — and so the Dynamic Island — visible; the
  // rail already reserves the top inset for it. Landscape hides the bar to give
  // the transposed board the full height (the Control Center gesture survives).
  useLayoutEffect(()=>{navigation.setOptions({statusBarHidden:landscape});},[navigation,landscape]);
  const twoPlayerActive = landscape && twoPlayer;
  // Reserve the same width for either left rail. Their artwork shares the
  // leading edge, and a cross-fade cannot resize or move the centered board.
  const chromeWidth = sudokuMetrics.keypadHeight;
  useEffect(()=>{
    if(!twoPlayerActive){twoPlayerMix.setValue(0);setShowsMenuRail(true);return;}
    const animation=Animated.timing(twoPlayerMix,{toValue:1,duration:TWO_PLAYER_CROSS_FADE_MS,useNativeDriver:true});
    let current=true;
    animation.start(({finished})=>{if(current&&finished)setShowsMenuRail(false);});
    return()=>{current=false;animation.stop();};
  },[twoPlayerActive,twoPlayerMix]);
  // Mirror the home-indicator inset and leave an extra gap at both edges.
  // Hiding the status bar does not remove the Control Center gesture.
  const topPadding = landscape ? Math.max(insets.top,insets.bottom,foundation.space.md)+foundation.space.md : insets.top+foundation.space.md;
  const bottomPadding = landscape ? topPadding : insets.bottom;
  const band = frame.height-topPadding-bottomPadding;
  const portraitBand = Math.max(0,band-foundation.control.target);
  const scrollRef=useRef<ScrollViewInstance>(null);
  const width = Math.min(frame.width-insets.left-insets.right,foundation.layout.readingWidth)-foundation.space.screenHorizontal*2;
  const portraitSide = Math.min(Math.max(Math.min(width,portraitBand-sudokuMetrics.verticalChrome),sudokuMetrics.minimumSide),width);
  // Landscape is the same composition with the axes swapped, so the board's
  // budget mirrors the portrait one: the safe area gives the height, and the
  // transposed rails and feedback gutters take space along the width. Both
  // sides reserve the keypad width, keeping the board centered in either mode.
  // The cap keeps an iPad board at a comfortable size.
  const landscapeHeight = band-sudokuMetrics.landscapePadding*2;
  const landscapeWidth = frame.width-insets.left-insets.right-2*chromeWidth-sudokuMetrics.feedbackHeight*2-sudokuMetrics.landscapePadding*2;
  const side = landscape ? Math.max(0,Math.min(landscapeHeight,landscapeWidth,sudokuMetrics.landscapeMaximumSide)) : portraitSide;
  const scrollController=useScrollInteractionController(scrollRef,!landscape&&side+sudokuMetrics.verticalChrome>portraitBand);
  const lockScroll=useScrollInteractionLock(scrollController);
  const board = useMemo(()=>workingBoard(game),[game]);
  const locked = useMemo(()=>isSolved(game),[game]);
  const canEnter = !loading && !locked && selected !== undefined && (!notesMode || board[selected] === 0);
  const canErase = !loading && !locked && selected !== undefined && game.values[selected] !== 0;
  const outcome = isComplete(game) ? locked : assist && selected !== undefined && game.values[selected] !== 0 ? game.values[selected] === game.puzzle.solution[selected] : undefined;
  // Solved-board brush reveal. Entry and erasing stay locked; selection and
  // haptics keep their existing path, and the tiles are a separate overlay that
  // only exists while `locked`. Trail length is speed × (linger + fade), so
  // there is deliberately no tile cap — the fade rate bounds it.
  const [revealTiles,setRevealTiles]=useState<readonly {index:number;opacity:Animated.Value}[]>([]);
  const revealTilesRef=useRef(new Map<number,{opacity:Animated.Value;hold?:ReturnType<typeof setTimeout>;fade?:ReturnType<typeof setTimeout>;clearSelection?:boolean}>());
  const lastRevealPoint=useRef<{x:number;y:number}|undefined>(undefined);
  // ONE image per game: derived from the puzzle's givens, not drawn per open,
  // so the same solved board always reveals the same glyph (across overlay
  // opens, resets and relaunches) and only a new puzzle changes it.
  const revealEmoji = revealEmojiFor(game.puzzle.givens);
  const cancelRevealTiles=()=>{
    // Report whether a pending accessible-activation clear was discarded, so
    // callers that can set state (background) can finish the job; unmount and
    // explicit clears handle selection themselves.
    let selectionClearPending=false;
    for(const entry of revealTilesRef.current.values()){
      if(entry.clearSelection)selectionClearPending=true;
      if(entry.hold)clearTimeout(entry.hold);
      if(entry.fade)clearTimeout(entry.fade);
    }
    revealTilesRef.current.clear();
    lastRevealPoint.current=undefined;
    return selectionClearPending;
  };
  const clearReveal=()=>{cancelRevealTiles();setRevealTiles([]);};
  const removeRevealTile=(index:number)=>{
    const entry=revealTilesRef.current.get(index);
    if(!entry)return;
    if(entry.hold)clearTimeout(entry.hold);
    if(entry.fade)clearTimeout(entry.fade);
    revealTilesRef.current.delete(index);
    setRevealTiles(current=>current.filter(tile=>tile.index!==index));
    // Accessibility activation has no gesture finish; once its tile is gone the
    // solved-board selection must not stick (matching the physical path).
    if(entry.clearSelection&&selectedRef.current===index)resetSelection();
  };
  const fadeRevealTile=(index:number,clearSelection=false)=>{
    const entry=revealTilesRef.current.get(index);
    if(!entry)return;
    if(clearSelection)entry.clearSelection=true;
    if(entry.hold)clearTimeout(entry.hold);
    if(entry.fade)clearTimeout(entry.fade);
    entry.hold=setTimeout(()=>{
      entry.hold=undefined;
      Animated.timing(entry.opacity,{toValue:0,duration:REVEAL_FADE_MS,easing:REVEAL_EASING,useNativeDriver:true}).start();
      entry.fade=setTimeout(()=>{entry.fade=undefined;removeRevealTile(index);},REVEAL_FADE_MS);
    },REVEAL_LINGER_MS);
  };
  const revealTile=(index:number)=>{
    const existing=revealTilesRef.current.get(index);
    if(existing){
      // Re-entering a tile during its hold/fade restarts it at full opacity;
      // a live gesture owns selection again, so drop any pending clear.
      if(existing.hold){clearTimeout(existing.hold);existing.hold=undefined;}
      if(existing.fade){clearTimeout(existing.fade);existing.fade=undefined;}
      existing.clearSelection=false;
      existing.opacity.setValue(1);
      return;
    }
    const opacity=new Animated.Value(1);
    revealTilesRef.current.set(index,{opacity});
    setRevealTiles(current=>[...current,{index,opacity}]);
  };
  const save = (next: SudokuGame, announceEdit = true) => {
    // The challenge replacement suppresses the generic edit cue so the long-press
    // produces the single affirmative challenge haptic, not a selection then success.
    if(announceEdit && next!==game)feedback.emit({semantic:isSolved(next)&&!isSolved(game)?'succeeded':'selected',controlID:'sudoku.edit',value:`${feedbackSession}:${++editSequence.current}`});
    setGame(next);
    setSession({...session,sudoku:session.logs['Lava Guard Progress']?next:undefined});
  };
  const clearSelection = () => {resetSelection();setTracking(undefined);trackingRef.current=undefined;resetNotesMode();setTrackedKey(undefined);trackedKeyRef.current=undefined;setTwoPlayerTrackedKey(undefined);twoPlayerTrackedKeyRef.current=undefined;clearReveal();};
  const enter = (digit:number) => {if (canEnter && selected !== undefined) save(editCell(game,selected,digit,notesMode));};
  // Selection and tracking stay available on a solved board: the completion lock
  // covers entry (`canEnter`) and erasing (`canErase`), not navigation. The board
  // must still acknowledge taps and swipes with selection haptics — the SwiftUI
  // easter egg has the same contract (PR #783), and locking selection made the
  // whole board read as dead after the final digit.
  const choose = (index:number,tracking=false) => {
    if(loading)return;
    if(locked){
      // Brush: every cell, given or not, shows its tile. A non-tracking call is
      // a tap (or accessible activation), which reveals then fades on its own;
      // its selection is cleared when the tile is removed so it never sticks.
      revealTile(index);
      if(!tracking)fadeRevealTile(index,true);
    }
    // Solved boards give every cell the same haptic as a selection — givens
    // included, because they now reveal image tiles like any other cell. Live
    // boards keep the original rule (givens stay silent).
    if(index!==selected&&(locked||!game.puzzle.givens[index]))feedback.emit({semantic:'selected',controlID:'sudoku.cell',value:String(index)});
    setSelected(game.puzzle.givens[index]?undefined:index);
  };
  // Both pads share the entry mechanism and the same feedback channel; only the
  // tracked preview is per-pad, so scrubbing one pad never paints the magnifier
  // on the other. The left pad is digits-only: erase stays P1's.
  const trackKeyInto=(trackedRef:{current:number|undefined},setTracked:(key?:number)=>void)=>(x:number,y:number)=>{
    const key = canEnter ? landscape ? keyAtColumn(x,y,sudokuMetrics.keyHeight,side) : keyAt(x,y,width) : undefined;
    if(key===trackedRef.current)return;
    if(key!==undefined)feedback.emit({semantic:'selected',controlID:'sudoku.key',value:String(key)});
    trackedRef.current=key;setTracked(key);
  };
  const trackKey = trackKeyInto(trackedKeyRef,setTrackedKey);
  const trackTwoPlayerKey = trackKeyInto(twoPlayerTrackedKeyRef,setTwoPlayerTrackedKey);
  // Keep the responder instances stable while selection/preview renders change.
  // Their actions read the latest game instead of resetting an in-flight gesture.
  const erase=()=>{if(canErase&&selected!==undefined)save(editCell(game,selected,0));};
  const actions=useRef({locked,canEnter,side,choose,enter,trackKey,trackTwoPlayerKey,erase,revealTile,fadeRevealTile,clearSelected:()=>setSelected(undefined)});
  actions.current={locked,canEnter,side,choose,enter,trackKey,trackTwoPlayerKey,erase,revealTile,fadeRevealTile,clearSelected:()=>setSelected(undefined)};
  const chooseCell=useCallback((index:number)=>actions.current.choose(index),[]);
  const enterDigit=useCallback((digit:number)=>actions.current.enter(digit),[]);
  const eraseCell=useCallback(()=>actions.current.erase(),[]);
  useEffect(()=>{
    // Leaving the solved state (Reset, New puzzle, a persisted board replaced)
    // must not leave tiles or timers behind.
    if(!locked&&revealTilesRef.current.size>0)clearReveal();
  },[locked]);
  useEffect(()=>{
    const subscription=AppState.addEventListener?.('change',state=>{
      if(state!=='background')return;
      // Backgrounding during an accessible activation's linger must still clear
      // its solved-board selection, or the next activation stays silent.
      if(cancelRevealTiles())resetSelection();
      setRevealTiles([]);
    });
    return ()=>{subscription?.remove?.();cancelRevealTiles();};
  },[]);
  const boardPan = useMemo(()=>{
    const track=(gesture:NonNullable<typeof boardGesture.current>)=>{
      if(!gesture.origin)return;
      const local={x:gesture.point.x-gesture.origin.x,y:gesture.point.y-gesture.origin.y};
      // Until the first tracked point, interpolate from the grant coordinate:
      // moves and even the release can land while `measure` is in flight, and
      // the opening segment must not be skipped.
      const previous=lastRevealPoint.current??{x:gesture.start.x-gesture.origin.x,y:gesture.start.y-gesture.origin.y};
      lastRevealPoint.current=local;
      const index=cellAt(local.x,local.y,actions.current.side);
      if(actions.current.locked){
        // Move events skip cells on a fast swipe; sample the segment so the
        // trail stays continuous, fading every cell the endpoint is not on.
        for(const crossed of cellsBetween(previous,local,actions.current.side)){
          if(crossed===index)continue;
          actions.current.revealTile(crossed);actions.current.fadeRevealTile(crossed);
        }
      }
      if(index===undefined){
        // Left the board: drop the tracked cell so re-entering through the same
        // edge cell revives its tile instead of being skipped.
        if(actions.current.locked&&trackingRef.current!==undefined){
          actions.current.fadeRevealTile(trackingRef.current);
          trackingRef.current=undefined;setTracking(undefined);
        }
        return;
      }
      if(trackingRef.current!==index){
        if(actions.current.locked&&trackingRef.current!==undefined)actions.current.fadeRevealTile(trackingRef.current);
        trackingRef.current=index;setTracking(index);actions.current.choose(index,true);
      }
    };
    const finish=()=>{
      // A solved board does not keep the selector: lift-off clears selection,
      // and the last tile lingers through its own fade.
      if(actions.current.locked){
        if(trackingRef.current!==undefined)actions.current.fadeRevealTile(trackingRef.current);
        actions.current.clearSelected();
      }
      boardGesture.current=null;trackingRef.current=undefined;setTracking(undefined);lastRevealPoint.current=undefined;lockScroll(false);
    };
    const move=(event:{nativeEvent:{pageX:number;pageY:number}})=>{
      const gesture=boardGesture.current;
      if(!gesture)return;
      if(gesture.released)return;
      if(actions.current.side!==gesture.side){finish();return;}
      gesture.point={x:event.nativeEvent.pageX,y:event.nativeEvent.pageY};
      track(gesture);
    };
    return PanResponder.create({
    // Claim board movement before the cell Pressables keep a scrub pinned to
    // its first cell. Ordinary taps and accessible activation still reach each
    // cell on a live board, preserving native rejection feedback only for taps
    // on given cells. A solved board claims the touch START too: every touch is
    // a brush stroke (no editing is possible), so taps and swipes take the same
    // path and the selector never sticks.
    onStartShouldSetPanResponderCapture:()=>actions.current.locked,
    onMoveShouldSetPanResponderCapture: (_,gesture) => Math.hypot(gesture.dx,gesture.dy)>=6,
    onPanResponderGrant:event=>{
      lockScroll(true);
      const gesture={point:{x:event.nativeEvent.pageX,y:event.nativeEvent.pageY},start:{x:event.nativeEvent.pageX,y:event.nativeEvent.pageY},side:actions.current.side,released:false} as NonNullable<typeof boardGesture.current>;
      boardGesture.current=gesture;
      // `pageX/pageY` and `measure` share the React root's coordinate space.
      // Measure per gesture so native presentation and scroll offsets cannot
      // leave a cached board origin behind.
      const board=boardRef.current;
      if(!board){finish();return;}
      board.measure((_,__,measuredWidth,measuredHeight,pageX,pageY)=>{
        if(boardGesture.current!==gesture)return;
        if(actions.current.side!==gesture.side||measuredWidth<=0||measuredHeight<=0||!Number.isFinite(pageX)||!Number.isFinite(pageY)){
          finish();return;
        }
        gesture.origin={x:pageX,y:pageY};track(gesture);
        if(gesture.released)finish();
      });
    },
    onPanResponderMove:move,
    onPanResponderRelease:event=>{
      const gesture=boardGesture.current;
      move(event);
      if(!gesture||boardGesture.current!==gesture)return;
      if(gesture.origin)finish();
      else {gesture.released=true;lockScroll(false);}
    },
    onPanResponderTerminate:finish,
  });},[]);
  // One responder per pad, each owning its pad's preview ref. Both route through
  // `actions` so selection/preview renders never reset an in-flight gesture.
  const trackPadKey=(twoPlayerPad:boolean,x:number,y:number)=>{
    if(twoPlayerPad)actions.current.trackTwoPlayerKey(x,y);else actions.current.trackKey(x,y);
  };
  const makeKeypadPan=(twoPlayerPad:boolean,trackedRef:{current:number|undefined},setTracked:(key?:number)=>void)=>PanResponder.create({
    onStartShouldSetPanResponder: () => actions.current.canEnter,
    onPanResponderGrant: event => {lockScroll(true);trackPadKey(twoPlayerPad,event.nativeEvent.locationX,event.nativeEvent.locationY);},
    onPanResponderMove: event => trackPadKey(twoPlayerPad,event.nativeEvent.locationX,event.nativeEvent.locationY),
    onPanResponderRelease: event => {
      // A release beyond either axis cancels. Read the final coordinate, not a
      // possibly stale render, so scrubbing commits exactly the last key once.
      trackPadKey(twoPlayerPad,event.nativeEvent.locationX,event.nativeEvent.locationY);
      const key=trackedRef.current;
      trackedRef.current=undefined;setTracked(undefined);
      if (key !== undefined) actions.current.enter(key);
      lockScroll(false);
    },
    onPanResponderTerminate: () => {trackedRef.current=undefined;setTracked(undefined);lockScroll(false);},
    onPanResponderTerminationRequest:()=>false,
  });
  const keypadPan = useMemo(()=>makeKeypadPan(false,trackedKeyRef,setTrackedKey),[]);
  const twoPlayerKeypadPan = useMemo(()=>makeKeypadPan(true,twoPlayerTrackedKeyRef,setTwoPlayerTrackedKey),[]);
  // Activating two-player replaces the rail with the left keypad and flashes the
  // one quiet instruction the mode needs: leaving landscape is the only exit.
  // No in-mode menu is added — with the rail gone, rotating back to portrait is
  // both the way to the menu and the reset to a 1P next landscape entry.
  const startTwoPlayer = () => {
    if(twoPlayer||!isCurrentAction())return;
    // The two transient captions share one absolute slot; they are mutually exclusive.
    challengeCaptionAnimation.current?.stop();
    setShowsChallengeCaption(false);
    setTwoPlayer(true);
    // The transient caption is decorative and fades before VoiceOver can reach
    // it, so announce its localized exit instruction when the mode starts.
    AccessibilityInfo.announceForAccessibility(localized('2P mode until landscape mode ends'));
    setTwoPlayerTrackedKey(undefined);twoPlayerTrackedKeyRef.current=undefined;
    twoPlayerCaptionAnimation.current?.stop();
    twoPlayerCaptionOpacity.setValue(0);
    setShowsTwoPlayerCaption(true);
    twoPlayerCaptionAnimation.current=Animated.sequence([
      Animated.timing(twoPlayerCaptionOpacity,{toValue:1,duration:160,useNativeDriver:true}),
      Animated.delay(TWO_PLAYER_CAPTION_HOLD_MS),
      Animated.timing(twoPlayerCaptionOpacity,{toValue:0,duration:240,useNativeDriver:true}),
    ]);
    twoPlayerCaptionAnimation.current.start(({finished})=>{if(finished)setShowsTwoPlayerCaption(false);});
  };
  useEffect(()=>()=>twoPlayerCaptionAnimation.current?.stop(),[]);
  useEffect(()=>()=>challengeCaptionAnimation.current?.stop(),[]);
  useEffect(()=>{
    if(landscape)return;
    // Leaving landscape is the mode's only exit: clear it (with its caption and
    // left-pad preview) so the next landscape entry starts single-player.
    twoPlayerCaptionAnimation.current?.stop();
    setShowsTwoPlayerCaption(false);
    resetTwoPlayer();
    setTwoPlayerTrackedKey(undefined);twoPlayerTrackedKeyRef.current=undefined;
  },[landscape]);
  const clearChallengeCaption = () => {
    challengeCaptionAnimation.current?.stop();
    setShowsChallengeCaption(false);
  };
  // Success feedback for a board that actually landed: the affirmative haptic, the
  // orange flash, and the below-board caption. Fire it only from the success path,
  // never at the gesture, or a rejected generation would read as an applied challenge.
  const challengeApplied = () => {
    // The two transient captions share one absolute slot; they are mutually exclusive.
    twoPlayerCaptionAnimation.current?.stop();
    setShowsTwoPlayerCaption(false);
    feedback.emit({semantic:'succeeded',controlID:'sudoku.challenge'});
    challengeFlash.setValue(1);
    Animated.timing(challengeFlash,{toValue:0,duration:CHALLENGE_FLASH_MS,useNativeDriver:true}).start();
    challengeCaptionAnimation.current?.stop();
    challengeCaptionOpacity.setValue(0);
    setShowsChallengeCaption(true);
    challengeCaptionAnimation.current=Animated.sequence([
      Animated.timing(challengeCaptionOpacity,{toValue:1,duration:160,useNativeDriver:true}),
      Animated.delay(CHALLENGE_CAPTION_HOLD_MS),
      Animated.timing(challengeCaptionOpacity,{toValue:0,duration:TWO_PLAYER_CROSS_FADE_MS,useNativeDriver:true}),
    ]);
    challengeCaptionAnimation.current.start(({finished})=>{if(finished)setShowsChallengeCaption(false);});
    // The caption fades before VoiceOver can reach it, so announce it once.
    AccessibilityInfo.announceForAccessibility(localized('Challenge mode applied to this board'));
  };
  // The hidden challenge gesture: a three-second hold on New puzzle. It generates a
  // fresh board below 30 clues (the challenge contract) and only then presents the
  // success signals, so a failed/refused generation shows the ordinary error instead.
  const startChallenge = () => {
    if(loading||!isCurrentAction())return;
    if(app){
      const accepted=generationAcceptance();setLoading(true);
      void app.command<SudokuGame>({type:'sudoku.new',challenge:true})
        .then(next=>{if(accepted()){save(next,false);clearSelection();challengeApplied();}})
        .catch(error=>Alert.alert('Lava',error.message))
        .finally(()=>setLoading(false));
    }else{
      save(newGame(freshChallengePuzzle(game.puzzle)),false);
      clearSelection();
      challengeApplied();
    }
  };
  const confirmReset = () => {if(!isCurrentAction())return;Alert.alert('Reset puzzle?','Your entries and notes will be removed. The puzzle will stay the same.',[
    {text:'Cancel',style:'cancel'}, {text:'Reset',style:'destructive',onPress:()=>{if(!isCurrentAction())return;save(newGame(game.puzzle));clearSelection();}},
  ]);};
  const confirmNew = () => {if(!isCurrentAction())return;Alert.alert('New puzzle','Your entries and notes will be removed and a new puzzle will begin.',[
    {text:'Cancel',style:'cancel'}, {text:'New puzzle',style:'destructive',onPress:()=>{if(!isCurrentAction())return;clearChallengeCaption();if(app){const accepted=generationAcceptance();setLoading(true);void app.command<SudokuGame>({type:'sudoku.new'}).then(next=>{if(accepted()){save(next);clearSelection();}}).catch(error=>Alert.alert('Lava',error.message)).finally(()=>setLoading(false));}else{save(newGame(freshPuzzle(game.puzzle)));clearSelection();}}},
  ]);};
  // One action list feeds the same rail in both orientations.
  const tools:SudokuTool[]=[
    {id:'sudoku-notes-toggle',label:`Notes mode ${notesMode?'on':'off'}`,icon:'notes',selected:notesMode,disabled:loading,
      onPress:()=>{if(!isCurrentAction())return;setNotesMode(!notesMode);feedback.emit({semantic:'selected',controlID:'sudoku.notes',value:String(!notesMode)});}},
    {id:'sudoku-correctness-toggle',label:`Puzzle assistance ${assist?'on':'off'}`,icon:assist?'assist':'hide',selected:assist,disabled:loading,
      onPress:()=>{if(!isCurrentAction())return;setAssist(!assist);feedback.emit({semantic:'selected',controlID:'sudoku.assist',value:String(!assist)});}},
    // Reset is a fresh restart of the same puzzle, not an undo: the glyph is the
    // counter-clockwise arrow the SwiftUI easter egg adopted in PR #783, not the
    // undo glyph the RN port inherited.
    {id:'sudoku-reset',label:'Reset',icon:'reset',disabled:loading,onPress:confirmReset},
    // Completion fills the next-game action with the same green treatment as a
    // selected mode (the eyes-on fill), but as a visual-only prominence: the
    // action is one-shot, so it must not publish selection semantics to
    // VoiceOver. A solved board has no next digit, making it the next step.
    {id:'sudoku-refresh',label:'New puzzle',icon:'add',prominent:locked,disabled:loading,onPress:confirmNew,onLongPress:startChallenge,longPressDelayMs:CHALLENGE_LONG_PRESS_MS},
  ];
  return <View testID="sudoku-screen" onLayout={onLayout} style={[styles.root,{paddingTop:topPadding,paddingBottom:bottomPadding,paddingLeft:insets.left,paddingRight:insets.right}]}>
    {landscape ? <View style={styles.landscapeRow}>
      <View testID="sudoku-left-chrome" style={styles.landscapeLeftChrome}>
        {showsMenuRail&&<Animated.View testID="sudoku-menu-rail-layer" pointerEvents={twoPlayerActive?'none':'auto'}
          accessibilityElementsHidden={twoPlayerActive} importantForAccessibility={twoPlayerActive?'no-hide-descendants':'auto'}
          style={[styles.landscapeRailLayer,{opacity:twoPlayerMix.interpolate({inputRange:[0,1],outputRange:[1,0]})}]}>
          <SudokuRail tools={tools} onClose={()=>navigation.goBack()} landscape availableHeight={band} onStartTwoPlayer={startTwoPlayer} flash={{id:'sudoku-refresh',opacity:challengeFlash}}/>
        </Animated.View>}
        {twoPlayerActive&&<Animated.View testID="sudoku-p2-rail-layer" style={[styles.landscapeKeypadLayer,{opacity:twoPlayerMix}]}>
          <SudokuKeypad layout="column" edge="leading" testIDPrefix="sudoku-p2" showsEraser={false} game={game} width={width} height={side} selected={selected} notesMode={notesMode} assist={assist} trackedKey={twoPlayerTrackedKey}
            canEnter={canEnter} canErase={canErase} onEnter={enterDigit} onErase={eraseCell} panHandlers={twoPlayerKeypadPan.panHandlers}/>
        </Animated.View>}
      </View>
      <View testID="sudoku-landscape-center" style={styles.landscapeCenter}>
        <View style={styles.landscapeBoardRow}>
          <View testID="sudoku-outcome-gutter" style={[styles.landscapeGutter,styles.landscapeOutcomeGutter]}>
            <SudokuFeedback loading={false} outcome={outcome} onRetry={()=>setGeneration(generation+1)} column/>
          </View>
          <SudokuBoard game={game} side={side} selected={selected} tracking={tracking} notesMode={notesMode} assist={assist}
            loading={loading} ready={ready} boardRef={boardRef} onChoose={chooseCell} panHandlers={boardPan.panHandlers}
            revealEmoji={revealEmoji} revealTiles={revealTiles}/>
          <View testID="sudoku-balance-gutter" style={styles.landscapeGutter}/>
          {showsTwoPlayerCaption&&<Animated.View pointerEvents="none" accessibilityElementsHidden style={[styles.twoPlayerCaption,{top:side+foundation.space.xs,opacity:twoPlayerCaptionOpacity}]}>
            <Text allowFontScaling={false} style={styles.twoPlayerCaptionText}>{localized('2P mode until landscape mode ends')}</Text>
          </Animated.View>}
          {showsChallengeCaption&&<Animated.View pointerEvents="none" accessibilityElementsHidden style={[styles.twoPlayerCaption,{top:side+foundation.space.xs,opacity:challengeCaptionOpacity}]}>
            <Text allowFontScaling={false} style={styles.twoPlayerCaptionText}>{localized('Challenge mode applied to this board')}</Text>
          </Animated.View>}
        </View>
        {loading&&<View style={styles.landscapeOverlay}>
          <SudokuFeedback loading error={generationError} onRetry={()=>setGeneration(generation+1)} testID="sudoku-loading"/>
        </View>}
      </View>
      <SudokuKeypad layout="column" game={game} width={width} height={side} selected={selected} notesMode={notesMode} assist={assist} trackedKey={trackedKey}
        canEnter={canEnter} canErase={canErase} onEnter={enterDigit} onErase={eraseCell} panHandlers={keypadPan.panHandlers}/>
    </View>
    : <>
      <SudokuRail tools={tools} onClose={()=>navigation.goBack()} flash={{id:'sudoku-refresh',opacity:challengeFlash}}/>
      <ScrollView ref={scrollRef} bounces={side+sudokuMetrics.verticalChrome>portraitBand} scrollEnabled={side+sudokuMetrics.verticalChrome>portraitBand}
        contentInsetAdjustmentBehavior="never" automaticallyAdjustKeyboardInsets={false}
        contentContainerStyle={[styles.content,{minHeight:portraitBand}]}>
        <SudokuFeedback loading={loading} error={generationError} outcome={outcome} onRetry={()=>setGeneration(generation+1)}/>
        {/* Portrait mirrors the landscape caption slot: the challenge caption hangs
            below the board, outside its layout, so the board never moves. */}
        <View style={{width:side,alignSelf:'center'}}>
          <SudokuBoard game={game} side={side} selected={selected} tracking={tracking} notesMode={notesMode} assist={assist}
            loading={loading} ready={ready} boardRef={boardRef} onChoose={chooseCell} panHandlers={boardPan.panHandlers}
            revealEmoji={revealEmoji} revealTiles={revealTiles}/>
          {showsChallengeCaption&&<Animated.View pointerEvents="none" accessibilityElementsHidden style={[styles.twoPlayerCaption,{top:side+foundation.space.xs,opacity:challengeCaptionOpacity}]}>
            <Text allowFontScaling={false} style={styles.twoPlayerCaptionText}>{localized('Challenge mode applied to this board')}</Text>
          </Animated.View>}
        </View>
        <View style={styles.flexible}/>
        <SudokuKeypad game={game} width={width} selected={selected} notesMode={notesMode} assist={assist} trackedKey={trackedKey}
          canEnter={canEnter} canErase={canErase} onEnter={enterDigit} onErase={eraseCell} panHandlers={keypadPan.panHandlers}/>
      </ScrollView>
    </>}
  </View>;
}
