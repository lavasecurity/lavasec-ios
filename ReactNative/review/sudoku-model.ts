// Reference exported from SudokuPuzzle.generate(seed: 648), the production
// -lava-sudoku-ui-test fixture. The review keeps all progress in its React session.
export type SudokuPuzzle = {readonly givens: readonly number[]; readonly solution: readonly number[]};
export type SudokuGame = {readonly puzzle: SudokuPuzzle; readonly values: readonly number[]; readonly notes: readonly (readonly number[])[]};
export const referencePuzzle: SudokuPuzzle = {
  givens: '032000601090602030000500000360800000910200080070000096020090070100020900450703800'.split('').map(Number),
  solution: '532987641791642538846531729364819257915276384278354196623198475187425963459763812'.split('').map(Number),
};
export function newGame(puzzle: SudokuPuzzle = referencePuzzle): SudokuGame {
  return {puzzle, values: Array<number>(81).fill(0), notes: Array.from({length:81}, () => [])};
}
export const workingBoard = (game: SudokuGame) => game.puzzle.givens.map((given,index) => given || game.values[index]!);
export const isSolved = (game: SudokuGame) => workingBoard(game).every((value,index) => value === game.puzzle.solution[index]);
export const isComplete = (game: SudokuGame) => workingBoard(game).every(value => value !== 0);
export const remainingCount = (game: SudokuGame, digit: number) => Number.isInteger(digit)&&digit>=1&&digit<=9 ? Math.max(0,9-workingBoard(game).filter(value => value === digit).length) : 0;
export function editCell(game: SudokuGame, index: number, digit: number, notesMode = false): SudokuGame {
  if (!Number.isInteger(index) || index < 0 || index >= 81 || game.puzzle.givens[index] || isSolved(game)
      || !Number.isInteger(digit) || digit < 0 || digit > 9) return game;
  if (notesMode && digit !== 0 && game.values[index] !== 0) return game;
  const values = [...game.values];
  const notes = [...game.notes];
  if (notesMode && digit !== 0) {
    notes[index] = notes[index]!.includes(digit) ? notes[index]!.filter(value => value !== digit) : [...notes[index]!,digit].sort();
  } else {
    values[index] = digit;
    notes[index] = [];
  }
  return {puzzle: game.puzzle, values, notes};
}

// New rounds in this UI-only host permute a proven unique native puzzle. Digit
// renaming and row/column permutations within bands/stacks preserve uniqueness;
// the production generator and disk persistence remain behind the service boundary.
export function freshPuzzle(previous: SudokuPuzzle, random = Math.random): SudokuPuzzle {
  const shuffled = (values: number[]) => {
    for (let i=values.length-1;i>0;i--) {
      const j = Math.floor(random()*(i+1));
      [values[i],values[j]] = [values[j]!,values[i]!];
    }
    return values;
  };
  const order = () => shuffled([0,1,2]).flatMap(band => shuffled([0,1,2]).map(row => band*3+row));
  const rows = order(), columns = order(), digits = shuffled([1,2,3,4,5,6,7,8,9]);
  const remap = (board: readonly number[]) => rows.flatMap(row => columns.map(column => {
    const digit = board[row*9+column]!;
    return digit === 0 ? 0 : digits[digit-1]!;
  }));
  let givens = remap(previous.givens), solution = remap(previous.solution);
  if (givens.every((value,index) => value === previous.givens[index])) {
    const rotate = (digit: number) => digit === 0 ? 0 : digit%9+1;
    givens = givens.map(rotate); solution = solution.map(rotate);
  }
  return {givens,solution};
}

