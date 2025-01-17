//========================================================================
// GLFW 3.4 macOS - www.glfw.org
//------------------------------------------------------------------------
// Copyright (c) 2009-2019 Camilla Löwy <elmindreda@glfw.org>
//
// This software is provided 'as-is', without any express or implied
// warranty. In no event will the authors be held liable for any damages
// arising from the use of this software.
//
// Permission is granted to anyone to use this software for any purpose,
// including commercial applications, and to alter it and redistribute it
// freely, subject to the following restrictions:
//
// 1. The origin of this software must not be misrepresented; you must not
//    claim that you wrote the original software. If you use this software
//    in a product, an acknowledgment in the product documentation would
//    be appreciated but is not required.
//
// 2. Altered source versions must be plainly marked as such, and must not
//    be misrepresented as being the original software.
//
// 3. This notice may not be removed or altered from any source
//    distribution.
//
//========================================================================
// It is fine to use C99 in this file because it will not be built with VS
//========================================================================

#include "internal.h"
#include "../kitty/monotonic.h"
#include <sys/param.h> // For MAXPATHLEN
#include <pthread.h>

// Needed for _NSGetProgname
#include <crt_externs.h>

// Change to our application bundle's resources directory, if present
//
static void changeToResourcesDirectory(void)
{
    char resourcesPath[MAXPATHLEN];

    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle)
        return;

    CFURLRef resourcesURL = CFBundleCopyResourcesDirectoryURL(bundle);

    CFStringRef last = CFURLCopyLastPathComponent(resourcesURL);
    if (CFStringCompare(CFSTR("Resources"), last, 0) != kCFCompareEqualTo)
    {
        CFRelease(last);
        CFRelease(resourcesURL);
        return;
    }

    CFRelease(last);

    if (!CFURLGetFileSystemRepresentation(resourcesURL,
                                          true,
                                          (UInt8*) resourcesPath,
                                          MAXPATHLEN))
    {
        CFRelease(resourcesURL);
        return;
    }

    CFRelease(resourcesURL);

    chdir(resourcesPath);
}

// Set up the menu bar (manually)
// This is nasty, nasty stuff -- calls to undocumented semi-private APIs that
// could go away at any moment, lots of stuff that really should be
// localize(d|able), etc.  Add a nib to save us this horror.
//
static void createMenuBar(void)
{
    size_t i;
    NSString* appName = nil;
    NSDictionary* bundleInfo = [[NSBundle mainBundle] infoDictionary];
    NSString* nameKeys[] =
    {
        @"CFBundleDisplayName",
        @"CFBundleName",
        @"CFBundleExecutable",
    };

    // Try to figure out what the calling application is called

    for (i = 0;  i < sizeof(nameKeys) / sizeof(nameKeys[0]);  i++)
    {
        id name = bundleInfo[nameKeys[i]];
        if (name &&
            [name isKindOfClass:[NSString class]] &&
            ![name isEqualToString:@""])
        {
            appName = name;
            break;
        }
    }

    if (!appName)
    {
        char** progname = _NSGetProgname();
        if (progname && *progname)
            appName = @(*progname);
        else
            appName = @"GLFW Application";
    }

    NSMenu* bar = [[NSMenu alloc] init];
    [NSApp setMainMenu:bar];

    NSMenuItem* appMenuItem =
        [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenuItem setSubmenu:appMenu];

    [appMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", appName]
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenu* servicesMenu = [[NSMenu alloc] init];
    [NSApp setServicesMenu:servicesMenu];
    [[appMenu addItemWithTitle:@"Services"
                       action:NULL
                keyEquivalent:@""] setSubmenu:servicesMenu];
    [servicesMenu release];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", appName]
                       action:@selector(hide:)
                keyEquivalent:@"h"];
    [[appMenu addItemWithTitle:@"Hide Others"
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@"h"]
        setKeyEquivalentModifierMask:NSEventModifierFlagOption | NSEventModifierFlagCommand];
    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", appName]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];

    NSMenuItem* windowMenuItem =
        [bar addItemWithTitle:@"" action:NULL keyEquivalent:@""];
    [bar release];
    NSMenu* windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [NSApp setWindowsMenu:windowMenu];
    [windowMenuItem setSubmenu:windowMenu];

    [windowMenu addItemWithTitle:@"Minimize"
                          action:@selector(performMiniaturize:)
                   keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom"
                          action:@selector(performZoom:)
                   keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front"
                          action:@selector(arrangeInFront:)
                   keyEquivalent:@""];

    // TODO: Make this appear at the bottom of the menu (for consistency)
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [[windowMenu addItemWithTitle:@"Enter Full Screen"
                           action:@selector(toggleFullScreen:)
                    keyEquivalent:@"f"]
     setKeyEquivalentModifierMask:NSEventModifierFlagControl | NSEventModifierFlagCommand];

    // Prior to Snow Leopard, we need to use this oddly-named semi-private API
    // to get the application menu working properly.
    SEL setAppleMenuSelector = NSSelectorFromString(@"setAppleMenu:");
    [NSApp performSelector:setAppleMenuSelector withObject:appMenu];
}

