#import "LavaReviewModule.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

@interface LavaReviewModule () <AVSpeechSynthesizerDelegate>
@property(nonatomic, strong) AVSpeechSynthesizer *demoSpeech;
@property(nonatomic, strong) AVSpeechUtterance *demoUtterance;
@property(nonatomic, copy) RCTPromiseResolveBlock demoCompletion;
@property(nonatomic) NSUInteger demoGeneration;
@end

@implementation LavaReviewModule
- (instancetype)init {
  if (self = [super init]) {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stopDemo) name:UIApplicationWillResignActiveNotification object:nil];
  }
  return self;
}
+ (NSString *)moduleName { return @"NativeLavaReview"; }
- (void)chooseFilterAction:(NSString *)name canSwitch:(BOOL)canSwitch canShare:(BOOL)canShare resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{ [LavaFilterChoiceBridge chooseWithName:name canSwitch:canSwitch canShare:canShare completion:^(NSString *value) { resolve(value ?: (id)kCFNull); }]; });
}
- (NSString *)getLegalNotices { return [LavaReviewReferenceContent legalNotices]; }
- (NSString *)getGuardAccents { return [LavaReviewReferenceContent guardAccents]; }
- (NSString *)getBlocklistCatalog { return [LavaReviewReferenceContent blocklistCatalog]; }
- (NSString *)getSharePreview:(NSString *)filter { return [LavaReviewReferenceContent sharePreview:filter]; }
- (void)copySharePreview:(NSString *)filter {
  dispatch_async(dispatch_get_main_queue(), ^{ UIPasteboard.generalPasteboard.string = [LavaReviewReferenceContent shareCode:filter]; });
}
- (NSString * _Nullable)normalizeDomain:(NSString *)input {
  return [LavaReviewDomainValidator normalize:input];
}
- (void)getActivityDates:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{ resolve([LavaActivityDateBridge today]); });
}
- (void)getActivityDatePreset:(NSString *)preset resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{ resolve([LavaActivityDateBridge preset:preset]); });
}
- (void)pickActivityDates:(double)start end:(double)end resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    [LavaActivityDateBridge pickWithStart:start end:end completion:^(NSDictionary *value) { resolve(value); }];
  });
}
// An exact approved caption/locale asset plays offline; all misses use installed
// public system speech. Generation ownership suppresses fallback after cancellation.
- (void)speakDemo:(NSString *)text locale:(NSString *)locale resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSUInteger generation = ++self.demoGeneration;
    [LavaBundledNarrationPlayer stop];
    [self finishDemo:NO];
    [self.demoSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    if ([LavaBundledNarrationPlayer playWithText:text locale:locale completion:^(BOOL success) {
      if (self.demoGeneration != generation) { resolve(@NO); return; }
      if (success) resolve(@YES);
      else [self speakSystemDemo:text locale:locale resolve:resolve reject:reject];
    }]) return;
    [self speakSystemDemo:text locale:locale resolve:resolve reject:reject];
  });
}
- (void)speakSystemDemo:(NSString *)text locale:(NSString *)locale resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
  NSUInteger generation = self.demoGeneration;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (generation != self.demoGeneration) { resolve(@NO); return; }
    [self finishDemo:NO];
    [self.demoSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) { resolve(@NO); return; }
    NSString *normalizedLocale = [locale stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:normalizedLocale];
    const AVSpeechSynthesisVoiceTraits excludedTraits = AVSpeechSynthesisVoiceTraitIsPersonalVoice | AVSpeechSynthesisVoiceTraitIsNoveltyVoice;
    if ((voice.voiceTraits & excludedTraits) != 0) voice = nil;
    // Public installed voice inventory; no private Siri identifiers, network
    // synthesis, Personal Voice access or voice download is requested.
    NSString *language = [normalizedLocale componentsSeparatedByString:@"-"].firstObject;
    for (AVSpeechSynthesisVoice *candidate in AVSpeechSynthesisVoice.speechVoices) {
      if ((candidate.voiceTraits & excludedTraits) != 0) continue;
      if (![[candidate.language componentsSeparatedByString:@"-"].firstObject isEqualToString:language]) continue;
      if (!voice || candidate.quality > voice.quality ||
          (candidate.quality == voice.quality && [candidate.language isEqualToString:normalizedLocale] && ![voice.language isEqualToString:normalizedLocale])) voice = candidate;
    }
    if (!voice) { resolve(@NO); return; }
#if LAVA_QA_TOOLS
    // Record public system metadata only, never the spoken content or a user's
    // Personal Voice. Quality is not a claim about audible naturalness.
    NSLog(@"[Lava Explore speech] voice=%@ language=%@ quality=%ld", voice.identifier, voice.language, (long)voice.quality);
#endif
    if (!self.demoSpeech) {
      self.demoSpeech = [[AVSpeechSynthesizer alloc] init];
      self.demoSpeech.delegate = self;
      self.demoSpeech.usesApplicationAudioSession = NO;
    }
    self.demoCompletion = resolve;
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:text];
    utterance.voice = voice;
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate;
    self.demoUtterance = utterance;
    [self.demoSpeech speakUtterance:utterance];
    // A missing system callback must never strand the visual lesson. This is
    // much longer than a scene's normal reading/speech time, and keyed to the
    // utterance so a cancelled scene cannot stop a later one.
    __weak LavaReviewModule *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      LavaReviewModule *owner = weakSelf;
      if (owner && owner.demoUtterance == utterance) {
        [owner finishDemo:NO];
        [owner.demoSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
      }
    });
  });
}
- (void)finishDemo:(BOOL)completed {
  RCTPromiseResolveBlock completion = self.demoCompletion;
  self.demoCompletion = nil;
  self.demoUtterance = nil;
  if (completion) completion(@(completed));
}
- (void)stopDemo {
  dispatch_block_t stop = ^{
    self.demoGeneration++;
    [LavaBundledNarrationPlayer stop];
    [self finishDemo:NO];
    [self.demoSpeech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
  };
  if (NSThread.isMainThread) stop(); else dispatch_async(dispatch_get_main_queue(), stop);
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
  if (utterance == self.demoUtterance) [self finishDemo:YES];
}
- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didCancelSpeechUtterance:(AVSpeechUtterance *)utterance {
  if (utterance == self.demoUtterance) [self finishDemo:NO];
}
- (void)invalidate {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [self stopDemo];
}
- (void)close {
  dispatch_async(dispatch_get_main_queue(), ^{
    // Only dismiss this isolated review runtime; no engine or production API.
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
      if (![scene isKindOfClass:UIWindowScene.class]) continue;
      for (UIWindow *window in ((UIWindowScene *)scene).windows) {
        if (window.isKeyWindow) [window.rootViewController dismissViewControllerAnimated:YES completion:nil];
      }
    }
  });
}
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params {
  return std::make_shared<facebook::react::NativeLavaReviewSpecJSI>(params);
}
@end
