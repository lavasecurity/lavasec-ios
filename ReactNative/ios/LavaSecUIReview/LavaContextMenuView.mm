#import "LavaContextMenuView.h"
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
using namespace facebook::react;
@implementation LavaContextMenuView
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaContextMenuComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaContextMenuProps>();
    [self addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
  }
  return self;
}
- (void)emitAction:(NSString *)identifier context:(NSString *)context {
  const auto &props = *std::static_pointer_cast<const LavaContextMenuProps>(_props);
  if (!context.UTF8String || props.contextID != context.UTF8String) return;
  for (const auto &action : props.actions) {
    if (identifier.UTF8String && action.id == identifier.UTF8String) {
      auto emitter = std::static_pointer_cast<const LavaContextMenuEventEmitter>(_eventEmitter);
      if (emitter) emitter->onAction({action.id});
      return;
    }
  }
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
  const auto &props = *std::static_pointer_cast<const LavaContextMenuProps>(_props);
  if (props.actions.empty()) return nil;
  NSString *context = [NSString stringWithUTF8String:props.contextID.c_str()];
  NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
  __weak LavaContextMenuView *weakSelf = self;
  for (const auto &action : props.actions) {
    NSString *identifier = [NSString stringWithUTF8String:action.id.c_str()];
    UIImage *image = [UIImage systemImageNamed:[NSString stringWithUTF8String:action.symbol.c_str()]];
    if (action.id == "blocked") image = [image imageWithTintColor:RCTUIColorFromSharedColor(props.blockedTintColor) renderingMode:UIImageRenderingModeAlwaysOriginal];
    [items addObject:[UIAction actionWithTitle:[NSString stringWithUTF8String:action.title.c_str()]
        image:image identifier:identifier
        handler:^(__kindof UIAction *selected) { [weakSelf emitAction:identifier context:context]; }]];
  }
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil
      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) { return [UIMenu menuWithChildren:items]; }];
}
@end
