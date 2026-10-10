import {PresentationHydration} from '../app/presentation-hydration';

test('cold launch needs no hydration cover and a query-free warm resume releases after layout',async()=>{
  const changed=jest.fn(),gate=new PresentationHydration(changed);
  expect(gate.getSnapshot().required).toBe(false);
  gate.beginBoundary();expect(gate.getSnapshot().required).toBe(true);
  await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.completeLayout(gate.getSnapshot().epoch);
  expect(gate.getSnapshot().required).toBe(true);
  await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);expect(changed).toHaveBeenCalledTimes(2);
});

test('all focused reads must settle before a completed resume layout becomes visible',async()=>{
  const gate=new PresentationHydration(()=>{});gate.beginBoundary();
  const first=gate.registerRead(),second=gate.registerRead();gate.completeLayout(gate.getSnapshot().epoch);
  gate.settleRead(first);await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.settleRead(second);await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});

test('navigation and scope replacement register before the retirement microtask can reveal content',async()=>{
  const gate=new PresentationHydration(()=>{});gate.beginBoundary();
  const old=gate.registerRead();gate.completeLayout(gate.getSnapshot().epoch);gate.settleRead(old);
  const replacement=gate.registerRead();await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.settleRead(replacement);await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});

test('a later privacy boundary rejects old read and layout completions',async()=>{
  const gate=new PresentationHydration(()=>{});gate.beginBoundary();
  const epoch=gate.getSnapshot().epoch,old=gate.registerRead();gate.completeLayout(epoch);
  gate.beginBoundary();const fresh=gate.registerRead();
  gate.settleRead(old);gate.completeLayout(epoch);await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.settleRead(fresh);await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.completeLayout(gate.getSnapshot().epoch);await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});

test('retiring a blurred read cannot wait forever and reset cancels the covered session',async()=>{
  const gate=new PresentationHydration(()=>{});gate.beginBoundary();
  const read=gate.registerRead();gate.completeLayout(gate.getSnapshot().epoch);
  gate.settleRead(read);await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
  gate.beginBoundary();gate.registerRead();gate.reset();await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});

test('cold admission waits for the committed viewport and reads without scheduling a second frame',async()=>{
  const gate=new PresentationHydration(()=>{});
  gate.beginInitialPresentation();const read=gate.registerRead();
  gate.settleRead(read);await Promise.resolve();
  expect(gate.getSnapshot().required).toBe(true);
  gate.completeLayout(gate.getSnapshot().epoch);
  expect(gate.getSnapshot().required).toBe(true);
  await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});

test('a queued release cannot admit a later boundary or newly registered read',async()=>{
  const gate=new PresentationHydration(()=>{});
  gate.beginInitialPresentation();gate.completeLayout(gate.getSnapshot().epoch);
  gate.beginBoundary();const read=gate.registerRead();
  await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.completeLayout(gate.getSnapshot().epoch);gate.settleRead(read);
  const replacement=gate.registerRead();
  await Promise.resolve();expect(gate.getSnapshot().required).toBe(true);
  gate.settleRead(replacement);await Promise.resolve();expect(gate.getSnapshot().required).toBe(false);
});
