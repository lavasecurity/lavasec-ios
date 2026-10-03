import {DynamicColorIOS, PlatformColor, type ColorValue} from 'react-native';
import {lavaTokens} from './generated/tokens';
import type {LavaColorScheme} from './appearance';

type ColorDescription =
  | {light: readonly number[]; dark: readonly number[]}
  | {system: string}
  | {alias: string};
const descriptions: Readonly<Record<string, ColorDescription>> = lavaTokens.colors;

function resolve(name: string, scheme?: LavaColorScheme): ColorValue {
  const value = descriptions[name];
  if (!value) throw new Error(`Unknown Lava color ${name}`);
  if ('system' in value) return PlatformColor(value.system);
  if ('alias' in value) return resolve(value.alias, scheme);
  // RN encodes custom colors as 8-bit sRGB; keep the Swift fractions in generated
  // data and quantize only at this platform boundary. Device comparison remains required.
  const rgb = (channels: readonly number[]) => `rgb(${channels.map(c => Math.round(c * 255)).join(', ')})`;
  return scheme ? rgb(value[scheme]) : DynamicColorIOS({light: rgb(value.light), dark: rgb(value.dark)});
}

/** Resolve a scaffold color against app appearance, independent of local native traits. */
export const colorForScheme = (name: keyof typeof lavaTokens.colors, scheme: LavaColorScheme): ColorValue => resolve(name, scheme);

export const colors = Object.fromEntries(
  Object.keys(lavaTokens.colors).map(name => [name, resolve(name)]),
) as Record<keyof typeof lavaTokens.colors, ColorValue>;