// Hidden challenge boards (native challenge target: 28 clues, always < 30) for the
// UI-only host, which has no generator. Provenance is the native engine at seeds
// 1, 7 and 42 with `challenge: true`; the connected app instead asks
// `sudoku.new {challenge:true}` so production draws a fresh board.
export const challengePuzzles: readonly SudokuPuzzle[] = [
  {givens: '050002960321004000900850300030000008600000003400080010080005400000420000005109700'.split('').map(Number),
   solution: '854372961321694875976851324537916248618247593492583617189765432763428159245139786'.split('').map(Number)},
  {givens: '350914067000000000920000003030800094080040000000352800700001000000400020100000748'.split('').map(Number),
   solution: '358914267617523489924768153231876594586149372479352816742681935895437621163295748'.split('').map(Number)},
  {givens: '000405000000017800037600012642000000019000405705004200100090000000000690098700000'.split('').map(Number),
   solution: '821435976956217843437689512642953187319872465785164239163598724574321698298746351'.split('').map(Number)},
];
export function freshChallengePuzzle(previous?: SudokuPuzzle, random = Math.random): SudokuPuzzle {
  // Exclude the current board (when it is one of the bundled ones) so a repeat hold
  // never promises a fresh challenge while redisplaying the identical puzzle.
  const candidates = previous
    ? challengePuzzles.filter(puzzle => puzzle.givens.join('') !== previous.givens.join(''))
    : challengePuzzles;
  const pool = candidates.length ? candidates : challengePuzzles;
  return pool[Math.min(pool.length-1,Math.floor(random()*pool.length))]!;
}

export function cellAt(x: number, y: number, side: number): number | undefined {
  if (side <= 0 || x < 0 || y < 0 || x >= side || y >= side) return;
  return Math.floor(y/(side/9))*9 + Math.floor(x/(side/9));
}
// One geometry contract owns the connected digit segments and eraser's 4–6 span.
export function keypadGeometry(width:number) {
  const gap=0,keyWidth=width/9;
  return {gap,keyWidth,keyCenter:(digit:number)=>(digit-0.5)*keyWidth,
    eraserLeft:3*keyWidth,eraserWidth:3*keyWidth};
}
export const keypadShortSide=78; // 1.5 × the original 52pt digit group depth.
export function keyAt(x: number, y: number, width: number, height = keypadShortSide): number | undefined {
  if (width <= 48 || height <= 0 || x < 0 || x >= width || y < 0 || y >= height) return;
  return Math.min(8,Math.floor(x/keypadGeometry(width).keyWidth))+1;
}
// Landscape transposes the keypad row into the right column: the same contract
// with the axes swapped, so the eraser keeps its exact span beside digits 4–6.
export function keypadColumnGeometry(height:number) {
  const gap=0,keyHeight=height/9;
  return {gap,keyHeight,keyCenter:(digit:number)=>(digit-0.5)*keyHeight,
    eraserTop:3*keyHeight,eraserHeight:3*keyHeight};
}
export function keyAtColumn(x: number, y: number, width: number, height: number): number | undefined {
  return keyAt(y,x,height,width);
}
type LabelFormatter = (format:string,...values:(string|number)[])=>string;
const defaultLabelFormat:LabelFormatter=(format,...values)=>{let index=0;return format.replace(/%lld|%@/g,()=>String(values[index++]));};
export function cellLabel(game: SudokuGame, index: number, notesMode: boolean, assist: boolean, format:LabelFormatter=defaultLabelFormat): string {
  const row=Math.floor(index/9)+1,col=index%9+1;
  const value = game.puzzle.givens[index] || game.values[index];
  if (game.puzzle.givens[index]) return format('Row %lld, column %lld: %lld, given',row,col,value!);
  if (value) {
    const label=format('Row %lld, column %lld: %lld',row,col,value);
    return assist ? [label,format(value===game.puzzle.solution[index]?'Correctly placed':'Misplaced')].join(', ') : label;
  }
  const notes = notesMode ? game.notes[index]! : [];
  return notes.length?format('Row %lld, column %lld: notes %@',row,col,[...notes].sort((a,b)=>a-b).join(' ')):format('Row %lld, column %lld: empty',row,col);
}

// A full board always owns the result, even when assistance is off or the
// selected entry is correct on an otherwise incorrect completed board.
export function correctnessResult(game: SudokuGame, assist: boolean, selected?: number): {correct: boolean; label: string} | undefined {
  if (isComplete(game)) {
    const correct = isSolved(game);
    return {correct, label: correct ? 'Puzzle solved' : 'Puzzle has errors'};
  }
  if (!assist || selected === undefined || !game.values[selected] || game.puzzle.givens[selected]) return;
  const correct = game.values[selected] === game.puzzle.solution[selected];
  return {correct, label: correct ? 'Correctly placed' : 'Misplaced'};
}
