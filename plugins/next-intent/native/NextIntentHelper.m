#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *const CodexBundleID = @"com.openai.codex";
static const CGKeyCode TabKeyCode = 48;
static const CGKeyCode EscapeKeyCode = 53;
static const NSTimeInterval SuggestionLifetime = 15 * 60;

static NSString *AXString(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || value == NULL) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:NSString.class] ? object : nil;
}

static BOOL AXPoint(AXUIElementRef element, CFStringRef attribute, CGPoint *point) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || value == NULL) {
        return NO;
    }
    BOOL success = CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)value, kAXValueTypeCGPoint, point);
    CFRelease(value);
    return success;
}

static BOOL AXSize(AXUIElementRef element, CFStringRef attribute, CGSize *size) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || value == NULL) {
        return NO;
    }
    BOOL success = CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)value, kAXValueTypeCGSize, size);
    CFRelease(value);
    return success;
}

static CGFloat DesktopMaximumY(void) {
    CGFloat maximum = 1000;
    for (NSScreen *screen in NSScreen.screens) {
        maximum = MAX(maximum, NSMaxY(screen.frame));
    }
    return maximum;
}

static BOOL IsSupportedBundle(NSString *bundle) {
    return [bundle isEqualToString:CodexBundleID];
}

static AXUIElementRef CopyFocusedElement(NSString **bundleOut, AXError *errorOut) {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSString *bundle = frontmost.bundleIdentifier ?: @"none";
    if (bundleOut != NULL) *bundleOut = bundle;
    if (!IsSupportedBundle(bundle)) {
        if (errorOut != NULL) *errorOut = kAXErrorInvalidUIElement;
        return NULL;
    }

    AXUIElementRef application = AXUIElementCreateApplication(frontmost.processIdentifier);
    // Chromium/Electron may keep its accessibility tree disabled until an assistive
    // client explicitly asks for it. Enabling these application attributes makes
    // the focused composer available without requiring special browser flags.
    AXUIElementSetAttributeValue(application, CFSTR("AXManualAccessibility"), kCFBooleanTrue);
    AXUIElementSetAttributeValue(application, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFTypeRef focusedValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute, &focusedValue);
    CFRelease(application);
    if (errorOut != NULL) *errorOut = error;
    return error == kAXErrorSuccess ? (AXUIElementRef)focusedValue : NULL;
}

static NSString *FocusedElementSummary(void) {
    NSString *bundle = nil;
    AXError error = kAXErrorSuccess;
    AXUIElementRef element = CopyFocusedElement(&bundle, &error);
    if (element == NULL) {
        return [NSString stringWithFormat:@"frontmost=%@ focused=unavailable error=%d", bundle, error];
    }
    NSString *role = AXString(element, kAXRoleAttribute) ?: @"none";
    NSString *subrole = AXString(element, kAXSubroleAttribute) ?: @"none";
    NSString *placeholder = AXString(element, kAXPlaceholderValueAttribute) ?: @"none";
    NSString *value = AXString(element, kAXValueAttribute) ?: @"";
    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL hasFrame = AXPoint(element, kAXPositionAttribute, &position) && AXSize(element, kAXSizeAttribute, &size);
    CFRelease(element);
    return [NSString stringWithFormat:
        @"frontmost=%@ role=%@ subrole=%@ placeholder=%@ valueLength=%lu frame=%@",
        bundle, role, subrole, placeholder, (unsigned long)value.length,
        hasFrame ? NSStringFromRect(NSMakeRect(position.x, position.y, size.width, size.height)) : @"unavailable"];
}

static NSValue *FallbackCodexComposerFrame(void) {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (![frontmost.bundleIdentifier isEqualToString:CodexBundleID]) return nil;

    NSArray<NSDictionary *> *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));
    CGRect best = CGRectZero;
    CGFloat bestArea = 0;
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != frontmost.processIdentifier ||
            [window[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds = CGRectZero;
        if (!CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds)) continue;
        CGFloat area = bounds.size.width * bounds.size.height;
        if (area > bestArea) {
            best = bounds;
            bestArea = area;
        }
    }
    if (bestArea < 40000) return nil;
    CGFloat width = MIN(760, MAX(220, best.size.width - 48));
    return [NSValue valueWithRect:NSMakeRect(
        best.origin.x + (best.size.width - width) / 2,
        best.origin.y + best.size.height - 112,
        width,
        72)];
}

