import {AppearanceStore, type AppearancePort} from '../review/appearance-store';

const deferred = <T,>() => {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; });
  return {promise, resolve};
};

test('subscribes before reading and rejects an older read arriving after a native change', async () => {
  const read = deferred<{preference: string; revision: number}>();
  let emit!: (value: {preference: string; revision: number}) => void;
  const remove = jest.fn();
  const port: AppearancePort = {
    onSnapshot: listener => { emit = listener; return {remove}; },
    getSnapshot: jest.fn(() => { expect(emit).toBeDefined(); return read.promise; }),
    setPreference: jest.fn(),
  };
  const store = new AppearanceStore(port);
  const disconnect = store.connect();
  emit({preference: 'dark', revision: 2});
  read.resolve({preference: 'light', revision: 1});
  await read.promise;
  expect(store.getSnapshot().snapshot).toEqual({preference: 'dark', revision: 2});
  disconnect();
  expect(remove).toHaveBeenCalledTimes(1);
});

test('waits for native confirmation and detachment does not replay an accepted command', async () => {
  const command = deferred<{preference: string; revision: number}>();
  const port: AppearancePort = {
    onSnapshot: () => ({remove: jest.fn()}),
    getSnapshot: jest.fn().mockResolvedValue({preference: 'system', revision: 0}),
    setPreference: jest.fn(() => command.promise),
  };
  const store = new AppearanceStore(port);
  const disconnect = store.connect();
  await store.refresh();
  const pending = store.setPreference('dark');
  expect(store.getSnapshot().snapshot?.preference).toBe('system');
  disconnect();
  command.resolve({preference: 'dark', revision: 1});
  await pending;
  expect(store.getSnapshot().snapshot?.preference).toBe('system');
  (port.getSnapshot as jest.Mock).mockResolvedValue({preference: 'dark', revision: 1});
  const close = store.connect();
  await store.refresh();
  expect(store.getSnapshot().snapshot?.preference).toBe('dark');
  expect(port.setPreference).toHaveBeenCalledTimes(1);
  close();
});

test('foreground refresh reads authority and a rejected command retains confirmed state', async () => {
  const port: AppearancePort = {
    onSnapshot: () => ({remove: jest.fn()}),
    getSnapshot: jest.fn().mockResolvedValue({preference: 'light', revision: 1}),
    setPreference: jest.fn().mockRejectedValue(new Error('Unavailable')),
  };
  const store = new AppearanceStore(port);
  const close = store.connect();
  await store.refresh();
  await store.setPreference('dark');
  expect(store.getSnapshot()).toEqual({snapshot: {preference: 'light', revision: 1}, error: 'Unavailable'});
  (port.getSnapshot as jest.Mock).mockResolvedValue({preference: 'dark', revision: 2});
  await store.refresh();
  expect(store.getSnapshot()).toEqual({snapshot: {preference: 'dark', revision: 2}, error: null});
  close();
});
