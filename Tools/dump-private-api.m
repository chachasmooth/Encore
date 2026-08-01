// Prints the live signatures of the private CoreGraphics virtual-display classes.
//
// Understudy calls undocumented API, so its declarations are transcribed from
// the runtime rather than from a header. Run this after each major macOS release
// and compare against the interfaces in Sources/CVirtualDisplay/USVirtualDisplay.m
// to catch changes before users do.
//
//   clang -fobjc-arc -framework Foundation Tools/dump-private-api.m -o /tmp/dump && /tmp/dump

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void dumpClass(const char *name) {
    printf("\n========== %s ==========\n", name);
    Class cls = objc_getClass(name);
    if (!cls) {
        printf("  <NOT FOUND — Understudy will refuse to run on this OS>\n");
        return;
    }
    printf("  image: %s\n", class_getImageName(cls) ?: "?");

    unsigned int count = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &count);
    printf("--- properties (%u) ---\n", count);
    for (unsigned int i = 0; i < count; i++) {
        printf("  %-28s %s\n", property_getName(properties[i]),
               property_getAttributes(properties[i]));
    }
    free(properties);

    count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    printf("--- instance methods (%u) ---\n", count);
    for (unsigned int i = 0; i < count; i++) {
        printf("  -[%-46s]  %s\n", sel_getName(method_getName(methods[i])),
               method_getTypeEncoding(methods[i]) ?: "?");
    }
    free(methods);
}

int main(void) {
    @autoreleasepool {
        const char *names[] = {
            "CGVirtualDisplay",
            "CGVirtualDisplayDescriptor",
            "CGVirtualDisplayMode",
            "CGVirtualDisplaySettings",
        };
        for (size_t i = 0; i < sizeof(names) / sizeof(*names); i++) {
            dumpClass(names[i]);
        }
        printf("\nCompare against Sources/CVirtualDisplay/USVirtualDisplay.m\n");
    }
    return 0;
}
