#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CFMDXRuntime : NSObject
+ (NSString *)runtimeVersion;
- (nullable instancetype)initWithPath:(NSString *)path gpu:(BOOL)gpu cache:(NSString *)cache frequency:(NSInteger)frequency time:(NSInteger)time error:(NSError **)error;
- (nullable NSData *)predict:(NSData *)spectrum error:(NSError **)error;
- (void)cancel;
@end

/// HTDemucs exported to ONNX: one stereo waveform segment in (`mix`, [1, 2, N]),
/// every stem out ([1, S, 2, N], S = 4 or 6). Runs on the CPU with graph
/// optimizations off: ONNX Runtime's optimizer needs over 6 GB to rewrite this
/// 25,000-node graph, while the unoptimized session stays under 1 GB.
@interface CFDemucsRuntime : NSObject
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error;
@property(nonatomic, readonly) NSInteger stemCount;
@property(nonatomic, readonly) NSInteger segment;
/// `mix` holds 2 × segment floats, channel-major. Returns stemCount × 2 × segment floats.
- (nullable NSData *)predict:(NSData *)mix error:(NSError **)error;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
