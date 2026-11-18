//
//  AppDelegate.m
//  SonyHeadphonesClient
//
//  Created by Sem Visscher on 01/12/2020.
//

#import "AppDelegate.h"
#import "SonyHeadphonesClient-Swift.h"

@interface AppDelegate ()


@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    _window = [[[NSApplication sharedApplication] windows] firstObject];
    [MenuBarController install];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if (flag) {
        return NO;
    }
    else {
        // In menu-bar-only mode the app isn't active, so bring it forward with the window.
        [NSApp activateIgnoringOtherApps:YES];
        [_window makeKeyAndOrderFront:self];
        return YES;
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end
