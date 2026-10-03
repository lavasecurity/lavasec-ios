import type {AppCommand, AppSnapshot} from './contract';
import type {AppStore} from './store';
import {AppState} from 'react-native';

// Private reusable values belong to the native encrypted cache. This adapter is
// deliberately no-store: a confirmed all-off lifecycle may retain only its
// already-painted inert values while native authority refreshes. No query,
// including sharing, may reuse that frame as a cached result.
class AppReadCache {
  peek<T>(_key: readonly unknown[]): T | undefined { return undefined; }
  read<T>(_key: readonly unknown[], read: () => Promise<T>): Promise<T> { return read(); }
  clear() {}
}
const noStore = new AppReadCache();
export function appReadCache(_app: AppStore) { return noStore; }
export function clearAppReadCache(_app: AppStore) {}
export function mayCacheRead(_command: AppCommand | null, _snapshot?: AppSnapshot): boolean { return false; }

/** Only an explicit native opt-out permits continuity of an already-painted frame. */
export function mayRetainPresentationFrame(snapshot?:AppSnapshot|null):boolean {
  return snapshot?.backgroundPrivacyCoverRequired===false;
}

/** Runtime callbacks require current foreground fields and a completed resume layout. */
export function mayInteractWithPresentation(app?:AppStore):boolean {
  // Isolated review adapters have no native snapshot owner.
  if(!app?.getSnapshot)return true;
  return AppState.currentState==='active'&&!!app.getSnapshot().snapshot&&!app.getPresentationHydration?.().required;
}

export function readPrivacyScope(snapshot: AppSnapshot): string {
  const ordered = (values?: Record<string, boolean>) => Object.entries(values ?? {}).sort(([a], [b]) => a.localeCompare(b));
  return JSON.stringify([snapshot.account?.signedIn, snapshot.account?.status, snapshot.account?.detail,
    snapshot.session?.passcode, ordered(snapshot.session?.protectedActions), ordered(snapshot.session?.logs),
    snapshot.security?.unavailable, snapshot.security?.readRevision, snapshot.security?.sourceRevision,snapshot.security?.ownerRevision,snapshot.security?.displayClearRevision]);
}

/** Painted opt-out frames ignore routine grant revocation, while data ownership and policy still bind them. */
export function readDisplayScope(snapshot:AppSnapshot):string {
  if(snapshot.security?.ownerRevision!==undefined&&snapshot.security.displayClearRevision!==undefined) {
    const ordered=(values?:Record<string,boolean>)=>Object.entries(values??{}).sort(([a],[b])=>a.localeCompare(b));
    return JSON.stringify([snapshot.security.ownerRevision,snapshot.security.displayClearRevision,
      mayRetainPresentationFrame(snapshot)?undefined:snapshot.session?.passcode,ordered(snapshot.session?.protectedActions),ordered(snapshot.session?.logs),snapshot.security.unavailable]);
  }
  return readPrivacyScope({...snapshot,security:{...snapshot.security,readRevision:undefined}});
}

/** Unsaved forms belong to an owner/privacy boundary, independent of ordinary native refresh or clear revisions. */
export function presentationOwnerScope(snapshot:AppSnapshot):string {
  const ordered=Object.entries(snapshot.session?.protectedActions??{}).sort(([a],[b])=>a.localeCompare(b));
  const owner=snapshot.security?.ownerRevision??[snapshot.account?.signedIn,snapshot.account?.status,snapshot.account?.detail,snapshot.security?.sourceRevision];
  return JSON.stringify([owner,mayRetainPresentationFrame(snapshot)?undefined:snapshot.session?.passcode,ordered,snapshot.security?.unavailable]);
}
