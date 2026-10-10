// `name` is display-ready copy; sourceName retains the authored identity used
// when editing or saving. An empty sourceName means the app supplied a label.
export type DNSChoice={isEnabled?:boolean;id:string;name:string;sourceName?:string;primary:string;secondary:string;transport:string;metadata:string};
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
export type OnboardingFrame = {x:number;y:number;width:number;height:number};
export type OnboardingSetup = {id:string;mock:boolean;page:number;history:number[];visited:number[];level:'essential'|'balanced'|'comprehensive';fallback:boolean;dnsProfile:boolean;supportsDNSProfile:boolean;vpnInstalled:boolean;notifications:boolean;busy:string;error:string;phase:'setup'|'arriving'|'ready'|'opening'|'released'};
export type AppSnapshot = {
  foregroundFlow?:ForegroundFlow|null;
  foregroundClosing?:string[];
  customEntry?:{id:string;kind:'dns'|'blocklist';name:string;primary:string;secondary:string;allowed:boolean;overBudget:boolean}|null;
  onboardingSetup?:OnboardingSetup|null;
  presentationBlocked?: boolean;
  presentationToken?: string;
  /** Native concealment policy for background/lock boundaries. */
  backgroundPrivacyCoverRequired?: boolean;
  /** Display continuity for a native-owned biometric prompt; never read/action authority. */
  authenticationInProgress?: boolean;
  /** A hard native lock/background boundary overrides authentication display continuity. */
  presentationRevoked?: boolean;
  connection?: ConnectionSnapshot;
  tracePresentation?:boolean; // Opt-in DEBUG simulator stage/timing trace.
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
  vpn?: {authorized:boolean;draft?:VPNDraft|null;setup:boolean;enabled:boolean;canEnable:boolean;canEdit:boolean;fallback:boolean;canChangeFallback:boolean;needsPlus:boolean;busy:boolean;restriction:string;error:string;unavailable:boolean;needsRepair?:boolean;rotationNote?:string;generation:string;rows:{name:string;mode:string;isEnabled?:boolean}[]};
  dns: {customDraft?:DNSChoice|null;customDraftToken?:string;tiers?:DNSChoice[];tiersContext?:string;choices?:DNSChoice[];editable?:boolean;transportDetail?:string;custom?:{name:string;primary:string;secondary:string;valid:boolean;metadata:string;context:string};deviceDetail?:string;fallbackDetail?:string;providers: {id: string; name: string; address: string; selected:boolean}[]; customSelected:boolean; transports: string[]};
  liveActivityPauseMinutes: number; liveActivityPause: {available:boolean;label:string;minutes:number[]}; qaTools: boolean;
  limits: {maxAllowedDomains: number; maxBlockedDomains: number; maxFilterRules: number; maxFilters: number; allowsCustomBlocklists: boolean; allowsCustomDNS: boolean};
  filterEditing?: {canSave:boolean;reviewCanConfirm?:boolean;validation?:string;upgradeReason?:import('../review/plus-intents').PlusReason|'';refreshing:boolean;lists:{id:string;pending:boolean;undo:boolean}[];blocked:{id:string;pending:boolean;undo:boolean}[];allowed:{id:string;pending:boolean;undo:boolean}[]};
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
export type FeedbackState={topic:string;site:string;details:string;email:string;diagnostics:boolean;step:number;furthest:number;revision:string;review:string;normalizedSite:string;normalizedDetails:string;normalizedEmail:string;count:number;canContinue:boolean;dirty:boolean;busy:boolean;prepared:boolean;sent:boolean;error:string;receipt:string;copied:boolean;topics:{id:string;title:string}[]};
export type FeedbackPreview={id:string;title:string;purpose:string;items:{id:string;label:string;value:string}[]};
export type VPNEditorState={name:string;nameResetRevision:number;dirty:boolean;hasContent:boolean;concealed:boolean;reading:boolean;canEdit:boolean;canSave:boolean;error:string};
export type ForegroundFlow={id:string;kind:'createFilter'|'renameFilter'|'deleteFilters'|'automation'|'licenses'|'feedback'|'vpnConfiguration';name:string;emoji:string;dismissAttempt:number;canCreate:boolean;templates:{id:string;name:string}[];groups?:{title:string;added:string[];removed:string[]}[];hasDeletions?:boolean;notices?:string;feedback?:FeedbackState;vpnEditor?:VPNEditorState|null};

export type AppCommand =
  | {type:'feedback.enter'|'feedback.preview'|'feedback.copy';id:string}
  | {type:'feedback.topic';id:string;topic:string}
  | {type:'feedback.change';id:string;field:'site'|'details'|'email';value:string}
  | {type:'feedback.diagnostics';id:string;value:boolean}
  | {type:'feedback.step';id:string;next?:boolean;step?:number}
  | {type:'feedback.submit';id:string;review:string}
  | {type:'system.open';target:'shortcuts'|'settings'}
  | {type:'foreground.dismiss';id:string;discardConfirmed?:boolean}
  | {type:'foreground.enter';id:string}
  | {type:'vpnEditor.enter'|'vpnEditor.file'|'vpnEditor.save';id:string}
  | {type:'vpnEditor.name';id:string;name:string}
  | {type:'foreground.dirty';id:string;dirty:boolean}
  | {type:'foreground.identity';id:string;name:string;emoji:string}
  | {type:'foreground.submit';id:string;template?:string;name?:string;emoji?:string}
  | {type:'vpn.begin';id:string;generation:string}
  | {type:'vpn.enter'}
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
  | {type:'customEntry.dismiss'|'customEntry.enter';id:string}
  | {type:'customEntry.save';id:string;name:string;primary?:string;secondary?:string;url?:string}
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
  | {type: 'sudoku.new'; challenge?: boolean}
  | {type:'onboarding.enter'|'onboarding.back'|'onboarding.vpn'|'onboarding.notifications'|'onboarding.ready'|'onboarding.open'|'onboarding.release'|'onboarding.complete'|'onboarding.dismiss';id:string}
  | {type:'onboarding.navigate';id:string;page:number;revisit?:boolean;skipFailedDNSProfile?:boolean}
  | {type:'onboarding.choice';id:string;level?:OnboardingSetup['level'];fallback?:boolean;dnsProfile?:boolean}
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
