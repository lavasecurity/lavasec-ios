export type DNSChoice={isEnabled?:boolean;id:string;name:string;primary:string;secondary:string;transport:string;metadata:string};
import type {PreviewSession} from '../review/session';
import type {PreviewDraft} from '../review/preview-model';
import type {SudokuGame} from '../review/sudoku-model';
import type {GuardMaterialIntent} from '../review/guard-material';

/** Confirmed configuration, rendered only within the app-settings access boundary. */
export type ConnectionSnapshot = {
  filter?: {id:string;name:string;count:string};
  configurationPending?:boolean;
  dns: {usesWireGuard?:boolean;editable?:boolean;primary:{name:string;detail:string;transport:string};fallback?:{name:string;detail:string;transport:string}|null};
  // enabled is the requested preference. Omitted configured/name means not inspected,
  // never "missing configuration" or proof of a working connection.
  vpn: {eligible:boolean;enabled:boolean;fallbackEnabled?:boolean|null;configured?:boolean;name?:string;statusLabel?:string};
};
/** Native-confirmed backup state. A null value must render attention/progress, never false. */
export type BackupEnablement = {
  state:'off'|'on'|'setup'|'busy'|'deletionPending'|'unavailable';
  value:boolean|null;
  canEnable:boolean;canDisable:boolean;canBackUp:boolean;canRestore:boolean;
  canChangeAutomatic:boolean;canRetryDeletion:boolean;
};
export type OnboardingPresentation = {session:string;mock:boolean;layoutRevision:number;phase:'setup'|'arriving'|'ready'|'opening'|'released'};
export type OnboardingFrame = {x:number;y:number;width:number;height:number};
export type AppSnapshot = {
  onboarding?:OnboardingPresentation;
  presentationBlocked?: boolean;
  /** Native concealment policy. Only explicit false permits an already-delivered inactive frame. */
  backgroundPrivacyCoverRequired?: boolean;
  connection?: ConnectionSnapshot;
  traceQueries?: boolean; // Emitted only by the DEBUG simulator delayed-read fixture.
  activityDates?: import('../specs/NativeLavaReview').ActivityDates;
  presentation: {locale:string;textScales:Record<string,number>|null};
  discoveries?: Partial<Record<DiscoveryID, boolean>>;
  dnsPatch?: {provider?:DNSChoice|null;choices?:DNSChoice[];available:boolean;state:'checking'|'absent'|'different'|'disabled'|'enabled'|'error';busy:boolean};
  settingsSummary: {dns:string;privacy:string;security:string};
  confirmations?: Record<string,{title:string;message:string;action:string}>;
  security: {readRevision?: number; sourceRevision?: string; ownerRevision?:string;displayClearRevision?:string;hasAuthenticationMethod?:boolean;updatingSurface?:boolean;unavailable:boolean;showBiometrics:boolean;canEnableBiometrics:boolean;biometricTitle:string;status:string};
  navigation?: {serial:number;tab:string;screen:string};
  schema: 1; revision: number; fullApp: true; sourceRevision?:string; version: string; build: string;
  protection: {materialIntent?:GuardMaterialIntent;actionTone?:'affirmative'|'quiet'|'recovery';today?:{countsEnabled:boolean;allowed:number;blocked:number};configuring?:boolean;quiet?:boolean;pauseOptions?:{minutes:number;title:string}[];mood:string; title: string; subtitle: string; action: string; disabled: boolean; status: number; paused: boolean; canPause: boolean; needsVPNSetup?: boolean; needsDNSProviderChange?:boolean; rules: number; activity: string};
  account: {appleBusy?:boolean;googleBusy?:boolean;signedIn: boolean; status: string; detail: string; appleTitle: string; googleTitle: string; appleConnected: boolean; googleConnected: boolean; busy: boolean; message: string};
  backup: {enablement?:BackupEnablement;detail?:string;needsAttention?:boolean;deletionPending?:boolean;backingUp?:boolean;remoteStatus?:string;remoteAvailable?:boolean;statusUnavailable?:boolean;configured: boolean; title: string; summary: string; automatic: boolean; busy: boolean};
  plus: {enabled: boolean; busy: boolean; checking:boolean; showsYearlyPaidMonthly:boolean; expiration:string; message: string; offers: {id: string; title: string; subtitle: string; price: string; commitmentPrice?: string}[]};
  session: Omit<PreviewSession, 'shareFilter'> & {filterID: string; activeFilterID: string};
  look: string; draft: PreviewDraft; savedDraft: PreviewDraft; sudoku?: SudokuGame;
  guards: {id: string; title: string; subtitle: string; selectable: boolean; description: string; tip: string}[];
  vpn?: {draft?:VPNDraft|null;setup:boolean;enabled:boolean;canEnable:boolean;canEdit:boolean;fallback:boolean;canChangeFallback:boolean;needsPlus:boolean;busy:boolean;restriction:string;error:string;unavailable:boolean;needsRepair?:boolean;rotationNote?:string;generation:string;rows:{name:string;mode:string;isEnabled?:boolean}[]};
  dns: {customDraft?:DNSChoice|null;customDraftToken?:string;tiers?:DNSChoice[];tiersContext?:string;choices?:DNSChoice[];editable?:boolean;transportDetail?:string;custom?:{name:string;primary:string;secondary:string;valid:boolean;metadata:string;context:string};deviceDetail?:string;fallbackDetail?:string;providers: {id: string; name: string; address: string; selected:boolean}[]; customSelected:boolean; transports: string[]};
  liveActivityPauseMinutes: number; liveActivityPause: {available:boolean;label:string;minutes:number[]}; qaTools: boolean;
  limits: {maxAllowedDomains: number; maxBlockedDomains: number; maxFilterRules: number; maxFilters: number; allowsCustomBlocklists: boolean; allowsCustomDNS: boolean};
  filterEditing?: {canSave:boolean;reviewCanConfirm?:boolean;validation?:string;refreshing:boolean;lists:{id:string;pending:boolean;undo:boolean}[];blocked:{id:string;pending:boolean;undo:boolean}[];allowed:{id:string;pending:boolean;undo:boolean}[]};
  libraryEditing?: {active:boolean;hasChanges:boolean;deletions:string[]};
  /** Editor-only identity; never included in saved filters or Guard. */
  newFilter?: AppSnapshot['filters'][number];
  filterPreparationPresented: boolean;
  logExportBusy: boolean; logExportError: string;
  domainHistoryCount?:number;
  hasDomainHistory: boolean;
  filterStatus: {title:string;icon:string;label:string;warning:boolean};
  blocklistNames: Record<string,string>;
  blocklistMetadata: Record<string,string>;
  filters: {emoji?:string;blockedDomainCount?:number;allowedExceptionCount?:number;empty?:boolean;id: string; name: string; frozen: boolean; count: string; lists: string[]; shareable: boolean; shareSummary: string}[];
};
export type DiscoveryID = 'ios27Patch.settings' | 'ios27Patch.page';

