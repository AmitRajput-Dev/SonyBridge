//
//  ViewController.mm
//  Thin AppKit host: the storyboard instantiates this controller; it swaps its content for the
//  SwiftUI interface (built in ContentView.swift, exposed via the generated -Swift.h header).
//

#import "ViewController.h"
#import "SonyHeadphonesClient-Swift.h"

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Drop the legacy storyboard controls; the SwiftUI view takes over the whole content area.
    for (NSView *subview in [self.view.subviews copy]) {
        [subview removeFromSuperview];
    }

    NSViewController *ui = [HeadphonesUIFactory makeViewController];
    [self addChildViewController:ui];
    ui.view.frame = self.view.bounds;
    ui.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:ui.view];
}

- (void)viewWillAppear {
    [super viewWillAppear];

    NSWindow *window = self.view.window;
    if (!window) return;

    // The storyboard pins the window to a small fixed size; open it up to a portrait layout.
    window.contentMinSize = NSMakeSize(360, 500);
    window.contentMaxSize = NSMakeSize(560, 900);
    window.styleMask |= NSWindowStyleMaskResizable;
    [window setContentSize:NSMakeSize(380, 560)];
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
}

// Legacy storyboard action connections resolve to these no-op stubs (their controls are removed above).
- (IBAction)connectToDevice:(id)sender {}
- (IBAction)ANCSliderChanged:(id)sender {}
- (IBAction)ANCEnabledButtonChanged:(id)sender {}
- (IBAction)focusOnVoiceChanged:(id)sender {}
- (IBAction)surroundChanged:(id)sender {}
- (IBAction)soundPositionChanged:(id)sender {}

@end
