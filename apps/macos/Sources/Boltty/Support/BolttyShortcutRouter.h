#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BolttyShortcutRouter : NSObject
+ (id)installMonitor;
+ (void)setSuspended:(BOOL)suspended;
@end

NS_ASSUME_NONNULL_END