// Retrieve Unicode data for the current keyboard layout
//
static bool updateUnicodeDataNS(void)
{
    if (_glfw.ns.inputSource)
    {
        CFRelease(_glfw.ns.inputSource);
        _glfw.ns.inputSource = NULL;
        _glfw.ns.unicodeData = nil;
    }

    for (_GLFWwindow *window = _glfw.windowListHead;  window;  window = window->next)
        window->ns.deadKeyState = 0;

    _glfw.ns.inputSource = TISCopyCurrentKeyboardLayoutInputSource();
    if (!_glfw.ns.inputSource)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to retrieve keyboard layout input source");
        return false;
    }

    _glfw.ns.unicodeData =
        TISGetInputSourceProperty(_glfw.ns.inputSource,
                                  kTISPropertyUnicodeKeyLayoutData);
    if (!_glfw.ns.unicodeData)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to retrieve keyboard layout Unicode data");
        return false;
    }

    return true;
}

// Load HIToolbox.framework and the TIS symbols we need from it
//
static bool initializeTIS(void)
{
    // This works only because Cocoa has already loaded it properly
    _glfw.ns.tis.bundle =
        CFBundleGetBundleWithIdentifier(CFSTR("com.apple.HIToolbox"));
    if (!_glfw.ns.tis.bundle)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to load HIToolbox.framework");
        return false;
    }

    CFStringRef* kPropertyUnicodeKeyLayoutData =
        CFBundleGetDataPointerForName(_glfw.ns.tis.bundle,
                                      CFSTR("kTISPropertyUnicodeKeyLayoutData"));
    *(void **)&_glfw.ns.tis.CopyCurrentKeyboardLayoutInputSource =
        CFBundleGetFunctionPointerForName(_glfw.ns.tis.bundle,
                                          CFSTR("TISCopyCurrentKeyboardLayoutInputSource"));
    *(void **)&_glfw.ns.tis.GetInputSourceProperty =
        CFBundleGetFunctionPointerForName(_glfw.ns.tis.bundle,
                                          CFSTR("TISGetInputSourceProperty"));
    *(void **)&_glfw.ns.tis.GetKbdType =
        CFBundleGetFunctionPointerForName(_glfw.ns.tis.bundle,
                                          CFSTR("LMGetKbdType"));

    if (!kPropertyUnicodeKeyLayoutData ||
        !TISCopyCurrentKeyboardLayoutInputSource ||
        !TISGetInputSourceProperty ||
        !LMGetKbdType)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to load TIS API symbols");
        return false;
    }

    _glfw.ns.tis.kPropertyUnicodeKeyLayoutData =
        *kPropertyUnicodeKeyLayoutData;

    return updateUnicodeDataNS();
}

static void
display_reconfigured(CGDirectDisplayID display UNUSED, CGDisplayChangeSummaryFlags flags, void *userInfo UNUSED)
{
    if (flags & kCGDisplayBeginConfigurationFlag) {
        return;
    }
    if (flags & kCGDisplaySetModeFlag) {
        // GPU possibly changed
    }
}

@interface GLFWHelper : NSObject
@end

@implementation GLFWHelper

- (void)selectedKeyboardInputSourceChanged:(NSObject* )object
{
    (void)object;
    updateUnicodeDataNS();
}

- (void)doNothing:(id)object
{
    (void)object;
}

@end // GLFWHelper

// Delegate for application related notifications {{{

@interface GLFWApplicationDelegate : NSObject <NSApplicationDelegate>
@end

@implementation GLFWApplicationDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    (void)sender;
    if (_glfw.callbacks.application_close) _glfw.callbacks.application_close(0);
    return NSTerminateCancel;
}

static GLFWapplicationshouldhandlereopenfun handle_reopen_callback = NULL;

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag
{
    (void)sender;
    if (!handle_reopen_callback) return YES;
    if (handle_reopen_callback(flag)) return YES;
    return NO;
}

