import {AppState} from 'react-native';
import {clearAppReadCache, readPrivacyScope, mayRetainPresentationFrame} from './read-cache';
import type {Spec} from '../specs/NativeLavaApp';
import type {AppCommand, AppSnapshot} from './contract';
import {PresentationHydration} from './presentation-hydration';

export class AppStore {
  private state: {snapshot: AppSnapshot | null; displaySnapshot: AppSnapshot | null; error: string | null; privacyCoverRequired?:boolean} = {snapshot: null, displaySnapshot: null, error: null};
  private listeners = new Set<() => void>();
  private generation = 0;
  private connected = false;
  private invalidation = 0;
  private readEpoch = 0;
  private lastSnapshotRevision = -1;
  private tail: Promise<unknown> = Promise.resolve();
  private hasAcceptedPresentation=false;
  private hydration=new PresentationHydration(()=>this.notify());
  constructor(private readonly native: Spec, initialSnapshot?: AppSnapshot) {
    if (initialSnapshot) this.accept(initialSnapshot,true);
  }
  getSnapshot = () => this.state;
  getInvalidation = () => this.invalidation;
  getReadEpoch = () => this.readEpoch;
  getPresentationHydration = this.hydration.getSnapshot;
  registerPresentationRead = () => this.hydration.registerRead();
  settlePresentationRead = (ticket:ReturnType<PresentationHydration['registerRead']>) => this.hydration.settleRead(ticket);
  completePresentationLayout = (epoch:number) => this.hydration.completeLayout(epoch);
  private revokeReads() {clearAppReadCache(this); ++this.readEpoch; ++this.invalidation;}
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => {this.listeners.delete(listener);}; };
  private notify() { for (const listener of this.listeners) listener(); }
  private accept(snapshot: AppSnapshot, initial=false) {
    if (!snapshot || snapshot.schema !== 1 || snapshot.fullApp !== true || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0) throw new Error('The installed native app does not provide the full Lava runtime.');
    if (snapshot.revision < this.lastSnapshotRevision) return;
    // A minimal inactive reply can cross the bridge after the full active reply
    // for that same native revision. It grants no new fields and cannot revoke
    // authority already restored by the newer lifecycle observation.
    if(snapshot.presentationBlocked&&mayRetainPresentationFrame(snapshot)
      &&snapshot.revision===this.lastSnapshotRevision&&this.state.snapshot)return;
    this.lastSnapshotRevision = snapshot.revision;
    const privacyCoverRequired=snapshot.backgroundPrivacyCoverRequired;
    if (snapshot.presentationBlocked || AppState.currentState !== 'active') {
      // Blocked/inactive events carry concealment metadata only. Confirmed off
      // preserves a trusted prior frame through active refresh as well; these
      // events cannot replace it, reopen reads, or revive a discarded frame.
      const previous=this.state.snapshot??this.state.displaySnapshot;
      // Native composed the bootstrap fields under its own foreground/read
      // checks. JS AppState may not have caught up yet. An explicit all-off
      // bootstrap can paint immediately, without granting queries or actions.
      // Only this constructor handoff may seed a frame; later inactive events
      // still cannot create one after a privacy boundary.
      const bootstrap=initial&&!snapshot.presentationBlocked&&mayRetainPresentationFrame(snapshot);
      const displaySnapshot=bootstrap?snapshot:mayRetainPresentationFrame(snapshot)
        &&mayRetainPresentationFrame(previous)?previous:null;
      if(bootstrap)this.hasAcceptedPresentation=true;
      const beginsBoundary=!!previous&&!displaySnapshot&&this.hasAcceptedPresentation;
      if (this.state.snapshot || this.state.displaySnapshot&&!displaySnapshot) this.revokeReads();
      this.state={snapshot:null,displaySnapshot,error:null,privacyCoverRequired};
      if(beginsBoundary)this.hydration.beginBoundary();else this.notify();return;
    }
    const beginsBoundary=!!this.state.displaySnapshot&&!mayRetainPresentationFrame(snapshot);
    if (this.state.displaySnapshot||this.state.snapshot && (readPrivacyScope(this.state.snapshot) !== readPrivacyScope(snapshot)
      ||this.state.snapshot.backgroundPrivacyCoverRequired!==snapshot.backgroundPrivacyCoverRequired)) {
      this.revokeReads();
    }
    this.hasAcceptedPresentation=true;
    this.state = {snapshot, displaySnapshot:null, error: null,privacyCoverRequired};
    if(mayRetainPresentationFrame(snapshot)&&this.hydration.getSnapshot().required)this.hydration.reset();
    else if(beginsBoundary)this.hydration.beginBoundary();else this.notify();
  }
  connect() {
    const generation = ++this.generation;
    this.connected = true;
    const subscription = this.native.onSnapshot(value => {
      if (generation === this.generation) { try {
        const snapshot=JSON.parse(value) as AppSnapshot;this.accept(snapshot);
        // A queued inactive marker can arrive after JS becomes active. Request
        // the current native projection so its display-only pause ends promptly.
        if(AppState.currentState==='active'&&this.state.displaySnapshot
          &&snapshot.presentationBlocked&&mayRetainPresentationFrame(snapshot))void this.refresh();
      } catch (error) {this.fail(error);} }
    });
    const lifecycle = AppState.addEventListener('change', state => {
      if (state !== 'active') {
        const previous=this.state.snapshot??this.state.displaySnapshot;
        const displaySnapshot=mayRetainPresentationFrame(previous)?previous:null;
        const beginsBoundary=!!previous&&!displaySnapshot&&this.hasAcceptedPresentation;
        // Confirmed all-off preserves only the existing visual frame; pending
        // reads, cache authority and every active snapshot still lose their epoch.
        this.revokeReads(); this.state = {snapshot:null,displaySnapshot,error:null,privacyCoverRequired:this.state.privacyCoverRequired};
        if(beginsBoundary)this.hydration.beginBoundary();else this.notify();
      } else {
        void this.refresh();
      }
    });
    void this.refresh();
    return () => {if (generation === this.generation) {++this.generation; this.connected = false;clearAppReadCache(this);this.state={snapshot:null,displaySnapshot:null,error:null};this.hydration.reset();this.notify();} subscription.remove(); lifecycle.remove();};
  }
  private fail(error: unknown) { this.state = {...this.state, error: error instanceof Error ? error.message : String(error)}; this.notify(); }
  async refresh() {
    const generation = this.generation, readEpoch = this.readEpoch;
    try { const value = await this.native.getSnapshot(); if (generation === this.generation && readEpoch === this.readEpoch) this.accept(JSON.parse(value)); }
    catch (error) { if (generation === this.generation) this.fail(error); }
  }
  command<T = unknown>(command: AppCommand): Promise<T> {
    const generation = this.generation;
    const execute = async () => {
      if (!this.connected || generation !== this.generation) throw new Error('The app screen closed before this action started.');
      // Owner retirement releases native work when a concealed body unmounts.
      // It grants no new read/action authority; replies still follow epoch and
      // native snapshot fences below.
      const retiresOwner=['vpn.cancel','customEntry.dismiss','domains.cancel','filter.close','purchase.clearMessage'].includes(command.type)
        ||command.type==='activity.visibility'&&!command.visible;
      if(!retiresOwner&&(AppState.currentState!=='active'||!this.state.snapshot))throw new Error('Read access changed.');
      // Restored native authorization permits mounted screens to prepare their
      // owner and presentation under the cover. Interactive callbacks remain
      // paused; setup cannot reject once and leave an empty retained route.
      const presentationWork=command.type.endsWith('.query')||['filter.review','filter.open','refresh','onboarding.geometry',
        'discovery.seen','backup.refresh','purchase.refresh','sudoku.new','activity.visibility'].includes(command.type);
      if(!retiresOwner&&this.hydration.getSnapshot().required&&!presentationWork)throw new Error('Read access changed.');
      const revokesReads = command.type === 'logs.clear' || command.type.startsWith('account.');
      if (revokesReads) {this.revokeReads(); this.notify();}
      const readEpoch = this.readEpoch;
      const response = JSON.parse(await this.native.command(JSON.stringify(command))) as {snapshot?: AppSnapshot; result: T};
      if (generation !== this.generation) throw new Error('The app screen closed while this action completed.');
      // A haptic changes no app state. Native acknowledges only the effect;
      // independent snapshot events still carry actual runtime changes.
      if (command.type === 'haptic' || command.type === 'onboarding.geometry') return response.result;
      if ((command.type.endsWith('.query') || command.type === 'domains.stage') && readEpoch !== this.readEpoch) throw new Error('Read access changed.');
      if (!response.snapshot) throw new Error('The native app did not return its updated state.');
      if (!command.type.endsWith('.query') && !command.type.startsWith('navigation.') && !['refresh','haptic','guard.gesture','activity.visibility'].includes(command.type)) ++this.invalidation;
      const mayPublish = readEpoch === this.readEpoch;
      if (revokesReads) this.revokeReads();
      // An interrupted mutation may finish, but its old presentation must not
      // repopulate a newly authenticated foreground session.
      if (mayPublish) this.accept(response.snapshot);
      return response.result;
    };
    // A filter compile may run for seconds. Protection Stop and authenticated
    // navigation must reach the native orchestrator immediately while it runs.
    // Apply starts only after the queued review returns a token. Native rechecks
    // that token against the current draft/baseline and rejects overtaken edits.
    if (command.type.startsWith('protection.') || command.type.endsWith('.query') || ['refresh','haptic','onboarding.geometry','guard.gesture','activity.visibility','filter.open','filter.close','filter.refresh','filter.edit'].includes(command.type) || command.type.startsWith('navigation.') || command.type === 'filter.apply') return execute();
    const result = this.tail.then(execute, execute);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}
