import {AppState} from 'react-native';
import {clearAppReadCache, readPrivacyScope, domainReviewPrivacyScope, mayRetainPresentationFrame, presentationScaffoldOwnerScope} from './read-cache';
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
  private domainReviewEpoch = 0;
  private lastSnapshotRevision = -1;
  private presentationToken?:string;
  private tail: Promise<unknown> = Promise.resolve();
  private refreshing?:{generation:number;readEpoch:number;promise:Promise<void>};
  private pendingQueries=new Map<string,Promise<unknown>>();
  private hasAcceptedPresentation=false;
  private retainingAuthenticationFrame=false;
  private authenticationPauseEpoch=0;
  private navigationAuthorizationEpoch=0;
  private hydration:PresentationHydration;
  constructor(private readonly native: Spec, initialSnapshot?: AppSnapshot, presentation?:{initial:boolean}) {
    this.hydration=new PresentationHydration(()=>{this.tracePresentation(this.hydration.getSnapshot().required?"react.concealed":"react.hydrated");this.notify();});
    if (initialSnapshot) this.accept(initialSnapshot,true);
    if(presentation?.initial)this.hydration.beginInitialPresentation();
  }
  private traceEnabled=false;
  tracePresentation = (stage:string) => {if(this.traceEnabled)console.info('LAVA_PRESENTATION '+Date.now()+' '+stage);};
  getSnapshot = () => this.state;
  getInvalidation = () => this.invalidation;
  getReadEpoch = () => this.readEpoch;
  getPresentationToken = () => this.presentationToken;
  getPresentationHydration = () => this.hydration.getSnapshot();
  registerPresentationRead = () => this.hydration.registerRead();
  settlePresentationRead = (ticket:ReturnType<PresentationHydration['registerRead']>) => this.hydration.settleRead(ticket);
  completePresentationLayout = (epoch:number) => this.hydration.completeLayout(epoch);
  private revokeReads(preserveDomainReview=false) {
    this.pendingQueries.clear();
    clearAppReadCache(this); ++this.readEpoch; ++this.invalidation;
    if(!preserveDomainReview)++this.domainReviewEpoch;
  }
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => {this.listeners.delete(listener);}; };
  private notify() { for (const listener of this.listeners) listener(); }
  private accept(snapshot: AppSnapshot, initial=false, commandReply=false) {
    if (!snapshot || snapshot.schema !== 1 || snapshot.fullApp !== true || !Number.isSafeInteger(snapshot.revision) || snapshot.revision < 0) throw new Error('The installed native app does not provide the full Lava runtime.');
    if (snapshot.revision < this.lastSnapshotRevision) return;
    // publish() emits this exact command projection before returning it. If that
    // event already restored an active frame, a navigation/query reply must not render it again.
    // Direct refreshes and blocked markers still run all lifecycle checks.
    if(commandReply&&!this.state.error&&!snapshot.presentationBlocked&&AppState.currentState==='active'
      &&this.state.snapshot?.revision===snapshot.revision)return;
    // A minimal inactive reply can cross the bridge after the full active reply
    // for that same native revision. It grants no new fields and cannot revoke
    // authority already restored by the newer lifecycle observation.
    if(snapshot.presentationBlocked&&!snapshot.presentationRevoked&&mayRetainPresentationFrame(snapshot)
      &&snapshot.revision===this.lastSnapshotRevision&&this.state.snapshot
      &&(snapshot.security?.ownerRevision===undefined||snapshot.security.ownerRevision===this.state.snapshot.security?.ownerRevision))return;
    this.traceEnabled=snapshot.tracePresentation??this.traceEnabled;
    this.tracePresentation(snapshot.presentationBlocked?"react.blockedSnapshot":"react.activeSnapshot");
    this.lastSnapshotRevision = snapshot.revision;
    this.presentationToken=snapshot.presentationToken;
    const previousOwner=(this.state.snapshot??this.state.displaySnapshot)?.security?.ownerRevision;
    if(snapshot.presentationRevoked||previousOwner!==undefined&&snapshot.security?.ownerRevision!==undefined
      &&previousOwner!==snapshot.security.ownerRevision)++this.navigationAuthorizationEpoch;
    const privacyCoverRequired=snapshot.backgroundPrivacyCoverRequired;
    if (snapshot.presentationBlocked || AppState.currentState !== 'active') {
      // Blocked/inactive events carry concealment metadata only. Confirmed off
      // preserves a trusted prior frame through active refresh as well; these
      // events cannot replace it, reopen reads, or revive a discarded frame.
      const previous=this.state.snapshot??this.state.displaySnapshot;
      const ownerChanged=snapshot.security?.ownerRevision!==undefined
        &&snapshot.security.ownerRevision!==previous?.security?.ownerRevision;
      // A system biometric prompt briefly makes UIKit inactive. Keep only an
      // already-delivered same-owner frame, inert until a fresh active snapshot.
      // Prompt completion can arrive before activation; it must not introduce
      // an empty retry screen in that gap. Real lock/background events retire it.
      const authenticationFrame=AppState.currentState!=='background'&&!snapshot.presentationRevoked
        &&!!previous?.security?.ownerRevision
        &&previous.security.ownerRevision===snapshot.security?.ownerRevision
        &&(this.retainingAuthenticationFrame||previous.authenticationInProgress===true);
      // Native composed the bootstrap fields under its own foreground/read
      // checks. JS AppState may not have caught up yet. An explicit all-off
      // bootstrap can paint immediately, without granting queries or actions.
      // Only this constructor handoff may seed a frame; later inactive events
      // still cannot create one after a privacy boundary.
      const bootstrap=initial&&!snapshot.presentationBlocked&&mayRetainPresentationFrame(snapshot);
      const displaySnapshot=bootstrap?snapshot:(authenticationFrame||!ownerChanged&&mayRetainPresentationFrame(snapshot)
        &&mayRetainPresentationFrame(previous))?previous:null;
      if(authenticationFrame&&!this.retainingAuthenticationFrame)++this.authenticationPauseEpoch;
      this.retainingAuthenticationFrame=!!displaySnapshot&&authenticationFrame;
      if(bootstrap)this.hasAcceptedPresentation=true;
      const beginsBoundary=!!previous&&!displaySnapshot&&this.hasAcceptedPresentation;
      if (this.state.snapshot || this.state.displaySnapshot&&!displaySnapshot) this.revokeReads();
      this.state={snapshot:null,displaySnapshot,error:null,privacyCoverRequired};
      if(beginsBoundary)this.hydration.beginBoundary();else this.notify();return;
    }
    const sameAuthenticationOwner=this.retainingAuthenticationFrame
      &&this.state.displaySnapshot?.security?.ownerRevision===snapshot.security?.ownerRevision
      &&!snapshot.presentationRevoked&&!snapshot.security?.unavailable;
    const beginsBoundary=!!this.state.displaySnapshot&&!mayRetainPresentationFrame(snapshot)&&!sameAuthenticationOwner;
    this.retainingAuthenticationFrame=false;
    if (this.state.displaySnapshot||this.state.snapshot && (readPrivacyScope(this.state.snapshot) !== readPrivacyScope(snapshot)
      ||this.state.snapshot.backgroundPrivacyCoverRequired!==snapshot.backgroundPrivacyCoverRequired)) {
      const previous=this.state.snapshot;
      this.revokeReads(!!previous&&!this.state.displaySnapshot
        &&domainReviewPrivacyScope(previous)===domainReviewPrivacyScope(snapshot)
        &&previous.backgroundPrivacyCoverRequired===snapshot.backgroundPrivacyCoverRequired);
    }
    this.hasAcceptedPresentation=true;
    this.state = {snapshot, displaySnapshot:null, error: null,privacyCoverRequired};
    if(mayRetainPresentationFrame(snapshot)&&this.hydration.getSnapshot().required&&!this.hydration.isInitialPresentation())this.hydration.reset();
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
          &&snapshot.presentationBlocked)void this.refresh();
      } catch (error) {this.fail(error);} }
    });
    const lifecycle = AppState.addEventListener('change', state => {
      if(state==='background')++this.navigationAuthorizationEpoch;
      if (state !== 'active') {
        const previous=this.state.snapshot??this.state.displaySnapshot;
        const authenticationFrame=state==='inactive'&&!!previous?.security?.ownerRevision
          &&!previous.security.unavailable
          &&(this.retainingAuthenticationFrame||previous.authenticationInProgress===true);
        const displaySnapshot=authenticationFrame||mayRetainPresentationFrame(previous)?previous:null;
        if(authenticationFrame&&!this.retainingAuthenticationFrame)++this.authenticationPauseEpoch;
        this.retainingAuthenticationFrame=!!displaySnapshot&&authenticationFrame;
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
    return () => {if (generation === this.generation) {++this.generation; this.connected = false;this.retainingAuthenticationFrame=false;this.pendingQueries.clear();clearAppReadCache(this);this.state={snapshot:null,displaySnapshot:null,error:null};this.hydration.reset();this.notify();} subscription.remove(); lifecycle.remove();};
  }
  private fail(error: unknown) {
    const message=error instanceof Error?error.message:String(error);
    if(this.retainingAuthenticationFrame){
      // A failed activation read must release successful pending settings and
      // expose the existing retry surface, rather than strand an inert frame.
      this.retainingAuthenticationFrame=false;this.revokeReads();
      this.state={...this.state,snapshot:null,displaySnapshot:null,error:message};
      this.hydration.beginBoundary();
    }else{this.state={...this.state,error:message};this.notify();}
  }
  private settleAuthenticationPresentation(generation:number) {
    if(!this.retainingAuthenticationFrame)return Promise.resolve();
    // A successful settings write can finish before UIKit/JS activation. Keep
    // its existing pending control until the fresh projection acknowledges it,
    // or a hard boundary retires the display. Never publish its stale response.
    return new Promise<void>(resolve=>{
      const finish=()=>{if(generation!==this.generation||!this.retainingAuthenticationFrame){unsubscribe();resolve();}};
      const unsubscribe=this.subscribe(finish);finish();
    });
  }
  private settleAuthorizedNavigation(generation:number,epoch:number,owner:string,revision:number) {
    // Face ID may complete before UIKit activation, the fresh snapshot, or its
    // committed layout. Retain this command until all three are ready. A real
    // privacy boundary cancels the intent even if the same screen later returns.
    return new Promise<void>((resolve,reject)=>{
      const finish=()=>{
        const {snapshot,error}=this.state;
        if(generation!==this.generation||epoch!==this.navigationAuthorizationEpoch
          ||snapshot&&presentationScaffoldOwnerScope(snapshot)!==owner){
          unsubscribe();reject(new Error('Authentication cancelled.'));return;
        }
        if(error){unsubscribe();reject(new Error(error));return;}
        if(AppState.currentState==='active'&&snapshot&&snapshot.revision>=revision&&!this.hydration.getSnapshot().required){unsubscribe();resolve();}
      };
      const unsubscribe=this.subscribe(finish);finish();
    });
  }
  private async discardUndeliveredDomainReview(result:unknown) {
    if(!result||typeof result!=='object'||!('standaloneReview' in result)||typeof result.standaloneReview!=='string')return;
    // Teardown carries no read authority and must not accept its response snapshot.
    try {await this.native.command(JSON.stringify({type:'domains.cancel',token:result.standaloneReview}));} catch {}
  }
  acknowledgePresentation(id:string,token:string) {
    if(!this.connected||AppState.currentState!=='active'||this.presentationToken!==token)return;
    // A painted error/retry surface is also a complete, non-private frame.
    if(!this.state.error&&(!this.state.snapshot||this.hydration.getSnapshot().required))return;
    // Readiness only. Native rechecks its token and authorization; this port
    // returns no projection and cannot execute an action.
    this.tracePresentation("react.acknowledging");
    void this.native.command(JSON.stringify({type:'presentation.ready',id,token})).catch(()=>{});
  }
  refresh():Promise<void> {
    const generation=this.generation,readEpoch=this.readEpoch;
    if(this.refreshing?.generation===generation&&this.refreshing.readEpoch===readEpoch)return this.refreshing.promise;
    const pending={generation,readEpoch,promise:Promise.resolve()};this.refreshing=pending;
    pending.promise=(async()=>{
      try {const value=await this.native.getSnapshot();if(generation===this.generation&&readEpoch===this.readEpoch)this.accept(JSON.parse(value));}
      catch(error){if(generation===this.generation&&readEpoch===this.readEpoch)this.fail(error);}
      finally {if(this.refreshing===pending)this.refreshing=undefined;}
    })();
    return pending.promise;
  }
  command<T = unknown>(command: AppCommand): Promise<T> {
    const generation = this.generation;
    const execute = async () => {
      if (!this.connected || generation !== this.generation) throw new Error('The app screen closed before this action started.');
      // Owner retirement releases native work when a concealed body unmounts.
      // It grants no new read/action authority; replies still follow epoch and
      // native snapshot fences below.
      const retiresOwner=['vpn.cancel','customEntry.dismiss','foreground.dismiss','domains.cancel','filter.close','purchase.clearMessage'].includes(command.type)
        ||command.type==='activity.visibility'&&!command.visible;
      if(!retiresOwner&&(AppState.currentState!=='active'||!this.state.snapshot))throw new Error('Read access changed.');
      // Restored native authorization permits mounted screens to prepare their
      // owner and presentation under the cover. Interactive callbacks remain
      // paused; setup cannot reject once and leave an empty retained route.
      const presentationWork=command.type.endsWith('.query')||['filter.review','filter.open','refresh',
        'discovery.seen','backup.refresh','purchase.refresh','sudoku.new','activity.visibility','onboarding.enter',
        'customEntry.enter','vpnEditor.enter','vpn.enter','foreground.enter','feedback.enter'].includes(command.type);
      if(!retiresOwner&&this.hydration.getSnapshot().required&&!presentationWork)throw new Error('Read access changed.');
      const navigationEpoch=this.navigationAuthorizationEpoch;
      const navigationOwner=command.type==='navigation.authorize'?presentationScaffoldOwnerScope(this.state.snapshot!):undefined;
      const revokesReads = command.type === 'logs.clear' || command.type.startsWith('account.');
      if (revokesReads) {this.revokeReads(); this.notify();}
      const readEpoch = this.readEpoch;
      const authenticationPauseEpoch=this.authenticationPauseEpoch;
      const domainReviewEpoch = this.domainReviewEpoch;
      const response = JSON.parse(await this.native.command(JSON.stringify(command))) as {snapshot?: AppSnapshot; result: T};
      if (generation !== this.generation) {
        if(command.type==='domains.stage')await this.discardUndeliveredDomainReview(response.result);
        throw new Error('The app screen closed while this action completed.');
      }
      // A haptic changes no app state. Native acknowledges only the effect;
      // independent snapshot events still carry actual runtime changes.
      if (command.type === 'haptic') return response.result;
      if(command.type==='domains.stage'&&domainReviewEpoch!==this.domainReviewEpoch) {
        await this.discardUndeliveredDomainReview(response.result);
        throw new Error('Read access changed.');
      }
      if (command.type.endsWith('.query') && readEpoch !== this.readEpoch) throw new Error('Read access changed.');
      // Native has revalidated this read immediately before delivery. A
      // read-only reply need not repaint the complete app or carry a snapshot.
      if(command.type.endsWith('.query')&&!response.snapshot){
        if(!Object.prototype.hasOwnProperty.call(response,'result'))throw new Error('The native app did not return its updated state.');
        return response.result;
      }
      if (!response.snapshot) throw new Error('The native app did not return its updated state.');
      if (!command.type.endsWith('.query') && !command.type.startsWith('navigation.') && !['refresh','haptic','guard.gesture','activity.visibility'].includes(command.type)) ++this.invalidation;
      const mayPublish = readEpoch === this.readEpoch || command.type==='domains.stage'&&domainReviewEpoch===this.domainReviewEpoch;
      if (revokesReads) this.revokeReads();
      // An interrupted mutation may finish, but its old presentation must not
      // repopulate a newly authenticated foreground session.
      if (mayPublish) this.accept(response.snapshot,false,command.type.startsWith('navigation.')||command.type.endsWith('.query'));
      if(command.type==='settings.set'){
        // Activation may beat the mutation reply. Read today's projection
        // instead of accepting that reply under an already-revoked read epoch.
        if(!mayPublish&&authenticationPauseEpoch!==this.authenticationPauseEpoch&&AppState.currentState==='active')await this.refresh();
        await this.settleAuthenticationPresentation(generation);
      }
      if(navigationOwner!==undefined){
        if(navigationEpoch!==this.navigationAuthorizationEpoch)throw new Error('Authentication cancelled.');
        // Never restore the pre-inactivity reply. Refresh from the current
        // native authority if JS activation already overtook authentication.
        if(!mayPublish&&AppState.currentState==='active'
          &&(!this.state.snapshot||this.state.snapshot.revision<response.snapshot.revision))await this.refresh();
        await this.settleAuthorizedNavigation(generation,navigationEpoch,navigationOwner,response.snapshot.revision);
        this.tracePresentation("react.navigationReady");
      }
      return response.result;
    };
    // A filter compile may run for seconds. Protection Stop and authenticated
    // navigation must reach the native orchestrator immediately while it runs.
    // Apply starts only after the queued review returns a token. Native rechecks
    // that token against the current draft/baseline and rejects overtaken edits.
    if(command.type.endsWith('.query')){
      // Join only simultaneous work in the same authority/source epoch. This
      // retains no settled result; reusable private data stays in native cache.
      const key=JSON.stringify([generation,this.readEpoch,this.invalidation,command]);
      const current=this.pendingQueries.get(key);if(current)return current as Promise<T>;
      const pending=execute().finally(()=>{if(this.pendingQueries.get(key)===pending)this.pendingQueries.delete(key);});
      this.pendingQueries.set(key,pending);return pending;
    }
    if (command.type.startsWith('protection.') || ['refresh','haptic','guard.gesture','activity.visibility','filter.open','filter.close','filter.refresh','filter.edit','foreground.dirty'].includes(command.type) || command.type.startsWith('navigation.') || command.type === 'filter.apply') return execute();
    const result = this.tail.then(execute, execute);
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }
}
