#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const USVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(USVirtualDisplayErrorDomain, USVirtualDisplayError) {
    /// The private CoreGraphics classes were not found at runtime. Expected if
    /// Apple removes or renames them in a future macOS release.
    USVirtualDisplayErrorUnsupportedOS = 1,
    /// The classes were found but did not respond to the selectors Understudy needs,
    /// meaning Apple changed the API shape.
    USVirtualDisplayErrorIncompatibleAPI = 2,
    /// Object allocation failed.
    USVirtualDisplayErrorAllocationFailed = 3,
    /// applySettings: returned NO, so macOS rejected the requested mode.
    USVirtualDisplayErrorSettingsRejected = 4,
    /// The display was created but never got a valid display ID from WindowServer.
    USVirtualDisplayErrorNoDisplayID = 5,
};

/// A virtual monitor that macOS treats as real hardware.
///
/// While an instance is alive, the system reports an extra display: windows can
/// be moved onto it, the cursor crosses onto it, and it appears in System
/// Settings. Releasing the instance (or calling `invalidate`) removes it.
///
/// This is built on private, undocumented Apple API. There is no public macOS
/// equivalent. Every private call is isolated inside this class so that a break
/// in a future macOS release surfaces as a clean error rather than a crash.
@interface USVirtualDisplay : NSObject

/// Whether the underlying private API is present on this system. Check before
/// attempting to create a display so failure can be reported gracefully.
@property (class, readonly) BOOL isSupported;

/// Creates and registers a virtual display.
///
/// @param name          Name shown in System Settings > Displays.
/// @param widthPoints   Logical width. This is the resolution the user "sees".
/// @param heightPoints  Logical height.
/// @param scaleFactor   1 for standard, 2 for Retina/HiDPI. With 2, the backing
///                      pixel buffer is twice the point size in each dimension.
/// @param refreshRate   Refresh rate in Hz, e.g. 60.
- (nullable instancetype)initWithName:(NSString *)name
                          widthPoints:(uint32_t)widthPoints
                         heightPoints:(uint32_t)heightPoints
                          scaleFactor:(uint32_t)scaleFactor
                          refreshRate:(double)refreshRate
                                error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// CoreGraphics display ID, used to target this screen for capture.
@property (readonly) CGDirectDisplayID displayID;

/// Backing resolution in real pixels (point size multiplied by scale factor).
@property (readonly) uint32_t pixelWidth;
@property (readonly) uint32_t pixelHeight;

/// Logical resolution in points.
@property (readonly) uint32_t pointWidth;
@property (readonly) uint32_t pointHeight;

/// Whether the display is still registered with the window server.
@property (readonly, getter=isValid) BOOL valid;

/// Called on the main queue if macOS tears the display down on its own, for
/// example during a graphics driver reset.
@property (nullable, copy) void (^terminationHandler)(void);

/// Removes the display. Idempotent; also invoked automatically on dealloc.
- (void)invalidate;

@end

/// Reads a display's true backing-store size straight from CoreGraphics.
///
/// Exists because calling CGDisplayCopyDisplayMode through Swift's importer
/// returns nil for freshly created virtual displays, while the identical call
/// from Objective-C succeeds. Returns NO if the mode could not be read.
BOOL USReadDisplayPixelSize(CGDirectDisplayID displayID,
                            uint32_t *_Nullable outPixelWidth,
                            uint32_t *_Nullable outPixelHeight);

NS_ASSUME_NONNULL_END