- (void)applicationDidChangeScreenParameters:(NSNotification *) notification
{
    (void)notification;
    _GLFWwindow* window;

    for (window = _glfw.windowListHead;  window;  window = window->next)
    {
        if (window->context.client != GLFW_NO_API)
            [window->context.nsgl.object update];
    }

    _glfwPollMonitorsNS();
}

static GLFWapplicationwillfinishlaunchingfun finish_launching_callback = NULL;

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    if (_glfw.hints.init.ns.menubar)
    {
        // In case we are unbundled, make us a proper UI application
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Menu bar setup must go between sharedApplication and finishLaunching
        // in order to properly emulate the behavior of NSApplicationMain

        if ([[NSBundle mainBundle] pathForResource:@"MainMenu" ofType:@"nib"])
        {
            [[NSBundle mainBundle] loadNibNamed:@"MainMenu"
                                          owner:NSApp
                                topLevelObjects:&_glfw.ns.nibObjects];
        }
        else
            createMenuBar();
    }
    if (finish_launching_callback)
        finish_launching_callback();
}

- (BOOL)application:(NSApplication *)theApplication openFile:(NSString *)filename {
    (void)theApplication;
    if (!filename || !_glfw.ns.file_open_callback) return NO;
    const char *path = NULL;
    @try {
        path = [[NSFileManager defaultManager] fileSystemRepresentationWithPath: filename];
    } @catch(NSException *exc) {
        NSLog(@"Converting openFile filename: %@ failed with error: %@", filename, exc.reason);
        return NO;
    }
    if (!path) return NO;
    return _glfw.ns.file_open_callback(path);
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames {
    (void)sender;
    if (!_glfw.ns.file_open_callback || !filenames) return;
    for (id x in filenames) {
        NSString *filename = x;
        const char *path = NULL;
        @try {
            path = [[NSFileManager defaultManager] fileSystemRepresentationWithPath: filename];
        } @catch(NSException *exc) {
            NSLog(@"Converting openFiles filename: %@ failed with error: %@", filename, exc.reason);
        }
        if (path) _glfw.ns.file_open_callback(path);
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    [NSApp stop:nil];
    if (_glfw.ns.file_open_callback) _glfw.ns.file_open_callback(":cocoa::application launched::");

    CGDisplayRegisterReconfigurationCallback(display_reconfigured, NULL);
    _glfwCocoaPostEmptyEvent();
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    (void)aNotification;
    CGDisplayRemoveReconfigurationCallback(display_reconfigured, NULL);
}

- (void)applicationDidHide:(NSNotification *)notification
{
    (void)notification;
    int i;

    for (i = 0;  i < _glfw.monitorCount;  i++)
        _glfwRestoreVideoModeNS(_glfw.monitors[i]);
}

@end // GLFWApplicationDelegate
// }}}


@interface GLFWApplication : NSApplication
- (void)tick_callback;
- (void)render_frame_received:(id)displayIDAsID;
@end

@implementation GLFWApplication
- (void)tick_callback
{
    _glfwDispatchTickCallback();
}

- (void)render_frame_received:(id)displayIDAsID
{
    CGDirectDisplayID displayID = [(NSNumber*)displayIDAsID unsignedIntValue];
    _glfwDispatchRenderFrame(displayID);
}
@end


//////////////////////////////////////////////////////////////////////////
//////                       GLFW internal API                      //////
//////////////////////////////////////////////////////////////////////////

void* _glfwLoadLocalVulkanLoaderNS(void)
{
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle)
        return NULL;

    CFURLRef url =
        CFBundleCopyAuxiliaryExecutableURL(bundle, CFSTR("libvulkan.1.dylib"));
    if (!url)
        return NULL;

    char path[PATH_MAX];
    void* handle = NULL;

    if (CFURLGetFileSystemRepresentation(url, true, (UInt8*) path, sizeof(path) - 1))
        handle = _glfw_dlopen(path);

    CFRelease(url);
    return handle;
}


//////////////////////////////////////////////////////////////////////////
//////                       GLFW platform API                      //////
//////////////////////////////////////////////////////////////////////////

/**
 * Apple Symbolic HotKeys Ids
 * To find this symbolic hot keys indices do:
 * 1. open Terminal
 * 2. restore defaults in System Preferences > Keyboard > Shortcuts
 * 3. defaults read com.apple.symbolichotkeys > current.txt
 * 4. enable/disable given symbolic hot key in System Preferences > Keyboard > Shortcuts
 * 5. defaults read com.apple.symbolichotkeys | diff -C 5 current.txt -
 * 6. restore defaults in System Preferences > Keyboard > Shortcuts
 */
typedef enum AppleShortcutNames {
    kSHKUnknown                                 = 0,    //
    kSHKMoveFocusToTheMenuBar                   = 7,    // Ctrl, F2
    kSHKMoveFocusToTheDock                      = 8,    // Ctrl, F3
    kSHKMoveFocusToActiveOrNextWindow           = 9,    // Ctrl, F4
    kSHKMoveFocusToTheWindowToolbar             = 10,   // Ctrl, F5
    kSHKMoveFocusToTheFloatingWindow            = 11,   // Ctrl, F6
    kSHKTurnKeyboardAccessOnOrOff               = 12,   // Ctrl, F1
    kSHKChangeTheWayTabMovesFocus               = 13,   // Ctrl, F7
    kSHKTurnZoomOnOrOff                         = 15,   // Opt, Cmd, 8
    kSHKZoomIn                                  = 17,   // Opt, Cmd, =
    kSHKZoomOut                                 = 19,   // Opt, Cmd, -
    kSHKInvertColors                            = 21,   // Ctrl, Opt, Cmd, 8
    kSHKTurnImageSmoothingOnOrOff               = 23,   // Opt, Cmd, Backslash "\"
    kSHKIncreaseContrast                        = 25,   // Ctrl, Opt, Cmd, .
    kSHKDecreaseContrast                        = 26,   // Ctrl, Opt, Cmd, ,
    kSHKMoveFocusToNextWindow                   = 27,   // Cmd, `
    kSHKSavePictureOfScreenAsAFile              = 28,   // Shift, Cmd, 3
    kSHKCopyPictureOfScreenToTheClipboard       = 29,   // Ctrl, Shift, Cmd, 3
    kSHKSavePictureOfSelectedAreaAsAFile        = 30,   // Shift, Cmd, 4
    kSHKCopyPictureOfSelectedAreaToTheClipboard = 31,   // Ctrl, Shift, Cmd, 4
    kSHKMissionControl                          = 32,   // Ctrl, Arrow Up
    kSHKApplicationWindows                      = 33,   // Ctrl, Arrow Down
    kSHKShowDesktop                             = 36,   // F11
    kSHKMoveFocusToTheWindowDrawer              = 51,   // Opt, Cmd, `
    kSHKTurnDockHidingOnOrOff                   = 52,   // Opt, Cmd, D
    kSHKMoveFocusToStatusMenus                  = 57,   // Ctrl, F8
    kSHKTurnVoiceOverOnOrOff                    = 59,   // Cmd, F5
    kSHKSelectThePreviousInputSource            = 60,   // Ctrl, Space bar
    kSHKSelectNextSourceInInputMenu             = 61,   // Ctrl, Opt, Space bar
    kSHKShowDashboard                           = 62,   // F12
    kSHKShowSpotlightSearch                     = 64,   // Cmd, Space bar
    kSHKShowFinderSearchWindow                  = 65,   // Opt, Cmd, Space bar
    kSHKLookUpInDictionary                      = 70,   // Shift, Cmd, E
    kSHKHideAndShowFrontRow                     = 73,   // Cmd, Esc
    kSHKActivateSpaces                          = 75,   // F8
    kSHKMoveLeftASpace                          = 79,   // Ctrl, Arrow Left
    kSHKMoveRightASpace                         = 81,   // Ctrl, Arrow Right
    kSHKShowHelpMenu                            = 98,   // Shift, Cmd, /
    kSHKSwitchToDesktop1                        = 118,  // Ctrl, 1
    kSHKSwitchToDesktop2                        = 119,  // Ctrl, 2
    kSHKSwitchToDesktop3                        = 120,  // Ctrl, 3
    kSHKSwitchToDesktop4                        = 121,  // Ctrl, 4
    kSHKShowLaunchpad                           = 160,  //
    kSHKShowAccessibilityControls               = 162,  // Opt, Cmd, F5
    kSHKShowNotificationCenter                  = 163,  //
    kSHKTurnDoNotDisturbOnOrOff                 = 175,  //
    kSHKTurnFocusFollowingOnOrOff               = 179,  //
} AppleShortcutNames;

static NSDictionary<NSString*,NSNumber*> *global_shortcuts = nil;

static void
build_global_shortcuts_lookup(void) {
    NSMutableDictionary<NSString*, NSNumber*> *temp = [NSMutableDictionary dictionaryWithCapacity:128];  // will be autoreleased
    NSDictionary *apple_settings = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.apple.symbolichotkeys"];
    if (apple_settings) {
        NSDictionary<NSString*, id> *symbolic_hotkeys = [apple_settings objectForKey:@"AppleSymbolicHotKeys"];
        if (symbolic_hotkeys) {
            for (NSString *key in symbolic_hotkeys) {
                id obj = symbolic_hotkeys[key];
                if (![key isKindOfClass:[NSString class]] || ![obj isKindOfClass:[NSDictionary class]]) continue;
                NSInteger sc = [key integerValue];
                NSDictionary *sc_value = obj;
                id enabled = [sc_value objectForKey:@"enabled"];
                if (!enabled || ![enabled isKindOfClass:[NSNumber class]] || ![(NSNumber*)enabled boolValue]) continue;
                id v = [sc_value objectForKey:@"value"];
                if (!v || ![v isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *value = v;
                id p = [value objectForKey:@"parameters"];
                if (!p || ![p isKindOfClass:[NSArray class]] || [(NSArray*)p count] < 2) continue;
                NSArray<NSNumber*> *parameters = p;
                NSInteger ch = [parameters[0] isKindOfClass:[NSNumber class]] ? [parameters[0] integerValue] : 0xffff;
                NSInteger vk = [parameters[1] isKindOfClass:[NSNumber class]] ? [parameters[1] integerValue] : 0xffff;
                NSEventModifierFlags mods = ([parameters count] > 2 && [parameters[2] isKindOfClass:[NSNumber class]]) ? [parameters[2] unsignedIntegerValue] : 0;
                static char buf[64];
                if (ch == 0xffff) {
                    if (vk == 0xffff) continue;
                    snprintf(buf, sizeof(buf) - 1, "v:%lx:%ld", (unsigned long)mods, (long)vk);
                } else snprintf(buf, sizeof(buf) - 1, "c:%lx:%ld", (unsigned long)mods, (long)ch);
                temp[@(buf)] = @(sc);
            }
        }
    }
    global_shortcuts = [[NSDictionary dictionaryWithDictionary:temp] retain];
    /* NSLog(@"global_shortcuts: %@", global_shortcuts); */
}

static int
is_active_apple_global_shortcut(NSEvent *event) {
    // TODO: watch for settings change and rebuild global_shortcuts using key/value observing on NSUserDefaults
    if (global_shortcuts == nil) build_global_shortcuts_lookup();
    NSEventModifierFlags modifierFlags = [event modifierFlags] & (NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagCommand | NSEventModifierFlagControl);
    static char lookup_key[64];
    if ([event.charactersIgnoringModifiers length] == 1) {
        const unichar ch = [event.charactersIgnoringModifiers characterAtIndex:0];
        snprintf(lookup_key, sizeof(lookup_key) - 1, "c:%lx:%ld", (unsigned long)modifierFlags, (long)ch);
        NSNumber *sc = global_shortcuts[@(lookup_key)];
        if (sc != nil) return [sc intValue];
    }
    unsigned short vk = [event keyCode];
    if (vk != 0xffff) {
        snprintf(lookup_key, sizeof(lookup_key) - 1, "v:%lx:%ld", (unsigned long)modifierFlags, (long)vk);
        NSNumber *sc = global_shortcuts[@(lookup_key)];
        if (sc != nil) return [sc intValue];
    }
    return kSHKUnknown;
}

static bool
is_useful_apple_global_shortcut(int sc) {
    switch(sc) {
        case kSHKMoveFocusToTheMenuBar:                   // Ctrl, F2
        case kSHKMoveFocusToTheDock:                      // Ctrl, F3
        case kSHKMoveFocusToActiveOrNextWindow:           // Ctrl, F4
        case kSHKMoveFocusToTheWindowToolbar:             // Ctrl, F5
        case kSHKMoveFocusToTheFloatingWindow:            // Ctrl, F6
        /* case kSHKTurnKeyboardAccessOnOrOff:               // Ctrl, F1 */
        /* case kSHKChangeTheWayTabMovesFocus:               // Ctrl, F7 */
        /* case kSHKTurnZoomOnOrOff:                         // Opt, Cmd, 8 */
        /* case kSHKZoomIn:                                  // Opt, Cmd, = */
        /* case kSHKZoomOut:                                 // Opt, Cmd, - */
        /* case kSHKInvertColors:                            // Ctrl, Opt, Cmd, 8 */
        /* case kSHKTurnImageSmoothingOnOrOff:               // Opt, Cmd, Backslash "\" */
        /* case kSHKIncreaseContrast:                        // Ctrl, Opt, Cmd, . */
        /* case kSHKDecreaseContrast:                        // Ctrl, Opt, Cmd, , */
        case kSHKMoveFocusToNextWindow:                   // Cmd, `
        /* case kSHKSavePictureOfScreenAsAFile:              // Shift, Cmd, 3 */
        /* case kSHKCopyPictureOfScreenToTheClipboard:       // Ctrl, Shift, Cmd, 3 */
        /* case kSHKSavePictureOfSelectedAreaAsAFile:        // Shift, Cmd, 4 */
        /* case kSHKCopyPictureOfSelectedAreaToTheClipboard: // Ctrl, Shift, Cmd, 4 */
        case kSHKMissionControl:                          // Ctrl, Arrow Up
        case kSHKApplicationWindows:                      // Ctrl, Arrow Down
        case kSHKShowDesktop:                             // F11
        case kSHKMoveFocusToTheWindowDrawer:              // Opt, Cmd, `
        case kSHKTurnDockHidingOnOrOff:                   // Opt, Cmd, D
        /* case kSHKMoveFocusToStatusMenus:                  // Ctrl, F8 */
        /* case kSHKTurnVoiceOverOnOrOff:                    // Cmd, F5 */
        case kSHKSelectThePreviousInputSource:            // Ctrl, Space bar
        case kSHKSelectNextSourceInInputMenu:             // Ctrl, Opt, Space bar
        case kSHKShowDashboard:                           // F12
        case kSHKShowSpotlightSearch:                     // Cmd, Space bar
        case kSHKShowFinderSearchWindow:                  // Opt, Cmd, Space bar
        /* case kSHKLookUpInDictionary:                      // Shift, Cmd, E */
        /* case kSHKHideAndShowFrontRow:                     // Cmd, Esc */
        case kSHKActivateSpaces:                          // F8
        case kSHKMoveLeftASpace:                          // Ctrl, Arrow Left
        case kSHKMoveRightASpace:                         // Ctrl, Arrow Right
        /* case kSHKShowHelpMenu:                            // Shift, Cmd, / */
        case kSHKSwitchToDesktop1:                        // Ctrl, 1
        case kSHKSwitchToDesktop2:                        // Ctrl, 2
        case kSHKSwitchToDesktop3:                        // Ctrl, 3
        case kSHKSwitchToDesktop4:                        // Ctrl, 4
        case kSHKShowLaunchpad:                           //
        /* case kSHKShowAccessibilityControls:               // Opt, Cmd, F5 */
        /* case kSHKShowNotificationCenter:                  // */
        /* case kSHKTurnDoNotDisturbOnOrOff:                 // */
        /* case kSHKTurnFocusFollowingOnOrOff:               // */
            return true;
        default:
            return false;
    }
}

GLFWAPI GLFWapplicationshouldhandlereopenfun glfwSetApplicationShouldHandleReopen(GLFWapplicationshouldhandlereopenfun callback) {
    GLFWapplicationshouldhandlereopenfun previous = handle_reopen_callback;
    handle_reopen_callback = callback;
    return previous;
}

GLFWAPI GLFWapplicationwillfinishlaunchingfun glfwSetApplicationWillFinishLaunching(GLFWapplicationwillfinishlaunchingfun callback) {
    GLFWapplicationwillfinishlaunchingfun previous = finish_launching_callback;
    finish_launching_callback = callback;
    return previous;
}

int _glfwPlatformInit(void)
{
    @autoreleasepool {

    _glfw.ns.helper = [[GLFWHelper alloc] init];

    [NSThread detachNewThreadSelector:@selector(doNothing:)
                             toTarget:_glfw.ns.helper
                           withObject:nil];

    if (NSApp)
        _glfw.ns.finishedLaunching = true;

    [GLFWApplication sharedApplication];

    _glfw.ns.delegate = [[GLFWApplicationDelegate alloc] init];
    if (_glfw.ns.delegate == nil)
    {
        _glfwInputError(GLFW_PLATFORM_ERROR,
                        "Cocoa: Failed to create application delegate");
        return false;
    }

    [NSApp setDelegate:_glfw.ns.delegate];
    static struct {
        unsigned short virtual_key_code;
        NSTimeInterval timestamp;
    } last_keydown_shortcut_event;
    last_keydown_shortcut_event.virtual_key_code = 0xffff;

    NSEvent* (^keydown_block)(NSEvent*) = ^ NSEvent* (NSEvent* event)
    {
        debug_key("---------------- key down -------------------\n");
        debug_key("%s\n", [[event description] UTF8String]);
        // first check if there is global menu bar shortcut
        if ([[NSApp mainMenu] performKeyEquivalent:event]) {
            debug_key("keyDown triggerred global menu bar action ignoring\n");
            last_keydown_shortcut_event.virtual_key_code = [event keyCode];
            last_keydown_shortcut_event.timestamp = [event timestamp];
            return nil;
        }
        // now check if there is a useful apple shortcut
        int global_shortcut = is_active_apple_global_shortcut(event);
        if (is_useful_apple_global_shortcut(global_shortcut)) {
            debug_key("keyDown triggerred global macOS shortcut ignoring\n");
            last_keydown_shortcut_event.virtual_key_code = [event keyCode];
            last_keydown_shortcut_event.timestamp = [event timestamp];
            return event;
        }
        last_keydown_shortcut_event.virtual_key_code = 0xffff;
        NSWindow *kw = [NSApp keyWindow];
        if (kw && kw.contentView) [kw.contentView keyDown:event];
        else debug_key("keyUp ignored as no keyWindow present");
        return nil;
    };

    NSEvent* (^keyup_block)(NSEvent*) = ^ NSEvent* (NSEvent* event)
    {
        debug_key("----------------- key up --------------------\n");
        debug_key("%s\n", [[event description] UTF8String]);
        if (last_keydown_shortcut_event.virtual_key_code != 0xffff && last_keydown_shortcut_event.virtual_key_code == [event keyCode]) {
            // ignore as the corresponding key down event triggered a menu bar or macOS shortcut
            last_keydown_shortcut_event.virtual_key_code = 0xffff;
            debug_key("keyUp ignored as corresponds to previous keyDown that trigerred a shortcut\n");
            return nil;
        }
        NSWindow *kw = [NSApp keyWindow];
        if (kw && kw.contentView) [kw.contentView keyUp:event];
        else debug_key("keyUp ignored as no keyWindow present");
        return nil;
    };

    _glfw.ns.keyUpMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                              handler:keyup_block];
    _glfw.ns.keyDownMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                              handler:keydown_block];

    if (_glfw.hints.init.ns.chdir)
        changeToResourcesDirectory();

    NSDictionary* defaults = @{
        // Press and Hold prevents some keys from emitting repeated characters
        @"ApplePressAndHoldEnabled": @NO,
        // Dont generate openFile events from command line arguments
        @"NSTreatUnknownArgumentsAsOpen": @"NO",
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];

    [[NSNotificationCenter defaultCenter]
        addObserver:_glfw.ns.helper
           selector:@selector(selectedKeyboardInputSourceChanged:)
               name:NSTextInputContextKeyboardSelectionDidChangeNotification
             object:nil];

    _glfw.ns.eventSource = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!_glfw.ns.eventSource)
        return false;

    CGEventSourceSetLocalEventsSuppressionInterval(_glfw.ns.eventSource, 0.0);

    if (!initializeTIS())
        return false;

    _glfwPollMonitorsNS();
    return true;

    } // autoreleasepool
}