export type VPNDraft = {id:string;revision:number;changed:boolean;containsFullTunnel:boolean;rows:{name:string;mode:string;isEnabled?:boolean}[]};

export type AppCommand =
  | {type:'vpn.begin';id:string;generation:string}
  | {type:'vpn.cancel'|'vpn.reset'|'vpn.swap';id:string}
  | {type:'vpn.commit';id:string}
  | {type:'vpn.toggle';key:'setup'|'enabled'|'fallback';value:boolean}
  | {type:'vpn.edit'|'vpn.remove';id:string;index:number}
  | {type: 'discovery.seen'; target: DiscoveryID}
  | {type: 'reports.sample' | 'refresh' | 'protection.toggle'}
  | {type: 'protection.pause'; minutes: 5 | 10 | 15}
  | {type: 'navigation.authorize'; surface: 'appUnlock' | 'appSettings' | 'activityViewing' | 'filterEditing' | 'credentials'; newTurn?:boolean}
  | {type: 'navigation.endTurn'}
  | {type:'dns.toggle';context:string;index:number;value:boolean}
  | {type:'vpn.rowToggle';generation:string;index:number;value:boolean}
  | {type:'dns.tiers';context:string;tiers:{id:string;name:string;primary:string;secondary:string;isEnabled?:boolean}[]}
  | {type:'customEntry.dismiss';id:string}
  | {type:'dns.customDraft';choice?:DNSChoice}
  | {type:'dns.custom';context:string;name:string;primary:string;secondary:string}
  | {type: 'settings.set'; key: string; value: string | boolean | number}
  | {type: 'filter.open' | 'filter.close' | 'filter.save' | 'filter.edit' | 'filter.cancel' | 'filter.switch' | 'filter.refresh' | 'filter.delete' | 'filter.renameForm'; id: string}
  | {type:'library.edit'|'library.cancel'}
  | {type:'library.toggleDeletion';id:string}
  | {type:'library.form';form:'create'|'rename'|'delete';id?:string;ids?:string[]}
  | {type: 'filter.create'; name: string; duplicate?: string}
  | {type: 'filter.rename'; id: string; name: string; emoji?:string}
  | {type: 'filter.domain' | 'filter.undoDomain'; id: string; domain: string; decision: 'blocked' | 'allowed'; remove?: boolean}
  | {type: 'filter.removeList' | 'filter.undoList'; id: string; sourceID: string}
  | {type: 'filter.lists' | 'filter.customList'; id: string; ids: string[]}
  | {type:'filter.deleteCustomList';id:string;sourceID:string}
  | {type: 'filter.review'; id: string}
  | {type: 'filter.apply'; id: string; review: string; standaloneReview?: string}
  | {type: 'account.apple' | 'account.google' | 'account.signOut' | 'account.delete' | 'backup.refresh' | 'backup.now' | 'backup.disable' | 'backup.delete' | 'purchase.restore' | 'purchase.manage' | 'purchase.refresh' | 'purchase.clearMessage'}
  | {type: 'native.flow'; flow: string}
  | {type: 'logs.clear'; kind: string;surface?:'activityViewing'}
  | {type: 'logs.export'; domains: false}
  | {type: 'sudoku.save'; game: SudokuGame}
  | {type: 'share.query' | 'share.copy' | 'share.present'; id: string}
  | {type:'share.card';id:string;token:string}
  | {type: 'purchase.buy'; id: string}
  | {type: 'sudoku.new'}
  | {type:'onboarding.geometry';session:string;phase:OnboardingPresentation['phase'];layoutRevision:number;frames:{panel:OnboardingFrame;mascot:OnboardingFrame;action:OnboardingFrame}}
  | {type:'guard.gesture';gesture:'start'|'end'|'tap'|'reveal'}
  | {type: 'haptic'; kind:'selection'|'changed'|'inspectionEmpty'|'rejected'|'success'|'selected'|'engaged'|'succeeded'|'attentionRequired'|'failed'|'acknowledged';controlID?:string;value?:string}
  | {type:'filter.restoreDefaults'}
  | {type: 'catalog.query'; ids: string[]}
  | {type:'activity.visibility'; token:string;visible:boolean;start?:number;end?:number}
  | {type: 'activity.query'; start?: number; end?: number; hourly?: boolean}
  | {type: 'domains.query'; start?: number; end?: number; history: boolean; decision: string; search: string; limit?: number}
  | {type: 'network.query' | 'stats.query'}
  | {type: 'domains.copy'; domain: string}
  | {type: 'domains.enableHistory'}
  | {type: 'domains.cancel'; token: string}
  | {type: 'domains.stage'; domain: string; decision: 'allowed' | 'blocked'};
