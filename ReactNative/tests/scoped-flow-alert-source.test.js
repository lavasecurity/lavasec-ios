import {readFileSync} from 'node:fs';
import {join} from 'node:path';

const source=readFileSync(join(__dirname,'../native-app/LavaAppFlowAlerts.swift'),'utf8');

test('migrated flow dialogs reuse the original native SwiftUI system alert and semantic tint',()=>{
  // iOS 27's direct UIAlertController paints nonpreferred actions black even
  // with the correct UIView tint. The original SwiftUI primitive retains ink.
  expect(source).toContain('Color.clear.lavaConfirmationAlert { host in');
  expect(source).toContain('host.alert(title, isPresented: model.presentation)');
  expect(source).toContain('.tint(LavaStyle.safeGreen)');
  expect(source).toContain('Button(button["title"] ?? "", role: role)');
  expect(source).toContain('button["role"] == "destructive" ? .destructive : button["role"] == "cancel" ? .cancel : nil');
  expect(source).toContain('.keyboardShortcut(.defaultAction)');
  expect(source).not.toContain('UIAlertController(title:');
  expect(source).not.toContain('setValue(');
  // UIKit reserves the system alert's own delegate (the previous actual crash).
  expect(source).not.toMatch(/presentationController\??\.delegate\s*=/);
  expect(source).not.toContain('UIAdaptivePresentationControllerDelegate');
});

test('the clear exact-owned host keeps the RN flow mounted and preserves native appearance',()=>{
  expect(source).toContain('controller.modalPresentationStyle = .overFullScreen');
  expect(source).toContain('controller.view.backgroundColor = .clear');
  expect(source).toContain('.preferredColorScheme(bridge.model.customization.preferredColorScheme)');
  expect(source).toContain('.lavaTextSizeOverride(bridge.model.customization.textSizeOverride)');
  expect(source).toContain('controller.traitOverrides.preferredContentSizeCategory = bridge.preferredContentSize');
  expect(source).toMatch(/presenter\.present\(controller, animated: false\)[\s\S]*?self\.model\.isPresented = true/);
  expect(source).toContain('self.controller.presentedViewController == nil');
  expect(source).not.toContain('presenter.dismiss(');
});

test('privacy can revoke a selection until the host actually dismisses and completes once',()=>{
  expect(source).toContain('UIApplication.willResignActiveNotification');
  expect(source).toContain('UIApplication.protectedDataWillBecomeUnavailableNotification');
  expect(source).toContain('private func revalidate() { if !admitted() { cancel() } }');
  expect(source).toContain('cancelled = true; selection = nil');
  expect(source).toContain('guard completion != nil, !resolving else { return }');
  expect(source).toContain('guard owner.presentedViewController === controller else { return }');
  expect(source).toMatch(/owner\.dismiss\(animated: animated\)[\s\S]*?finishIfDetached\(\)/);
  expect(source).toContain('guard controller.presentingViewController == nil, controller.viewIfLoaded?.window == nil else { return }');
  expect(source).toContain('let value = !cancelled && admitted() ? selection : nil');
  expect(source).toContain('let callback = completion; completion = nil');
  expect(source).toContain('guard flowAlertLifetime.mayBegin(ticket) else { return NSNull() }');
  expect(source).toContain('guard flowAlertLifetime.finish(ticket), admitted() else { return NSNull() }');
});

test('replacement waits for exact host detachment and revalidates the newest reservation before locating a presenter',()=>{
  const command=source.slice(source.indexOf('func flowAlertCommand('),source.indexOf('private func flowAlertAdmission('));
  const reserved=command.indexOf('guard flowAlertLifetime.begin(ticket)');
  const detached=command.indexOf('await previous.cancelAndWaitForDetachment()');
  const runtime=command.indexOf('try requireCurrentRuntime()',detached);
  const admitted=command.indexOf('flowAlertLifetime.current == ticket, admitted()',runtime);
  const presenter=command.indexOf('let root = UIApplication.shared.connectedScenes',admitted);
  const presented=command.indexOf('dialog.present(from: presenter)',presenter);
  expect(reserved).toBeGreaterThanOrEqual(0);
  expect(detached).toBeGreaterThan(reserved);expect(runtime).toBeGreaterThan(detached);
  expect(admitted).toBeGreaterThan(runtime);expect(presenter).toBeGreaterThan(admitted);expect(presented).toBeGreaterThan(presenter);
  expect(command).toContain('defer { flowAlertLifetime.cancel(ticket) }');
  const retirement=source.slice(source.indexOf('@objc func retireFlowAlert()'),source.indexOf('func flowAlertCommand('));
  expect(retirement).toContain('flowAlertLifetime.current');
  expect(retirement).not.toContain('flowAlert = nil');
});