void _glfwPlatformTerminate(void)
{
    @autoreleasepool {

    _glfwClearDisplayLinks();

    if (_glfw.ns.inputSource)
    {
        CFRelease(_glfw.ns.inputSource);
        _glfw.ns.inputSource = NULL;
        _glfw.ns.unicodeData = nil;
    }

    if (_glfw.ns.eventSource)
    {
        CFRelease(_glfw.ns.eventSource);
        _glfw.ns.eventSource = NULL;
    }

    if (_glfw.ns.delegate)
    {
        [NSApp setDelegate:nil];
        [_glfw.ns.delegate release];
        _glfw.ns.delegate = nil;
    }

    if (_glfw.ns.helper)
    {
        [[NSNotificationCenter defaultCenter]
            removeObserver:_glfw.ns.helper
                      name:NSTextInputContextKeyboardSelectionDidChangeNotification
                    object:nil];
        [[NSNotificationCenter defaultCenter]
            removeObserver:_glfw.ns.helper];
        [_glfw.ns.helper release];
        _glfw.ns.helper = nil;
    }

    if (_glfw.ns.keyUpMonitor)
        [NSEvent removeMonitor:_glfw.ns.keyUpMonitor];
    if (_glfw.ns.keyDownMonitor)
        [NSEvent removeMonitor:_glfw.ns.keyDownMonitor];

    free(_glfw.ns.clipboardString);

    _glfwTerminateNSGL();
    if (global_shortcuts != nil) { [global_shortcuts release]; global_shortcuts = nil; }

    } // autoreleasepool
}

