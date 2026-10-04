#import "LavaAppModule.h"
#import <React/RCTAssert.h>
#import <React/RCTComponentViewFactory.h>
#import <ReactCodegen/RCTThirdPartyComponentsProvider.h>
#import "../ios/LavaSecUIReview/BridgingHeader.h"
#ifdef LAVA_REACT_NATIVE
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"
#endif

@interface LavaAppComponentProvider : NSObject <RCTComponentViewFactoryComponentProvider>
@end
@implementation LavaAppComponentProvider
- (NSDictionary<NSString *, Class<RCTComponentViewProtocol>> *)thirdPartyFabricComponents {
  return [RCTThirdPartyComponentsProvider thirdPartyFabricComponents];
}
@end

void LavaInstallAppComponentProvider(void) {
  RCTAssertMainQueue();
  static LavaAppComponentProvider *provider;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{ provider = [LavaAppComponentProvider new]; });
  // Every RN factory replaces Fabric's process-wide weak provider. Install our
  // process-owned lookup after each factory is created, before its root mounts.
  // Dismissing a mock host then cannot orphan components first used afterward.
  // Keep RN's lazy registration, including platform-specific generated entries.
  [RCTComponentViewFactory currentComponentViewFactory].thirdPartyFabricComponentsProvider = provider;
}

@implementation LavaAppModule {
  NSString *_observerToken;
  BOOL _invalidated;
}
+ (NSString *)moduleName { return @"NativeLavaApp"; }
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (void)getSnapshot:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
#ifdef LAVA_REACT_NATIVE
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_invalidated) { reject(@"E_DETACHED", @"App runtime detached.", nil); return; }
    [self ensureObserver];
    resolve([[LavaAppBridge shared] snapshot]);
  });
#else
  reject(@"E_FIXTURE_HOST", @"This development fixture has no app services.", nil);
#endif
}
- (void)command:(NSString *)request resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
#ifdef LAVA_REACT_NATIVE
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_invalidated) { reject(@"E_DETACHED", @"App runtime detached.", nil); return; }
    [self ensureObserver];
    [[LavaAppBridge shared] command:request completion:^(NSString *value, NSString *error) {
      if (self->_invalidated) { reject(@"E_DETACHED", @"App runtime detached.", nil); return; }
      if (error) reject(@"E_APP_COMMAND", error, nil); else resolve(value);
    }];
  });
#else
  reject(@"E_FIXTURE_HOST", @"This development fixture has no app services.", nil);
#endif
}
#ifdef LAVA_REACT_NATIVE
- (void)ensureObserver {
  RCTAssertMainQueue();
  if (_observerToken || _invalidated) return;
  __weak LavaAppModule *weakSelf = self;
  _observerToken = [[LavaAppBridge shared] observe:^(NSString *snapshot) {
    LavaAppModule *owner = weakSelf;
    if (owner && !owner->_invalidated && owner->_eventEmitterCallback) [owner emitOnSnapshot:snapshot];
  }];
}
#endif
- (void)invalidate {
  RCTAssertMainQueue();
  _invalidated = YES;
#ifdef LAVA_REACT_NATIVE
  if (_observerToken) [[LavaAppBridge shared] removeObserver:_observerToken];
  [[LavaAppBridge shared] retireShareCards];
#endif
  _observerToken = nil;
  _eventEmitterCallback = nullptr;
}
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeLavaAppSpecJSI>(params);
}
@end
