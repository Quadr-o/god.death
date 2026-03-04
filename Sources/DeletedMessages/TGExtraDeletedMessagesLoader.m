#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Используем NSClassFromString чтобы избежать проблем с линковкой Swift классов.
// Swift класс TGExtraDeletedMessages будет найден по runtime-имени.

@interface TGExtraDeletedMessagesLoader : NSObject
@end

@implementation TGExtraDeletedMessagesLoader

+ (void)load {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            // Swift манглирует имена: TGExtra.TGExtraDeletedMessages
            // Пробуем оба варианта на случай разных версий Swift
            Class cls = NSClassFromString(@"TGExtra.TGExtraDeletedMessages");
            if (!cls) {
                cls = NSClassFromString(@"_TtC7TGExtra22TGExtraDeletedMessages");
            }
            if (cls) {
                [cls performSelector:@selector(setup)];
            } else {
                NSLog(@"[TGExtra] ERROR: TGExtraDeletedMessages class not found");
            }
        }
    );
}

@end
