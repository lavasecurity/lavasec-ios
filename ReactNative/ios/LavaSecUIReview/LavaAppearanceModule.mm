#import "LavaAppearanceModule.h"
#import <React/RCTAssert.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

@implementation LavaAppearanceModule {
  NSString *_observerToken;
  BOOL _invalidated;
}

+ (NSString *)moduleName { return @"NativeLavaAppearance"; }
+ (BOOL)requiresMainQueueSetup { return YES; }

// RN dispatches module invalidation on this queue and waits for it to finish.
// Detach the native observer synchronously before the TurboModule is destroyed.
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }

- (void)ensureObserver {
  RCTAssertMainQueue();
  if (_observerToken || _invalidated) return;
  // The generated dependency provider also constructs a discovery-only instance.
  // Subscribe only when a runtime calls us. A command still returns its snapshot
  // if there is no event callback yet; only event delivery needs an emitter.
  __weak LavaAppearanceModule *weakSelf = self;
  _observerToken = [[LavaAppearanceBridge shared] observe:^(NSDictionary *snapshot) {
    LavaAppearanceModule *owner = weakSelf;
    if (owner && !owner->_invalidated && owner->_eventEmitterCallback) [owner emitOnSnapshot:snapshot];
  }];
}

- (void)getSnapshot:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_invalidated) { reject(@"E_DETACHED", @"Appearance runtime is detached.", nil); return; }
    [self ensureObserver];
    resolve([[LavaAppearanceBridge shared] snapshot]);
  });
}

- (void)setPreference:(NSString *)preference resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_invalidated) { reject(@"E_DETACHED", @"Appearance runtime is detached.", nil); return; }
    [self ensureObserver];
    NSDictionary *snapshot = [[LavaAppearanceBridge shared] setPreference:preference];
    if (snapshot) resolve(snapshot);
    else reject(@"E_PREFERENCE", @"Unsupported appearance preference.", nil);
  });
}

- (void)invalidate {
  RCTAssertMainQueue();
  _invalidated = YES;
  if (_observerToken) {
    [[LavaAppearanceBridge shared] removeObserver:_observerToken];
    _observerToken = nil;
  }
  _eventEmitterCallback = nullptr;
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeLavaAppearanceSpecJSI>(params);
}
@end