const char* _glfwPlatformGetVersionString(void)
{
    return _GLFW_VERSION_NUMBER " Cocoa NSGL EGL OSMesa"
#if defined(_GLFW_BUILD_DLL)
        " dynamic"
#endif
        ;
}

static GLFWtickcallback tick_callback = NULL;
static void* tick_callback_data = NULL;
static bool tick_callback_requested = false;
static pthread_t main_thread;
static NSLock *tick_lock = NULL;


void _glfwDispatchTickCallback() {
    if (tick_lock && tick_callback) {
        [tick_lock lock];
        while(tick_callback_requested) {
            tick_callback_requested = false;
            tick_callback(tick_callback_data);
        }
        [tick_lock unlock];
    }
}

static void
request_tick_callback() {
    if (!tick_callback_requested) {
        tick_callback_requested = true;
        [NSApp performSelectorOnMainThread:@selector(tick_callback) withObject:nil waitUntilDone:NO];
    }
}

void _glfwPlatformPostEmptyEvent(void)
{
    if (pthread_equal(pthread_self(), main_thread)) {
        request_tick_callback();
    } else if (tick_lock) {
        [tick_lock lock];
        request_tick_callback();
        [tick_lock unlock];
    }
}


void _glfwPlatformStopMainLoop(void) {
    [NSApp stop:nil];
    _glfwCocoaPostEmptyEvent();
}

