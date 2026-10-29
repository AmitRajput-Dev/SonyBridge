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
// A menu-bar app (LSUIElement): no Dock icon, and the window only opens from the menu-bar item.
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [MenuBarController install];
}

// Launching the app again while it's running (e.g. from Finder) opens the window.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if (flag) {
        return NO;
    }
    else {
        [MenuBarController openMainWindow];
        return YES;
    }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end
