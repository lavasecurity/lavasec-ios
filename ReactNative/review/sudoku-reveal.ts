import {Easing} from 'react-native';

// Solved-board emoji reveal (brush): after a successful solve, one frozen emoji
// is laid out once, centered at REVEAL_SIDE_FRACTION of the board; each touched
// cell shows its window of that glyph, then fades. This module owns the pure
// policy (emoji list, geometry, trail interpolation, timings) so the screen and
// its tests share one definition and the gameplay board stays untouched.

// Version 1 stays frozen in both membership and order: saved puzzles without
// revealVersion used this 44-glyph pool. Extending its modulus would change
// their pictures after an app update, even though the puzzle itself is unchanged.
const LEGACY_REVEAL_EMOJI = [
  // Fruit
  '🍎', '🍋', '🍇', '🍉', '🍓', '🍒', '🍑', '🍍', '🍌', '🍊', '🍐', '🥝',
  // Animals
  '🦊', '🐼', '🦄', '🐢', '🐬', '🐙', '🐳', '🐧', '🐸', '🐝', '🦋', '🦁',
  // Plants
  '🌵', '🍄', '🌻', '🌴', '🌳', '🌸', '🌹', '🌷', '🍀', '🌱',
  // Hearts (no black, white or brown)
  '❤️', '🧡', '💛', '💚', '💙', '💜',
  // Others
  '🗿', '🌈', '⭐️', '🪐',
] as const;

// Curated Unicode ≤ 12.0, single-grapheme emoji; all render on the iOS 18 floor.
// Version 2 adds 40 animals, treats, plants, sky scenes and playful objects.
// Keep this pool frozen too; future expansions need a new persisted version.
export const REVEAL_EMOJI = [
  ...LEGACY_REVEAL_EMOJI,
  // Animals
  '🐶', '🐱', '🐰', '🐹', '🐻', '🐨', '🦦', '🦔',
  '🦝', '🦥', '🦉', '🐣', '🐷', '🐮', '🐯', '🐵',
  // Sweets
  '🍦', '🍩', '🍪', '🧁', '🍭', '🍮',
  // Snacks
  '🍙', '🥐', '🥨', '🥞',
  // Nature
  '🌺', '🌼', '🍁', '🌿',
  // Sky and space
  '🌞', '🌙', '🌍', '🚀',
  // Toys and gifts
  '🧸', '🎈', '🎁', '🎀', '🪁', '🧩',
] as const;

export const REVEAL_SIDE_FRACTION = 0.8;
// Trail lifetime: a cell holds while the finger is on it, then lingers LINGER
// before fading over FADE. Trail length on a swipe is speed × (LINGER + FADE);
// there is deliberately no tile cap — the fade rate is the limiter.
export const REVEAL_LINGER_MS = 450;
export const REVEAL_FADE_MS = 320;
// Close curve, chosen from an on-device blind comparison of nine variants:
// ease-out front-loads the opacity drop, so the tile reads as a swift close
// while the elapsed time stays the same. The symmetric default (inOut) and the
// accelerating variants held the image visibly longer before it vanished.
export const REVEAL_EASING = Easing.out(Easing.cubic);
// Line-box height as a fraction of the glyph size. Emoji ink sits just above the
// baseline; a slightly taller line box keeps the visual center near the board
// center across iOS font updates.
export const REVEAL_LINE_HEIGHT_FRACTION = 1.16;

export type RevealPoint = {x: number; y: number};

/// The reveal image belongs to the GAME, not to when you look at it. The index
/// is derived from the puzzle's givens, so the same game always shows the same
/// glyph — re-opening the solved board, resetting it, or relaunching on it must
/// not change the picture — while a new puzzle draws a different one. FNV-1a
/// over the givens, then a final mix so the low bits spread across the list.
export function revealEmojiFor(givens: readonly number[], revealVersion: 1 | 2 = 1): string {
  let hash = 0x811c9dc5;
  for (const value of givens) {
    hash = Math.imul(hash ^ value, 0x01000193);
  }
  hash ^= hash >>> 16;
  hash = Math.imul(hash, 0x21f0aaad);
  hash ^= hash >>> 15;
  hash = Math.imul(hash, 0x735a2d97);
  hash ^= hash >>> 15;
  const pool = revealVersion === 2 ? REVEAL_EMOJI : LEGACY_REVEAL_EMOJI;
  return pool[(hash >>> 0) % pool.length]!;
}

export function revealFontSize(side: number): number {
  return Math.round(side * REVEAL_SIDE_FRACTION);
}

export function revealLineHeight(side: number): number {
  return Math.round(revealFontSize(side) * REVEAL_LINE_HEIGHT_FRACTION);
}

/// Where the single board-sized emoji box sits inside tile `index`: the whole
/// box is translated so its board-centered glyph lines up with the tile window.
export function revealTileOffset(index: number, side: number): {left: number; top: number} {
  const cell = side / 9;
  const col = index % 9, row = Math.floor(index / 9);
  return {left: col === 0 ? 0 : -col * cell, top: row === 0 ? 0 : -row * cell};
}

/// Cells the finger crossed between two board-local points. Move events arrive
/// at display rate, so a fast swipe jumps whole cells; this walks the segment
/// across the grid (Amanatides–Woo) so every cell it enters is visited — point
/// sampling can step over a cell the segment merely clips. Out-of-board cells
/// are skipped; the order is first-touch order with no repeats.
export function cellsBetween(from: RevealPoint, to: RevealPoint, side: number): number[] {
  const cell = side / 9;
  if (!(cell > 0)) return [];
  const fromX = from.x / cell, fromY = from.y / cell;
  let x = Math.floor(fromX), y = Math.floor(fromY);
  const endX = Math.floor(to.x / cell), endY = Math.floor(to.y / cell);
  const seen = new Set<number>();
  const cells: number[] = [];
  const collect = () => {
    if (x < 0 || x > 8 || y < 0 || y > 8) return;
    const index = y * 9 + x;
    if (seen.has(index)) return;
    seen.add(index);
    cells.push(index);
  };
  const dx = to.x / cell - fromX, dy = to.y / cell - fromY;
  const stepX = dx > 0 ? 1 : dx < 0 ? -1 : 0;
  const stepY = dy > 0 ? 1 : dy < 0 ? -1 : 0;
  let tMaxX = stepX === 0 ? Infinity : ((stepX > 0 ? x + 1 : x) - fromX) / dx;
  let tMaxY = stepY === 0 ? Infinity : ((stepY > 0 ? y + 1 : y) - fromY) / dy;
  const tDeltaX = stepX === 0 ? Infinity : Math.abs(1 / dx);
  const tDeltaY = stepY === 0 ? Infinity : Math.abs(1 / dy);
  collect();
  for (let guard = 81; guard > 0 && (x !== endX || y !== endY); guard--) {
    // Ties step x first: a corner-crossing segment visits both edge-adjacent
    // cells before the diagonal one, which is what a brush should reveal.
    if (tMaxX <= tMaxY) { x += stepX; tMaxX += tDeltaX; } else { y += stepY; tMaxY += tDeltaY; }
    collect();
  }
  return cells;
}
