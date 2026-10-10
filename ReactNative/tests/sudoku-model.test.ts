import {cellAt, cellLabel, challengePuzzles, editCell, freshChallengePuzzle, freshPuzzle, isComplete, isSolved, keyAt, keyAtColumn, keypadColumnGeometry, keypadGeometry, keypadShortSide, newGame, referencePuzzle, remainingCount, workingBoard} from '../review/sudoku-model';

test('locked clues and invalid input cannot mutate the board',()=>{
  const game=newGame();
  for(const [index,digit] of [[1,5],[-1,5],[81,5],[0,10],[0,1.5]]) expect(editCell(game,index!,digit!)).toBe(game);
  expect(workingBoard(game)).toEqual(referencePuzzle.givens);
});
test('notes toggle only in empty cells, stay sorted, and disappear when replaced or erased',()=>{
  let game=editCell(editCell(newGame(),0,3,true),0,1,true);
  expect(cellLabel(game,0,true,false)).toBe('Row 1, column 1: notes 1 3');
  expect(cellLabel(game,0,false,false)).toBe('Row 1, column 1: empty');
  game=editCell(game,0,3,true);
  expect(game.notes[0]).toEqual([1]);
  game=editCell(game,0,5);
  expect(game.notes[0]).toEqual([]);
  expect(editCell(game,0,1,true)).toBe(game);
  expect(editCell(game,0,0).values[0]).toBe(0);
});
test('a full incorrect board remains editable; a solved board is locked',()=>{
  let game=newGame();
  referencePuzzle.solution.forEach((digit,index)=>{game=editCell(game,index,index===0?1:digit);});
  expect(isComplete(game)).toBe(true);expect(isSolved(game)).toBe(false);
  expect(cellLabel(game,0,false,true)).toContain('Misplaced');
  expect(cellLabel(game,0,false,false)).not.toContain('Misplaced');
  game=editCell(game,0,5);
  expect(isSolved(game)).toBe(true);
  expect(editCell(game,0,0)).toBe(game);
  for(let digit=1;digit<=9;digit++)expect(remainingCount(game,digit)).toBe(0);
});
test('new review puzzles preserve legal rows, columns, boxes, clue count and clue agreement',()=>{
  let puzzle=referencePuzzle;
  const expected=[1,2,3,4,5,6,7,8,9];
  for(let round=0;round<30;round++){
    const next=freshPuzzle(puzzle);
    expect(next.givens).not.toEqual(puzzle.givens);
    expect(next.givens.filter(Boolean)).toHaveLength(referencePuzzle.givens.filter(Boolean).length);
    expect(next.givens.every((value,index)=>!value||value===next.solution[index])).toBe(true);
    for(let unit=0;unit<9;unit++){
      expect(next.solution.slice(unit*9,unit*9+9).sort()).toEqual(expected);
      expect(Array.from({length:9},(_,row)=>next.solution[row*9+unit]).sort()).toEqual(expected);
      expect(Array.from({length:9},(_,offset)=>next.solution[(Math.floor(unit/3)*3+Math.floor(offset/3))*9+(unit%3)*3+offset%3]).sort()).toEqual(expected);
    }
    puzzle=next;
  }
});
test('bundled challenge puzzles are legal and under thirty clues',()=>{
  expect(challengePuzzles.length).toBeGreaterThan(0);
  const expected=[1,2,3,4,5,6,7,8,9];
  for(const puzzle of challengePuzzles){
    expect(puzzle.givens).toHaveLength(81);
    expect(puzzle.solution).toHaveLength(81);
    expect(puzzle.givens.filter(Boolean).length).toBeLessThan(30);
    expect(puzzle.givens.every((value,index)=>!value||value===puzzle.solution[index])).toBe(true);
    for(let unit=0;unit<9;unit++){
      expect(puzzle.solution.slice(unit*9,unit*9+9).sort()).toEqual(expected);
      expect(Array.from({length:9},(_,row)=>puzzle.solution[row*9+unit]).sort()).toEqual(expected);
      expect(Array.from({length:9},(_,offset)=>puzzle.solution[(Math.floor(unit/3)*3+Math.floor(offset/3))*9+(unit%3)*3+offset%3]).sort()).toEqual(expected);
    }
  }
  expect(challengePuzzles).toContain(freshChallengePuzzle(undefined,()=>0));
  expect(challengePuzzles).toContain(freshChallengePuzzle(undefined,()=>0.999999));
  // A repeat hold never redraws the board it is replacing.
  expect(freshChallengePuzzle(challengePuzzles[0],()=>0)).not.toBe(challengePuzzles[0]);
});
test('board and connected keypad tracking use actual bounds and cross segment boundaries',()=>{
  expect(cellAt(0,0,360)).toBe(0);expect(cellAt(359,359,360)).toBe(80);
  expect(cellAt(360,0,360)).toBeUndefined();expect(cellAt(-1,0,360)).toBeUndefined();
  expect(keyAt(-1,26,360)).toBeUndefined();expect(keyAt(360,26,360)).toBeUndefined();
  expect(keypadShortSide).toBe(52*1.5);
  expect(keyAt(20,-1,360)).toBeUndefined();expect(keyAt(20,keypadShortSide,360)).toBeUndefined();
  expect(keyAt(20,0,360)).toBe(1);expect(keyAt(20,keypadShortSide-0.01,360)).toBe(1);
  expect(keyAt(359,26,360)).toBe(9);
  const midpoint=360/9;
  expect(keyAt(midpoint-0.01,26,360)).toBe(1);expect(keyAt(midpoint+0.01,26,360)).toBe(2);
});


