// Review fixtures live only in this React tree. Values mirror a fresh native
// installation for layout review; none are production settings or credentials.
import type {SudokuGame} from './sudoku-model';
export const protectedActionNames = ['App Unlock', 'Turn on/off Lava', 'Pause Lava', 'Update domains and lists', 'View Activities', 'Update App Settings'] as const;
type ProtectedActions = Record<typeof protectedActionNames[number], boolean>;
export type PreviewSession = {
  sudoku?: SudokuGame;
  filter: string; activeFilter: string; shareFilter: string; editing: boolean; blocklists: string[]; savedBlocklists: string[];
  logs: Record<string, boolean>; notifications: Record<string, boolean>;
  deviceDNS: boolean; fallback: boolean; provider: string; transport: string;
  matchTextSize: boolean; textSize: number; haptics: boolean; liveActivities: boolean;
  matchIcon: boolean; passcode: boolean; biometrics: boolean; protectedActions: ProtectedActions;
};
export const defaultBlocklists = ['Block List Basic', 'StevenBlack Unified Hosts'];
export const initialSession = (): PreviewSession => ({
  filter: 'Balanced', activeFilter: 'Balanced', shareFilter: 'Balanced', editing: false, blocklists: [...defaultBlocklists], savedBlocklists: [...defaultBlocklists],
  logs: {'Filtering Counts': true, 'Domain logs': true, 'Network activity': true, 'Lava Guard Progress': true},
  notifications: {'Filter changes': true, "Filter couldn't switch": true, 'Protection resumed': true, 'Connection updates': true},
  deviceDNS: false, fallback: true, provider: 'Quad9', transport: 'DoH', matchTextSize: true, textSize: 3,
  haptics: true, liveActivities: false, matchIcon: true, passcode: false, biometrics: false,
  protectedActions: Object.fromEntries(protectedActionNames.map(title => [title, false])) as ProtectedActions,
});
export const filterFixtures = [
  {name: 'Core', count: '76,031', lists: ['Block List Basic']},
  {name: 'Balanced', count: '121,652', lists: [...defaultBlocklists]},
  {name: 'Extra', count: '535,118', lists: ['Block List Basic', 'StevenBlack Unified Hosts', 'Block List Ads', 'Block List Tracking']},
] as const;

export const reviewDNSProviders = [
  ['Quad9','https://dns10.quad9.net/dns-query'], ['Cloudflare 1.1.1.1','https://cloudflare-dns.com/dns-query'],
  ['HaGeZi DNS','https://root.hagezi.org/dns-query'], ['Google Public DNS','https://dns.google/dns-query'],
] as const;
