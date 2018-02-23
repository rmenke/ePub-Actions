//
//  VImageBuffer.m
//  ImagesToEPUBAction
//
//  Created by Rob Menke on 2/22/17.
//  Copyright © 2017 Rob Menke. All rights reserved.
//

#import "VImageBuffer.h"
#include "HoughTransform.h"

@import AppKit.NSColor;
@import AppKit.NSColorSpace;
@import Accelerate.vImage;
@import simd;

#define UTILITY_QUEUE dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)

#if CGFLOAT_IS_DOUBLE
#define vector_cgfloat vector_double
typedef vector_double2 vector_cgfloat2;
typedef vector_double4 vector_cgfloat4;
#else
#define vector_cgfloat vector_float
typedef vector_float2 vector_cgfloat2;
typedef vector_float4 vector_cgfloat4;
#endif

_Static_assert(sizeof(vector_uchar16) == 16, "size incorrect");
_Static_assert(sizeof(vector_int4) == 16, "size incorrect");
_Static_assert(sizeof(vector_cgfloat2) == sizeof(NSPoint), "Incorrect sizing");

NS_ASSUME_NONNULL_BEGIN

NSString * const VImageErrorDomain = @"VImageErrorDomain";

#define TRY(...) \
    vImage_Error code = (__VA_ARGS__); \
    if (code != kvImageNoError) { \
        if (error) *error = [NSError errorWithDomain:VImageErrorDomain code:code userInfo:nil]; \
        return NO; \
    } \
    return YES

FOUNDATION_STATIC_INLINE
BOOL InitBuffer(vImage_Buffer *buf, NSUInteger height, NSUInteger width, uint32_t pixelBits, NSError **error) {
    TRY(vImageBuffer_Init(buf, height, width, pixelBits, kvImageNoFlags));
}

FOUNDATION_STATIC_INLINE
BOOL CopyBuffer(const vImage_Buffer *src, const vImage_Buffer *dst, size_t pixelBytes, NSError **error) {
    TRY(vImageCopyBuffer(src, dst, pixelBytes, kvImageNoFlags));
}

FOUNDATION_STATIC_INLINE
_Nullable CGImageRef CreateCGImageFromBuffer(vImage_Buffer *buffer, vImage_CGImageFormat *format, NSError **error) {
    vImage_Error code;

    CGImageRef image = vImageCreateCGImageFromBuffer(buffer, format, NULL, NULL, kvImageNoFlags, &code);

    if (!image) {
        if (error) *error = [NSError errorWithDomain:VImageErrorDomain code:code userInfo:nil];
    }

    return image;
}

FOUNDATION_STATIC_INLINE
BOOL ContrastStretch(const vImage_Buffer *src, const vImage_Buffer *dest, NSError **error) {
    TRY(vImageContrastStretch_Planar8(src, dest, kvImageNoFlags));
}

@implementation VImageBuffer {
    vImage_Buffer buffer;
}

+ (void)initialize {
    [NSError setUserInfoValueProviderForDomain:VImageErrorDomain provider:^id(NSError *err, NSString *userInfoKey) {
        if ([NSLocalizedDescriptionKey isEqualToString:userInfoKey]) {
            switch (err.code) {
                case kvImageNoError:
                    return @"No error";
                case kvImageRoiLargerThanInputBuffer:
                    return @"ROI larger than input buffer";
                case kvImageInvalidKernelSize:
                    return @"Invalid kernel size";
                case kvImageInvalidEdgeStyle:
                    return @"Invalid edge style";
                case kvImageInvalidOffset_X:
                    return @"Invalid offset x";
                case kvImageInvalidOffset_Y:
                    return @"Invalid offset y";
                case kvImageMemoryAllocationError:
                    return @"Memory allocation error";
                case kvImageNullPointerArgument:
                    return @"Null pointer argument";
                case kvImageInvalidParameter:
                    return @"Invalid parameter";
                case kvImageBufferSizeMismatch:
                    return @"Buffer size mismatch";
                case kvImageUnknownFlagsBit:
                    return @"Unknown flags bit";
                case kvImageInternalError:
                    return @"Internal error";
                case kvImageInvalidRowBytes:
                    return @"Invalid row bytes";
                case kvImageInvalidImageFormat:
                    return @"Invalid image format";
                case kvImageColorSyncIsAbsent:
                    return @"Color sync is absent";
                case kvImageOutOfPlaceOperationRequired:
                    return @"Out of place operation required";
                case kvImageInvalidImageObject:
                    return @"Invalid image object";
                case kvImageInvalidCVImageFormat:
                    return @"Invalid cvimage format";
                case kvImageUnsupportedConversion:
                    return @"Unsupported conversion";
                case kvImageCoreVideoIsAbsent:
                    return @"Core video is absent";
            }
        }

        return nil;
    }];
}