test.each([297,357,640])('eraser spans exactly digit 4 through 6 at width %i, away from the digit touch band',width=>{
  const geometry=keypadGeometry(width);
  expect(geometry.eraserLeft).toBeCloseTo(geometry.keyCenter(4)-geometry.keyWidth/2);
  expect(geometry.eraserLeft+geometry.eraserWidth).toBeCloseTo(geometry.keyCenter(6)+geometry.keyWidth/2);
  expect(geometry.eraserLeft+geometry.eraserWidth/2).toBeCloseTo(geometry.keyCenter(5));
  expect(geometry.eraserWidth).toBeCloseTo(3*geometry.keyWidth);
  for(let digit=1;digit<=9;digit++)expect(keyAt(geometry.keyCenter(digit),26,width)).toBe(digit);
});
test('landscape transposes the keypad into a column with the same two-axis hit bounds',()=>{
  const width=keypadShortSide,height=320,geometry=keypadColumnGeometry(height);
  expect(geometry.keyHeight).toBeCloseTo(height/9);
  for(let digit=1;digit<=9;digit++)expect(keyAtColumn(26,geometry.keyCenter(digit),width,height)).toBe(digit);
  expect(keyAtColumn(-1,geometry.keyCenter(1),width,height)).toBeUndefined();
  expect(keyAtColumn(width,geometry.keyCenter(1),width,height)).toBeUndefined();
  expect(keyAtColumn(0,geometry.keyCenter(1),width,height)).toBe(1);
  expect(keyAtColumn(width-0.01,geometry.keyCenter(1),width,height)).toBe(1);
  expect(keyAtColumn(26,-1,width,height)).toBeUndefined();
  expect(keyAtColumn(26,height,width,height)).toBeUndefined();
  expect(keyAtColumn(26,geometry.keyCenter(1),width,48)).toBeUndefined();
  const boundary=geometry.keyHeight+geometry.gap/2;
  expect(keyAtColumn(26,boundary-0.01,width,height)).toBe(1);
  expect(keyAtColumn(26,boundary+0.01,width,height)).toBe(2);
  expect(geometry.eraserTop).toBeCloseTo(geometry.keyCenter(4)-geometry.keyHeight/2);
  expect(geometry.eraserTop+geometry.eraserHeight).toBeCloseTo(geometry.keyCenter(6)+geometry.keyHeight/2);
});