static NSValue *FocusedComposerFrame(void) {
    NSString *frontmostBundle = nil;
    AXError error = kAXErrorSuccess;
    AXUIElementRef element = CopyFocusedElement(&frontmostBundle, &error);
    if (element == NULL) {
        return [frontmostBundle isEqualToString:CodexBundleID] ? FallbackCodexComposerFrame() : nil;
    }

    pid_t pid = 0;
    NSString *focusedBundle = nil;
    if (AXUIElementGetPid(element, &pid) == kAXErrorSuccess) {
        focusedBundle = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    }
    if (focusedBundle == nil || ![focusedBundle isEqualToString:frontmostBundle]) {
        CFRelease(element);
        return nil;
    }

    NSString *role = AXString(element, kAXRoleAttribute) ?: @"";
    NSSet<NSString *> *editableRoles = [NSSet setWithObjects:
        (__bridge NSString *)kAXTextAreaRole,
        (__bridge NSString *)kAXTextFieldRole,
        (__bridge NSString *)kAXComboBoxRole,
        @"AXGroup",
        @"AXWebArea",
        nil];
    if (![editableRoles containsObject:role]) {
        CFRelease(element);
        return nil;
    }

    NSString *currentValue = AXString(element, kAXValueAttribute) ?: @"";
    NSString *placeholder = AXString(element, kAXPlaceholderValueAttribute) ?: @"";
    NSString *trimmedValue = [currentValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSSet<NSString *> *knownPlaceholders = [NSSet setWithObjects:
        @"要求后续变更",
        @"Ask anything",
        @"Ask Codex anything",
        nil];
    BOOL isEmpty = trimmedValue.length == 0 ||
        (placeholder.length > 0 && [trimmedValue isEqualToString:
            [placeholder stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]) ||
        [knownPlaceholders containsObject:trimmedValue];
    if (!isEmpty) {
        CFRelease(element);
        return nil;
    }

    CGPoint position = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL hasFrame = AXPoint(element, kAXPositionAttribute, &position) && AXSize(element, kAXSizeAttribute, &size);
    CFRelease(element);
    if (!hasFrame || size.width < 180 || size.height < 24 || position.y <= DesktopMaximumY() * 0.42) {
        return nil;
    }
    return [NSValue valueWithRect:NSMakeRect(position.x, position.y, size.width, size.height)];
}

@interface SuggestionOverlay : NSObject
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) NSTextField *label;
@property(nonatomic, assign) CGFloat compactXOffset;
@property(nonatomic, assign) CGFloat compactYOffset;
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory;
- (void)showText:(NSString *)text composerFrame:(NSRect)composerFrame;
- (void)hide;
@end

@implementation SuggestionOverlay
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory {
    self = [super init];
    if (self) {
        _compactXOffset = -2;
        _compactYOffset = 20;
        NSURL *layoutURL = [dataDirectory URLByAppendingPathComponent:@"layout.json"];
        NSData *layoutData = [NSData dataWithContentsOfURL:layoutURL];
        NSDictionary *layout = layoutData == nil ? nil :
            [NSJSONSerialization JSONObjectWithData:layoutData options:0 error:nil];
        if ([layout[@"compact_x"] isKindOfClass:NSNumber.class])
            _compactXOffset = [layout[@"compact_x"] doubleValue];
        if ([layout[@"compact_y"] isKindOfClass:NSNumber.class])
            _compactYOffset = [layout[@"compact_y"] doubleValue];

        _panel = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                           styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        _panel.level = NSStatusWindowLevel;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.opaque = NO;
        _panel.hasShadow = NO;
        _panel.ignoresMouseEvents = YES;
        _panel.hidesOnDeactivate = NO;
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;

        _label = [NSTextField labelWithString:@""];
        _label.font = [NSFont systemFontOfSize:14];
        _label.textColor = [NSColor.secondaryLabelColor colorWithAlphaComponent:0.78];
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        _panel.contentView = _label;
    }
    return self;
}

- (void)showText:(NSString *)text composerFrame:(NSRect)composerFrame {
    CGFloat width = MIN(MAX(220, composerFrame.size.width - 32), 620);
    CGFloat height = 24;
    CGFloat appKitY = DesktopMaximumY() - composerFrame.origin.y - composerFrame.size.height;
    BOOL compactComposer = composerFrame.size.height <= 60;
    NSRect frame = NSMakeRect(
        composerFrame.origin.x + (compactComposer ? self.compactXOffset : 16),
        appKitY + (compactComposer ? self.compactYOffset : MAX(10, (composerFrame.size.height - height) / 2)),
        width,
        height
    );
    self.label.stringValue = [NSString stringWithFormat:@"%@    ⇥ Tab", text];
    self.label.frame = NSMakeRect(0, 0, width, height);
    [self.panel setFrame:frame display:YES];
    [self.panel orderFrontRegardless];
}

- (void)hide {
    [self.panel orderOut:nil];
}
@end

@class NextIntentDelegate;
static CGEventRef KeyboardCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo);

