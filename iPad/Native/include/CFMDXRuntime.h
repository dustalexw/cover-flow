#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CFMDXRuntime : NSObject
+ (NSString *)runtimeVersion;
- (nullable instancetype)initWithPath:(NSString *)path gpu:(BOOL)gpu cache:(NSString *)cache frequency:(NSInteger)frequency time:(NSInteger)time error:(NSError **)error;
- (nullable NSData *)predict:(NSData *)spectrum error:(NSError **)error;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