void _glfwPlatformRunMainLoop(GLFWtickcallback callback, void* data) {
    main_thread = pthread_self();
    tick_callback = callback;
    tick_callback_data = data;
    tick_lock = [NSLock new];
    [NSApp run];
    [tick_lock release];
    tick_lock = NULL;
    tick_callback = NULL;
    tick_callback_data = NULL;
}


typedef struct {
    NSTimer *os_timer;
    unsigned long long id;
    bool repeats;
    monotonic_t interval;
    GLFWuserdatafun callback;
    void *callback_data;
    GLFWuserdatafun free_callback_data;
} Timer;

static Timer timers[128] = {{0}};
static size_t num_timers = 0;

static void
remove_timer_at(size_t idx) {
    if (idx < num_timers) {
        Timer *t = timers + idx;
        if (t->os_timer) { [t->os_timer invalidate]; t->os_timer = NULL; }
        if (t->callback_data && t->free_callback_data) { t->free_callback_data(t->id, t->callback_data); t->callback_data = NULL; }
        remove_i_from_array(timers, idx, num_timers);
    }
}

static void schedule_timer(Timer *t) {
    t->os_timer = [NSTimer scheduledTimerWithTimeInterval:monotonic_t_to_s_double(t->interval) repeats:(t->repeats ? YES: NO) block:^(NSTimer *os_timer) {
        for (size_t i = 0; i < num_timers; i++) {
            if (timers[i].os_timer == os_timer) {
                timers[i].callback(timers[i].id, timers[i].callback_data);
                if (!timers[i].repeats) remove_timer_at(i);
                break;
            }
        }
    }];
}

