#import <Foundation/Foundation.h>

// Этот файл использует Objective-C +load — единственный надёжный способ
// запустить код при загрузке dylib в Swift/Theos проекте.
// Swift запрещает +load и +initialize, поэтому выносим их в ObjC.

// Forward declaration Swift класса
@interface TGExtraDeletedMessages : NSObject
+ (void)setup;
@end

@interface TGExtraDeletedMessagesLoader : NSObject
@end

@implementation TGExtraDeletedMessagesLoader

+ (void)load {
    // Вызываем после запуска main runloop чтобы не крашить при старте
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
        dispatch_get_main_queue(),
        ^{
            [TGExtraDeletedMessages setup];
        }
    );
}

@end