@interface NextIntentDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSURL *suggestionURL;
@property(nonatomic, strong) NSURL *consumedURL;
@property(nonatomic, strong) NSURL *logURL;
@property(nonatomic, strong) SuggestionOverlay *overlay;
@property(nonatomic, copy) NSString *consumedID;
@property(nonatomic, copy) NSString *reportedID;
@property(nonatomic, assign) CFMachPortRef eventTap;
@property(nonatomic, assign) NSTimeInterval pasteRestoreDelay;
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory;
- (BOOL)handleKeyDown:(CGEventRef)event;
@end

@implementation NextIntentDelegate
- (instancetype)initWithDataDirectory:(NSURL *)dataDirectory {
    self = [super init];
    if (self) {
        _suggestionURL = [dataDirectory URLByAppendingPathComponent:@"suggestion.json"];
        _consumedURL = [dataDirectory URLByAppendingPathComponent:@"consumed.txt"];
        _logURL = [dataDirectory URLByAppendingPathComponent:@"native-helper/helper.log"];
        _overlay = [[SuggestionOverlay alloc] initWithDataDirectory:dataDirectory];
        _pasteRestoreDelay = 1.5;
        NSData *layoutData = [NSData dataWithContentsOfURL:
            [dataDirectory URLByAppendingPathComponent:@"layout.json"]];
        NSDictionary *layout = layoutData == nil ? nil :
            [NSJSONSerialization JSONObjectWithData:layoutData options:0 error:nil];
        if ([layout[@"paste_restore_delay"] isKindOfClass:NSNumber.class])
            _pasteRestoreDelay = MAX(0.5, [layout[@"paste_restore_delay"] doubleValue]);
        _reportedID = @"";
        _consumedID = [[[NSString alloc] initWithContentsOfURL:_consumedURL
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    }
    return self;
}

- (void)dealloc {
    if (_eventTap != NULL) {
        CFRelease(_eventTap);
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        [self log:@"Accessibility permission is required. Restart Codex after granting it."];
        return;
    }
    [self log:@"Accessibility permission granted."];
    [self installEventTap];
    [NSTimer scheduledTimerWithTimeInterval:0.25
                                    target:self
                                  selector:@selector(refreshOverlay)
                                  userInfo:nil
                                   repeats:YES];
    [self refreshOverlay];
}

- (void)installEventTap {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    self.eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                    kCGEventTapOptionDefault, mask, KeyboardCallback,
                                    (__bridge void *)self);
    if (self.eventTap == NULL) {
        [self log:@"Could not create a keyboard event tap; Input Monitoring may be required."];
        return;
    }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CGEventTapEnable(self.eventTap, true);
    [self log:@"Keyboard event tap installed."];
}

- (NSDictionary *)validSuggestion {
    NSData *data = [NSData dataWithContentsOfURL:self.suggestionURL];
    if (data == nil) return nil;
    NSDictionary *suggestion = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![suggestion isKindOfClass:NSDictionary.class]) return nil;
    NSString *identifier = suggestion[@"id"];
    NSString *text = suggestion[@"text"];
    NSNumber *createdAt = suggestion[@"created_at"];
    if (![identifier isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class] ||
        ![createdAt isKindOfClass:NSNumber.class] || [identifier isEqualToString:self.consumedID] ||
        NSDate.date.timeIntervalSince1970 - createdAt.doubleValue > SuggestionLifetime ||
        [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
        return nil;
    }
    return suggestion;
}

- (void)refreshOverlay {
    NSDictionary *suggestion = [self validSuggestion];
    NSValue *frame = FocusedComposerFrame();
    if (suggestion == nil || frame == nil) {
        [self.overlay hide];
        if (suggestion != nil && ![self.reportedID isEqualToString:suggestion[@"id"]]) {
            self.reportedID = suggestion[@"id"];
            [self log:[NSString stringWithFormat:
                @"Suggestion ready, but composer was not detected: %@", FocusedElementSummary()]];
        }
        return;
    }
    [self.overlay showText:suggestion[@"text"] composerFrame:frame.rectValue];
    if (![self.reportedID isEqualToString:suggestion[@"id"]]) {
        self.reportedID = suggestion[@"id"];
        [self log:@"Suggestion overlay shown; Tab is ready."];
    }
}

- (void)consume:(NSDictionary *)suggestion {
    self.consumedID = suggestion[@"id"];
    NSString *value = [self.consumedID stringByAppendingString:@"\n"];
    [value writeToURL:self.consumedURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)handleKeyDown:(CGEventRef)event {
    NSDictionary *suggestion = [self validSuggestion];
    if (suggestion == nil || FocusedComposerFrame() == nil) return NO;
    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    CGEventFlags modifiers = CGEventGetFlags(event) &
        (kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
    if (keyCode == TabKeyCode && modifiers == 0) {
        [self consume:suggestion];
        [self.overlay hide];
        [self log:@"Tab accepted the current suggestion."];
        dispatch_async(dispatch_get_main_queue(), ^{ [self typeText:suggestion[@"text"]]; });
        return YES;
    }
    if (keyCode == EscapeKeyCode || modifiers == 0) {
        [self consume:suggestion];
        [self.overlay hide];
    }
    return NO;
}

- (void)typeText:(NSString *)text {
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!IsSupportedBundle(frontmost.bundleIdentifier) ||
        FocusedComposerFrame() == nil) return;

    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSMutableArray<NSPasteboardItem *> *savedItems = [NSMutableArray array];
    for (NSPasteboardItem *item in pasteboard.pasteboardItems ?: @[]) {
        NSPasteboardItem *saved = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data != nil) [saved setData:data forType:type];
        }
        [savedItems addObject:saved];
    }
    [pasteboard clearContents];
    [pasteboard setString:text forType:NSPasteboardTypeString];
    NSInteger injectedChangeCount = pasteboard.changeCount;

    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 9, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 9, false);
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    CGEventPostToPid(frontmost.processIdentifier, down);
    CGEventPostToPid(frontmost.processIdentifier, up);
    CFRelease(down);
    CFRelease(up);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.pasteRestoreDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (pasteboard.changeCount != injectedChangeCount) return;
        [pasteboard clearContents];
        if (savedItems.count > 0) [pasteboard writeObjects:savedItems];
        [self log:@"Suggestion pasted; previous clipboard restored."];
    });
}

- (void)log:(NSString *)message {
    NSString *timestamp = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", timestamp, message];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:self.logURL.path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } else {
        [line writeToURL:self.logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
@end

static CGEventRef KeyboardCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    (void)proxy;
    if (type != kCGEventKeyDown) return event;
    NextIntentDelegate *owner = (__bridge NextIntentDelegate *)userInfo;
    return [owner handleKeyDown:event] ? NULL : event;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: NextIntentHelper <plugin-data-directory>\n");
            return 2;
        }
        NSURL *dataDirectory = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSURL *nativeDirectory = [dataDirectory URLByAppendingPathComponent:@"native-helper" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:nativeDirectory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
        NSString *pid = [NSString stringWithFormat:@"%d\n", NSProcessInfo.processInfo.processIdentifier];
        [pid writeToURL:[nativeDirectory URLByAppendingPathComponent:@"helper.pid"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];

        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NextIntentDelegate *delegate = [[NextIntentDelegate alloc]
            initWithDataDirectory:dataDirectory];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
