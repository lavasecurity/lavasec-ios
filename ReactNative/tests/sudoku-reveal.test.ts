import {
  REVEAL_EASING,
  REVEAL_EMOJI,
  REVEAL_FADE_MS,
  REVEAL_LINGER_MS,
  REVEAL_SIDE_FRACTION,
  cellsBetween,
  revealEmojiFor,
  revealFontSize,
  revealLineHeight,
  revealTileOffset,
} from '../review/sudoku-reveal';

const side = 360;
const cell = side / 9;

test('the frozen emoji list is unique, single-grapheme and non-empty', () => {
  const segmenter = new Intl.Segmenter('en', {granularity: 'grapheme'});
  expect(REVEAL_EMOJI.length).toBeGreaterThan(0);
  expect(new Set(REVEAL_EMOJI).size).toBe(REVEAL_EMOJI.length);
  for (const emoji of REVEAL_EMOJI) expect([...segmenter.segment(emoji)]).toHaveLength(1);
});

test('the frozen list holds its curated range and heart selection', () => {
  // Saturn is the newest glyph (Unicode 12.0, U+1FA90); the deployment target
  // is iOS 18, so the whole list renders. Anything above it would raise the
  // frozen floor without a deliberate decision.
  for (const emoji of REVEAL_EMOJI) expect(emoji.codePointAt(0)!).toBeLessThanOrEqual(0x1FA90);
  expect(REVEAL_EMOJI).toContain('🪐');
  expect(REVEAL_EMOJI).toContain('🧡');
  for (const excluded of ['🖤', '🤍', '🤎']) expect(REVEAL_EMOJI).not.toContain(excluded);
});

test('the reveal emoji is a stable image per game and varies across puzzles', () => {
  // Shape is all the hashing cares about; the values exercise the mix.
  const givens = Array.from({length: 81}, (_, index) => (index % 9) + 1);
  const chosen = revealEmojiFor(givens);
  expect(REVEAL_EMOJI).toContain(chosen);
  // The same puzzle always maps to the same glyph, however it is handed in.
  expect(revealEmojiFor([...givens])).toBe(chosen);
  // Changing one clue is a different game, so the list must not collapse to one.
  const variants = Array.from({length: 20}, (_, row) =>
    givens.map((value, index) => (index === 0 ? (row % 9) + 1 : value)));
  expect(new Set(variants.map(revealEmojiFor)).size).toBeGreaterThan(1);
});

test('the glyph is a fixed fraction of the board side', () => {
  expect(REVEAL_SIDE_FRACTION).toBe(0.8);
  expect(revealFontSize(side)).toBe(Math.round(side * 0.8));
  expect(revealLineHeight(side)).toBe(Math.round(revealFontSize(side) * 1.16));
});

test('every tile holds the same board-sized glyph box, shifted by its cell', () => {
  expect(revealTileOffset(0, side)).toEqual({left: 0, top: 0});
  expect(revealTileOffset(8, side)).toEqual({left: -8 * cell, top: 0});
  expect(revealTileOffset(40, side)).toEqual({left: -4 * cell, top: -4 * cell});
  expect(revealTileOffset(80, side)).toEqual({left: -8 * cell, top: -8 * cell});
});

test('a stationary point stays in one cell', () => {
  expect(cellsBetween({x: 10, y: 10}, {x: 12, y: 12}, side)).toEqual([0]);
  expect(cellsBetween({x: cell * 3.5, y: cell * 2.5}, {x: cell * 3.6, y: cell * 2.6}, side)).toEqual([21]);
});

test('a fast swipe interpolates the cells it skipped instead of leaving a dotted trail', () => {
  // One move event jumps from the start of row 0 to the start of row 2.
  const cells = cellsBetween({x: 1, y: 1}, {x: 1, y: cell * 2 + 1}, side);
  expect(cells[0]).toBe(0);
  expect(cells[cells.length - 1]).toBe(18);
  expect(cells).toContain(9);
});

test('a diagonal swipe crosses the intermediate corner cells in order', () => {
  const cells = cellsBetween({x: 1, y: 1}, {x: cell * 2 + 1, y: cell * 2 + 1}, side);
  expect(cells[0]).toBe(0);
  expect(cells).toContain(10);
  expect(cells[cells.length - 1]).toBe(20);
  expect(cells).toEqual([...new Set(cells)]);
});

test('out-of-board samples are skipped and empty geometry is safe', () => {
  expect(cellsBetween({x: -cell * 2, y: -cell * 2}, {x: -1, y: -1}, side)).toEqual([]);
  // The traversal reports every cell the segment enters, including the
  // edge-adjacent cells a perfect diagonal touches at each grid corner; the
  // out-of-board tail is skipped.
  expect(cellsBetween({x: cell * 2, y: cell * 2}, {x: side + cell * 3, y: side + cell * 3}, side))
    .toEqual([20, 21, 30, 31, 40, 41, 50, 51, 60, 61, 70, 71, 80]);
  expect(cellsBetween({x: 0, y: 0}, {x: 1, y: 1}, 0)).toEqual([]);
});
test('an oblique segment clipping a cell corner still reports that cell',()=>{
  // This shallow segment enters the bottom row just left of the vertical
  // boundary, so it clips cell 9 for a sliver before entering cell 10. Half-cell
  // point sampling skips that sliver (its samples land in 0 and 10); the
  // boundary walk reports all three.
  expect(cellsBetween({x: cell * 0.49, y: cell * 0.98}, {x: cell * 1.49, y: cell * 1.02}, side))
    .toEqual([0, 9, 10]);
});

test('the trail timings leave room for the brush to read as a fading comet', () => {
  expect(REVEAL_LINGER_MS).toBeGreaterThan(200);
  expect(REVEAL_LINGER_MS).toBeLessThan(800);
  expect(REVEAL_FADE_MS).toBeGreaterThan(100);
  expect(REVEAL_FADE_MS).toBeLessThan(600);
});

test('the close curve front-loads the drop so the tile reads as a swift close', () => {
  // Chosen on device over the symmetric and accelerating variants: at the
  // midpoint the eased progress is already well ahead of the linear drop.
  expect(REVEAL_EASING(0)).toBeCloseTo(0, 5);
  expect(REVEAL_EASING(1)).toBeCloseTo(1, 5);
  expect(REVEAL_EASING(0.25)).toBeGreaterThan(0.25);
  expect(REVEAL_EASING(0.5)).toBeGreaterThan(0.5);
  let previous = 0;
  for (let step = 1; step <= 10; step++) {
    const value = REVEAL_EASING(step / 10);
    expect(value).toBeGreaterThanOrEqual(previous);
    previous = value;
  }
});
