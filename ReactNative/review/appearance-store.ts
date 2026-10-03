export type AppearancePreference = 'system' | 'light' | 'dark';
export type AppearanceSnapshot = {preference: AppearancePreference; revision: number};
type WireSnapshot = {preference: string; revision: number};
export interface AppearancePort {
  getSnapshot(): Promise<WireSnapshot>;
  setPreference(preference: string): Promise<WireSnapshot>;
  onSnapshot(listener: (snapshot: WireSnapshot) => void): {remove(): void};
}
export type AppearanceViewState = {snapshot: AppearanceSnapshot | null; error: string | null};

/** Confirmed native state only. Epochs reject work from a detached UI; revisions
 * reject an older query response arriving after a newer native event. */
export class AppearanceStore {
  private value: AppearanceViewState = {snapshot: null, error: null};
  private listeners = new Set<() => void>();
  private epoch = 0;
  private connected = false;
  constructor(private readonly port: AppearancePort) {}
  getSnapshot = () => this.value;
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };
  private publish(value: AppearanceViewState) {
    this.value = value;
    for (const listener of this.listeners) listener();
  }
  private accept(incoming: WireSnapshot, epoch: number) {
    if (!this.connected || epoch !== this.epoch) return;
    const {preference, revision} = incoming;
    if (!['system', 'light', 'dark'].includes(preference) || !Number.isSafeInteger(revision) || revision < 0) {
      this.publish({...this.value, error: 'Invalid native appearance snapshot.'});
      return;
    }
    if (this.value.snapshot && revision < this.value.snapshot.revision) return;
    this.publish({snapshot: {preference: preference as AppearancePreference, revision}, error: null});
  }
  private fail(error: unknown, epoch: number) {
    if (this.connected && epoch === this.epoch) {
      this.publish({...this.value, error: error instanceof Error ? error.message : 'Native preference request failed.'});
    }
  }
  connect() {
    if (this.connected) throw new Error('AppearanceStore is already connected.');
    this.connected = true;
    const epoch = ++this.epoch;
    const subscription = this.port.onSnapshot(snapshot => this.accept(snapshot, epoch));
    void this.refresh();
    return () => {
      if (epoch !== this.epoch) return;
      this.connected = false;
      ++this.epoch;
      subscription.remove();
    };
  }
  async refresh() {
    if (!this.connected) return;
    const epoch = this.epoch;
    try { this.accept(await this.port.getSnapshot(), epoch); }
    catch (error) { this.fail(error, epoch); }
  }
  async setPreference(preference: AppearancePreference) {
    if (!this.connected) return;
    const epoch = this.epoch;
    try { this.accept(await this.port.setPreference(preference), epoch); }
    catch (error) { this.fail(error, epoch); }
  }
}
