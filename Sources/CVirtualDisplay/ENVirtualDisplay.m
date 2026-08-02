#import "ENVirtualDisplay.h"
#import <objc/runtime.h>

NSErrorDomain const ENVirtualDisplayErrorDomain = @"com.encore.virtualdisplay";

#pragma mark - Private CoreGraphics API

// These classes ship inside CoreGraphics but are absent from the public SDK, so
// the linker cannot see them. They are declared here purely to give the
// compiler type information; every instance is created through objc_getClass so
// no _OBJC_CLASS_$_ symbol is ever emitted and the binary links cleanly.
//
// Signatures were read off the live Objective-C runtime rather than copied from
// a header, so they describe what the OS actually exposes. Re-verify with
// Tools/dump-private-api.m after each major macOS release.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, copy) void (^terminationHandler)(id _Nullable, id _Nullable);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray *modes;
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic) uint32_t rotation;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (readonly) CGDirectDisplayID displayID;
@end

#pragma mark - Helpers

/// Assumed pixel density used to derive a plausible physical size. macOS shows
/// this in System Settings and factors it into scaled-resolution options; it has
/// no effect on the rendered image.
static const double kAssumedPointsPerInch = 110.0;
static const double kMillimetresPerInch = 25.4;

static NSError *ENMakeError(ENVirtualDisplayError code, NSString *description) {
    return [NSError errorWithDomain:ENVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

#pragma mark - ENVirtualDisplay

@implementation ENVirtualDisplay {
    id _display;                  // CGVirtualDisplay
    dispatch_queue_t _queue;
    BOOL _invalidated;
}

+ (BOOL)isSupported {
    static const char *required[] = {
        "CGVirtualDisplay", "CGVirtualDisplayDescriptor",
        "CGVirtualDisplayMode", "CGVirtualDisplaySettings",
    };
    for (size_t i = 0; i < sizeof(required) / sizeof(*required); i++) {
        if (objc_getClass(required[i]) == nil) return NO;
    }
    return YES;
}

- (nullable instancetype)initWithName:(NSString *)name
                          widthPoints:(uint32_t)widthPoints
                         heightPoints:(uint32_t)heightPoints
                          scaleFactor:(uint32_t)scaleFactor
                          refreshRate:(double)refreshRate
                                error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    if (widthPoints == 0 || heightPoints == 0 || refreshRate <= 0) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorSettingsRejected,
                                        @"Resolution and refresh rate must be greater than zero.");
        return nil;
    }
    if (scaleFactor != 1 && scaleFactor != 2) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorSettingsRejected,
                                        @"Scale factor must be 1 or 2.");
        return nil;
    }

    Class displayClass = objc_getClass("CGVirtualDisplay");
    Class descriptorClass = objc_getClass("CGVirtualDisplayDescriptor");
    Class modeClass = objc_getClass("CGVirtualDisplayMode");
    Class settingsClass = objc_getClass("CGVirtualDisplaySettings");

    if (!displayClass || !descriptorClass || !modeClass || !settingsClass) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorUnsupportedOS,
                                        @"This version of macOS does not provide the virtual display API "
                                        @"Encore relies on.");
        return nil;
    }

    _pointWidth = widthPoints;
    _pointHeight = heightPoints;
    _pixelWidth = widthPoints * scaleFactor;
    _pixelHeight = heightPoints * scaleFactor;

    _queue = dispatch_queue_create("com.encore.virtualdisplay", DISPATCH_QUEUE_SERIAL);

    // --- Descriptor: the display's identity and physical characteristics. ---
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    if (!descriptor) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorAllocationFailed,
                                        @"Could not allocate a virtual display descriptor.");
        return nil;
    }

    SEL requiredDescriptorSelectors[] = {
        @selector(setName:), @selector(setMaxPixelsWide:), @selector(setMaxPixelsHigh:),
        @selector(setSizeInMillimeters:), @selector(setProductID:), @selector(setVendorID:),
        @selector(setSerialNum:), @selector(setDispatchQueue:),
    };
    for (size_t i = 0; i < sizeof(requiredDescriptorSelectors) / sizeof(SEL); i++) {
        if (![descriptor respondsToSelector:requiredDescriptorSelectors[i]]) {
            if (error) *error = ENMakeError(ENVirtualDisplayErrorIncompatibleAPI,
                                            [NSString stringWithFormat:
                                             @"macOS changed the virtual display API: descriptor no longer "
                                             @"responds to -%s.", sel_getName(requiredDescriptorSelectors[i])]);
            return nil;
        }
    }

    descriptor.name = name;
    descriptor.maxPixelsWide = _pixelWidth;
    descriptor.maxPixelsHigh = _pixelHeight;
    descriptor.sizeInMillimeters = CGSizeMake(
        widthPoints / kAssumedPointsPerInch * kMillimetresPerInch,
        heightPoints / kAssumedPointsPerInch * kMillimetresPerInch);
    // Arbitrary but stable identifiers. Keeping them fixed means macOS
    // remembers window positions and arrangement across sessions.
    descriptor.vendorID = 0x554E;   // "UN"
    descriptor.productID = 0x4453;  // "DS"
    descriptor.serialNum = 0x0001;
    [descriptor setDispatchQueue:_queue];

    __weak typeof(self) weakSelf = self;
    descriptor.terminationHandler = ^(id _Nullable sender, id _Nullable info) {
        (void)sender; (void)info;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_invalidated) return;
            strongSelf->_invalidated = YES;
            if (strongSelf.terminationHandler) strongSelf.terminationHandler();
        });
    };

    // --- Create the display. ---
    _display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!_display) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorAllocationFailed,
                                        @"macOS refused to create the virtual display.");
        return nil;
    }

    // --- Settings: the mode list macOS will offer for this display. ---
    // With hiDPI enabled, modes are expressed in points and macOS renders them
    // at twice the size in pixels. Without it, modes are literal pixel sizes.
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    if (!settings || ![settings respondsToSelector:@selector(setModes:)]
                  || ![settings respondsToSelector:@selector(setHiDPI:)]) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorIncompatibleAPI,
                                        @"macOS changed the virtual display settings API.");
        return nil;
    }

    BOOL wantsHiDPI = (scaleFactor == 2);
    uint32_t modeWidth = wantsHiDPI ? widthPoints : _pixelWidth;
    uint32_t modeHeight = wantsHiDPI ? heightPoints : _pixelHeight;

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:modeWidth
                                                          height:modeHeight
                                                     refreshRate:refreshRate];
    if (!mode) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorAllocationFailed,
                                        @"Could not allocate a virtual display mode.");
        return nil;
    }

    settings.modes = @[mode];
    settings.hiDPI = wantsHiDPI ? 1 : 0;
    settings.rotation = 0;

    if (![_display applySettings:settings]) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorSettingsRejected,
                                        [NSString stringWithFormat:
                                         @"macOS rejected a %ux%u @ %.0fHz display.",
                                         modeWidth, modeHeight, refreshRate]);
        _display = nil;
        return nil;
    }

    // WindowServer assigns the display ID asynchronously, so poll briefly.
    CGDirectDisplayID resolvedID = 0;
    for (int attempt = 0; attempt < 100 && resolvedID == 0; attempt++) {
        resolvedID = [(CGVirtualDisplay *)_display displayID];
        if (resolvedID != 0) break;
        [NSThread sleepForTimeInterval:0.02];
    }
    if (resolvedID == 0) {
        if (error) *error = ENMakeError(ENVirtualDisplayErrorNoDisplayID,
                                        @"The virtual display was created but macOS never assigned it an ID.");
        _display = nil;
        return nil;
    }
    _displayID = resolvedID;

    return self;
}

- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    // Releasing the CGVirtualDisplay is what actually unregisters the display.
    _display = nil;
    _displayID = 0;
}

- (void)dealloc {
    [self invalidate];
}

@end