unsigned long long _glfwPlatformAddTimer(monotonic_t interval, bool repeats, GLFWuserdatafun callback, void *callback_data, GLFWuserdatafun free_callback) {
    static unsigned long long timer_counter = 0;
    if (num_timers >= sizeof(timers)/sizeof(timers[0]) - 1) {
        _glfwInputError(GLFW_PLATFORM_ERROR, "Too many timers added");
        return 0;
    }
    Timer *t = timers + num_timers++;
    t->id = ++timer_counter;
    t->repeats = repeats;
    t->interval = interval;
    t->callback = callback;
    t->callback_data = callback_data;
    t->free_callback_data = free_callback;
    schedule_timer(t);
    return timer_counter;
}

void _glfwPlatformRemoveTimer(unsigned long long timer_id) {
    for (size_t i = 0; i < num_timers; i++) {
        if (timers[i].id == timer_id) {
            remove_timer_at(i);
            break;
        }
    }
}

void _glfwPlatformUpdateTimer(unsigned long long timer_id, monotonic_t interval, bool enabled) {
    for (size_t i = 0; i < num_timers; i++) {
        if (timers[i].id == timer_id) {
            Timer *t = timers + i;
            if (t->os_timer) { [t->os_timer invalidate]; t->os_timer = NULL; }
            t->interval = interval;
            if (enabled) schedule_timer(t);
            break;
        }
    }
}