- (nullable instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height error:(NSError **)error {
    self = [super init];

    if (self) {
        if (!InitBuffer(&buffer, height, width, 8, error)) return nil;
    }

    return self;
}

- (nullable instancetype)initWithCIImage:(CIImage *)image error:(NSError **)error {
    if (!image) {
        if (error) *error = [NSError errorWithDomain:VImageErrorDomain code:kvImageNullPointerArgument userInfo:nil];
        return nil;
    }

    CGRect extent = image.extent;

    if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) {
        if (error) *error = [NSError errorWithDomain:VImageErrorDomain code:kvImageInvalidImageObject userInfo:nil];
        return nil;
    }

    self = [self initWithWidth:CGRectGetWidth(extent) height:CGRectGetHeight(extent) error:error];

    if (self) {
        [[CIContext context] render:image toBitmap:buffer.data rowBytes:buffer.rowBytes bounds:extent format:kCIFormatR8 colorSpace:NULL];
    }

    return self;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    NSError * __autoreleasing error;

    VImageBuffer *copy = [[VImageBuffer allocWithZone:zone] initWithWidth:buffer.width height:buffer.height error:&error];
    if (!copy || !CopyBuffer(&buffer, &(copy->buffer), 1, &error)) {
        @throw [NSException exceptionWithName:NSGenericException reason:error.localizedDescription userInfo:@{NSUnderlyingErrorKey: error}];
    }

    return copy;
}

- (nullable NSArray<NSArray<NSNumber *> *> *)findSegmentsWithParameters:(NSDictionary *)parameters error:(NSError **)error {
    CFErrorRef cfError = NULL;

    NSArray<NSArray<NSNumber *> *> *segments = CFBridgingRelease(CreateSegmentsFromImage(&buffer, (__bridge CFDictionaryRef)(parameters), error ? &cfError : NULL));

    if (!segments && error) *error = CFBridgingRelease(cfError);

    return segments;
}

- (nullable NSArray<NSValue *> *)findRegionsAndReturnError:(NSError **)error {
    return @[]; // TODO: Implement
}

- (nullable VImageBuffer *)normalizeContrastAndReturnError:(NSError **)error {
    VImageBuffer *result = [[VImageBuffer alloc] initWithWidth:buffer.width height:buffer.height error:error];
    if (!result) return nil;

    if (!ContrastStretch(&buffer, &(result->buffer), error)) return nil;

    return result;
}

- (nullable CGImageRef)copyCGImageAndReturnError:(NSError **)error {
    NS_VALID_UNTIL_END_OF_SCOPE NSColorSpace *grayColorSpace = [NSColorSpace genericGrayColorSpace];

    vImage_CGImageFormat format = {
        8, 8, grayColorSpace.CGColorSpace, kCGBitmapByteOrderDefault
    };

    return CreateCGImageFromBuffer(&buffer, &format, error);
}

- (void)dealloc {
    free(buffer.data);
}

- (void *)data {
    return buffer.data;
}

- (NSUInteger)width {
    return buffer.width;
}

- (NSUInteger)height {
    return buffer.height;
}

- (NSUInteger)bytesPerRow {
    return buffer.rowBytes;
}

@end

NS_ASSUME_NONNULL_END
