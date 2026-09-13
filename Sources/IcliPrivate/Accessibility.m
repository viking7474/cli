#import "IcliPrivate.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// AXRuntime numeric attributes are used by XCTest/private accessibility clients
// and remain the primary path here. Older iOS releases can expose a different
// subset of the private numeric surface, so scalar values and root children
// also have string-attribute fallbacks. Keep traversal shallow on pre-iOS 15
// runtimes: deep cross-process AX crawling is substantially less robust there.
typedef CFTypeRef AXElement;
static AXElement (*createApp)(pid_t);
static int (*copyAttribute)(AXElement, CFStringRef, CFTypeRef *);
static int (*setTimeout)(AXElement, float);
static Boolean (*getAXValue)(CFTypeRef, int, void *);
static int (*hitTest)(AXElement, AXElement *, float, float);

static char *axJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? strndup(data.bytes, data.length) : NULL;
}

static void *axSymbol(void *handle, const char *name) {
    void *symbol = handle ? dlsym(handle, name) : NULL;
    return symbol ? symbol : dlsym(RTLD_DEFAULT, name);
}

static BOOL prepareAX(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ax = dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        void *accessibility = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*enable)(BOOL) = accessibility ? dlsym(accessibility, "_AXSApplicationAccessibilitySetEnabled") : NULL;
        void (*automation)(BOOL) = accessibility ? dlsym(accessibility, "_AXSSetAutomationEnabled") : NULL;
        if (enable) enable(YES);
        if (automation) automation(YES);
        if (!ax) return;

        void (*client)(uint32_t) = (void (*)(uint32_t))axSymbol(ax, "__AXSetRequestingClient");
        if (client) client(2);
        uint64_t (*override)(uint64_t) = (uint64_t (*)(uint64_t))axSymbol(ax, "_AXOverrideRequestingClientType");
        if (override) override(2);

        // Prefer the generic symbol when the runtime exports it; the underscored
        // iOS private variant remains the fallback used by the currently tested
        // environment.
        createApp = (AXElement (*)(pid_t))axSymbol(ax, "AXUIElementCreateApplication");
        if (!createApp) createApp = (AXElement (*)(pid_t))axSymbol(ax, "_AXUIElementCreateAppElementWithPid");
        copyAttribute = (int (*)(AXElement, CFStringRef, CFTypeRef *))axSymbol(ax, "AXUIElementCopyAttributeValue");
        setTimeout = (int (*)(AXElement, float))axSymbol(ax, "AXUIElementSetMessagingTimeout");
        getAXValue = (Boolean (*)(CFTypeRef, int, void *))axSymbol(ax, "AXValueGetValue");
        hitTest = (int (*)(AXElement, AXElement *, float, float))axSymbol(ax, "AXUIElementCopyElementAtPosition");
    });
    return createApp && copyAttribute && getAXValue;
}

static id attributeRef(AXElement element, CFStringRef key) {
    if (!element || !key || !copyAttribute) return nil;
    CFTypeRef value = NULL;
    int error = copyAttribute(element, key, &value);
    if (error) {
        if (value) CFRelease(value);
        return nil;
    }
    return value ? CFBridgingRelease(value) : nil;
}

static id numericAttribute(AXElement element, uint32_t key) {
    return attributeRef(element, (CFStringRef)(uintptr_t)key);
}

static id namedAttribute(AXElement element, NSString *key) {
    return key.length ? attributeRef(element, (__bridge CFStringRef)key) : nil;
}

static id attributeWithFallback(AXElement element, uint32_t numericKey, NSString *namedKey) {
    id value = numericAttribute(element, numericKey);
    return value ?: namedAttribute(element, namedKey);
}

static NSArray *rootElements(AXElement root) {
    // 3015 is the visible-elements collection used by the current runtime.
    // 5001 (children) plus named AX collections give older runtimes a safe
    // fallback without inventing version-specific numeric mappings.
    for (NSNumber *key in @[@3015, @5001]) {
        id value = numericAttribute(root, key.unsignedIntValue);
        if ([value isKindOfClass:NSArray.class] && [value count] > 0) return value;
    }
    for (NSString *key in @[@"AXVisibleChildren", @"AXChildren", @"AXElements", @"AXWindows"]) {
        id value = namedAttribute(root, key);
        if ([value isKindOfClass:NSArray.class] && [value count] > 0) return value;
    }
    return nil;
}

