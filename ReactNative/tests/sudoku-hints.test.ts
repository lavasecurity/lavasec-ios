import {editCell,hintCellIndices,newGame,type SudokuPuzzle} from '../review/sudoku-model';

const solution='123456789456789123789123456234567891567891234891234567345678912678912345912345678'.split('').map(Number);
const puzzle=(indices:readonly number[]):SudokuPuzzle=>({solution,givens:solution.map((value,index)=>indices.includes(index)?value:0)});
const except=(indices:readonly number[])=>solution.map((_,index)=>index).filter(index=>!indices.includes(index));

test('naked singles combine row, column and box constraints',()=>{
  expect(hintCellIndices(newGame(puzzle([1,2,9,18,19,20,36,63]))).has(0)).toBe(true);
});
test.each([
  ['row',[2,3,4,5,6,7,8,73],[0,1]],
  ['column',[18,27,36,45,54,63,72,15],[0,9]],
  ['box',[2,9,10,11,18,19,20,73],[0,1]],
] as const)('hidden singles in a %s mark cells with multiple candidates',(_unit,givens,targets)=>{
  expect(hintCellIndices(newGame(puzzle(givens)))).toEqual(new Set(targets));
});
test('a stored solution cannot manufacture a single or make pencil marks authoritative',()=>{
  const game=newGame(puzzle(solution.map((value,index)=>value>2?index:-1)));
  expect(hintCellIndices(game).size).toBe(0);
  expect(hintCellIndices(editCell(newGame(puzzle([])),0,1,true)).size).toBe(0);
  let forced=newGame(puzzle(except([0,1])));
  const original=hintCellIndices(forced);
  for(let digit=1;digit<=9;digit++)forced=editCell(forced,0,digit,true);
  expect(hintCellIndices(forced)).toEqual(original);
});
test('hints recompute after entry and erasure without mutating progress or returning answers',()=>{
  const game=newGame(puzzle(except([0,1]))),before=JSON.stringify(game);
  expect(hintCellIndices(game)).toEqual(new Set([0,1]));
  expect(JSON.stringify(game)).toBe(before);
  const placed=editCell(game,0,solution[0]!);
  expect(hintCellIndices(placed)).toEqual(new Set([1]));
  expect(hintCellIndices(editCell(placed,0,0))).toEqual(new Set([0,1]));
  expect(hintCellIndices(editCell(placed,1,solution[1]!)).size).toBe(0);
});
test('a wrong entry suppresses hints even when it creates no duplicate in its units',()=>{
  const game=newGame(puzzle(except([0,1,27,80])));
  expect(hintCellIndices(game).size).toBeGreaterThan(0);
  const wrong=editCell(game,0,2);
  expect(hintCellIndices(wrong).size).toBe(0);
  expect(hintCellIndices(editCell(wrong,0,0))).toEqual(hintCellIndices(game));
  expect(hintCellIndices(editCell(wrong,0,1)).size).toBeGreaterThan(0);
});
