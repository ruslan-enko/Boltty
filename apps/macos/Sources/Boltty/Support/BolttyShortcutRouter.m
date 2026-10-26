#import "BolttyShortcutRouter.h"

static BOOL BolttyShortcutRouterSuspended = NO;

@implementation BolttyShortcutRouter

+ (void)setSuspended:(BOOL)suspended {
  BolttyShortcutRouterSuspended = suspended;
}

+ (id)installMonitor {
  return [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                               handler:^NSEvent *_Nullable(NSEvent *event) {
    if (BolttyShortcutRouterSuspended) {
      return event;
    }

    // Every chord a user can assign carries ⌘, ⌥ or ⌃ — `ShortcutBindingValidation`
    // refuses the rest. Testing only for ⌘ was right while every default had
    // one, and wrong the moment Settings let someone record ⌃⌥T: the menu never
    // saw it, the terminal ate it, and the row showed a chord that did nothing.
    //
    // Widening this costs nothing when no item matches: `performKeyEquivalent`
    // answers NO and the event carries on to the terminal, so ⌃C still
    // interrupts and ⌥← still moves by word.
    NSEventModifierFlags assignable = NSEventModifierFlagCommand
      | NSEventModifierFlagOption
      | NSEventModifierFlagControl;
    if ((event.modifierFlags & assignable) == 0) {
      return event;
    }

    NSMenu *mainMenu = NSApp.mainMenu;
    if (mainMenu != nil && [mainMenu performKeyEquivalent:event]) {
      return nil;
    }

    return event;
  }];
}

@end