static NSDictionary *serializeElement(AXElement element) {
    if (setTimeout) setTimeout(element, 0.25f);

    id value = attributeWithFallback(element, 2003, @"AXFrame");
    CGRect frame = CGRectZero;
    if (!value || !getAXValue((__bridge CFTypeRef)value, 3, &frame) ||
        !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height)) return nil;

    id label = attributeWithFallback(element, 2001, @"AXLabel");
    id text = attributeWithFallback(element, 2006, @"AXValue");
    id identifier = attributeWithFallback(element, 5019, @"AXIdentifier");
    id traitsValue = attributeWithFallback(element, 2004, @"AXTraits");
    id enabledValue = namedAttribute(element, @"AXEnabled");
    id namedRoleValue = namedAttribute(element, @"AXRole");
    NSString *namedRole = [namedRoleValue isKindOfClass:NSString.class] ? namedRoleValue : nil;
    uint64_t traits = [traitsValue respondsToSelector:@selector(unsignedLongLongValue)] ? [traitsValue unsignedLongLongValue] : 0;
    BOOL enabled = [enabledValue isKindOfClass:NSNumber.class] ? [enabledValue boolValue] : ((traits & UIAccessibilityTraitNotEnabled) == 0);
    BOOL roleIsButton = namedRole.length > 0 && [namedRole rangeOfString:@"Button" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL roleIsText = namedRole.length > 0 && [namedRole rangeOfString:@"StaticText" options:NSCaseInsensitiveSearch].location != NSNotFound;
    BOOL semanticButton = (traits & UIAccessibilityTraitButton) != 0 || roleIsButton;
    BOOL semanticText = (traits & UIAccessibilityTraitStaticText) != 0 || roleIsText;
    BOOL clickable = enabled && frame.size.width > 0 && frame.size.height > 0 &&
        ((traits & (UIAccessibilityTraitButton | UIAccessibilityTraitLink | UIAccessibilityTraitAdjustable)) != 0 ||
         roleIsButton || !semanticText);
    NSString *role = semanticButton ? @"button" : (semanticText ? @"text" : @"element");

    IcliScreenMetrics metrics = icli_screen_metrics();
    CGRect screen = CGRectMake(0, 0, metrics.width, metrics.height);
    CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    id pointValue = numericAttribute(element, 2007);
    if (pointValue) getAXValue((__bridge CFTypeRef)pointValue, 1, &point);

    NSMutableDictionary *node = [@{
        @"label": [label isKindOfClass:NSString.class] ? label : @"",
        @"identifier": [identifier isKindOfClass:NSString.class] ? identifier : @"",
        @"value": [text isKindOfClass:NSString.class] || [text isKindOfClass:NSNumber.class] ? text : @"",
        @"role": role,
        @"traits": @(traits),
        @"enabled": @(enabled),
        @"clickable": @(clickable),
        @"visible": @(!CGRectIsEmpty(CGRectIntersection(frame, screen))),
        @"frame": @{
            @"x": @(frame.origin.x), @"y": @(frame.origin.y),
            @"width": @(frame.size.width), @"height": @(frame.size.height)
        },
        @"x": @(point.x), @"y": @(point.y)
    } mutableCopy];
    return node;
}

char *icli_ax_elements_json(int pid, int max_elements) {
    if (pid <= 0 || max_elements < 1 || max_elements > 2000) return axJSON(@{@"error": @"invalid AX query"});
    if (!prepareAX()) return axJSON(@{@"error": @"AX runtime unavailable"});

    AXElement root = createApp(pid);
    if (!root) return axJSON(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    NSArray *elements = rootElements(root);
    CFRelease(root);
    if (!elements) return axJSON(@{@"error": @"AX element query returned no readable collection", @"pid": @(pid)});

    NSInteger majorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSInteger effectiveMax = majorVersion < 15 ? MIN(max_elements, 50) : max_elements;
    NSMutableArray *rows = [NSMutableArray array];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5;
    BOOL truncated = elements.count > (NSUInteger)effectiveMax;
    for (id element in elements) {
        if (rows.count >= (NSUInteger)effectiveMax || NSProcessInfo.processInfo.systemUptime >= deadline) {
            truncated = YES;
            break;
        }
        NSDictionary *node = serializeElement((__bridge AXElement)element);
        if (node) [rows addObject:node];
    }

    NSMutableDictionary *result = [@{
        @"source": @"ax", @"pid": @(pid), @"elements": rows,
        @"count": @(rows.count), @"truncated": @(truncated)
    } mutableCopy];
    if (effectiveMax != max_elements) {
        result[@"safety_cap"] = @"pre_ios15";
        result[@"requested_max_elements"] = @(max_elements);
        result[@"effective_max_elements"] = @(effectiveMax);
    }
    return axJSON(result);
}

char *icli_ax_element_at_json(int pid, double x, double y) {
    if (pid <= 0 || !prepareAX() || !hitTest) return axJSON(@{@"error": @"AX hit testing unavailable"});
    AXElement root = createApp(pid), hit = NULL;
    if (!root) return axJSON(@{@"error": @"AX application unavailable"});
    if (setTimeout) setTimeout(root, 0.5f);
    int error = hitTest(root, &hit, (float)x, (float)y);
    CFRelease(root);
    if (error) {
        if (hit) CFRelease(hit);
        return axJSON(@{@"error": [NSString stringWithFormat:@"AX hit testing failed (%d)", error]});
    }
    NSDictionary *node = hit ? serializeElement(hit) : nil;
    if (hit) CFRelease(hit);
    return axJSON(@{@"source": @"ax", @"element": node ?: @{}, @"x": @(x), @"y": @(y)});
}
