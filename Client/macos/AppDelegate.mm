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
// A menu-bar app (LSUIElement): no Dock icon or window; everything lives in the menu-bar panel.
- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [MenuBarController install];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    [MenuBarController showPanel];
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // Insert code here to tear down your application
}

@end
