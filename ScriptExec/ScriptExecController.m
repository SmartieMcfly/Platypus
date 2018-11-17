/*
 Copyright (c) 2003-2018, Sveinbjorn Thordarson <sveinbjorn@sveinbjorn.org>
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2. Redistributions in binary form must reproduce the above copyright notice, this
 list of conditions and the following disclaimer in the documentation and/or other
 materials provided with the distribution.
 
 3. Neither the name of the copyright holder nor the names of its contributors may
 be used to endorse or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
*/

/* This is the source code to the main controller for the binary
 bundled into Platypus-generated applications */

#import <Security/Authorization.h>
#import <WebKit/WebKit.h>
#import <sys/stat.h>

#import "Common.h"
#import "NSColor+HexTools.h"
#import "STPrivilegedTask.h"
#import "STDragWebView.h"
#import "ScriptExecController.h"
#import "NSTask+Description.h"
#import "Alerts.h"
#import "ScriptExecJob.h"

#ifdef DEBUG
#import "PlatypusScriptUtils.h"
#endif

@interface ScriptExecController()
{
    // Progress bar
    IBOutlet NSWindow *progressBarWindow;
    IBOutlet NSButton *progressBarCancelButton;
    IBOutlet NSTextField *progressBarMessageTextField;
    IBOutlet NSProgressIndicator *progressBarIndicator;
    IBOutlet NSTextView *progressBarTextView;
    IBOutlet NSButton *progressBarDetailsTriangle;
    IBOutlet NSTextField *progressBarDetailsLabel;
    
    // Text Window
    IBOutlet NSWindow *textWindow;
    IBOutlet NSButton *textWindowCancelButton;
    IBOutlet NSTextView *textWindowTextView;
    IBOutlet NSProgressIndicator *textWindowProgressIndicator;
    IBOutlet NSTextField *textWindowMessageTextField;
    
    // Web View
    IBOutlet NSWindow *webViewWindow;
    IBOutlet NSButton *webViewCancelButton;
    IBOutlet WebView *webView;
    IBOutlet NSProgressIndicator *webViewProgressIndicator;
    IBOutlet NSTextField *webViewMessageTextField;
    
    // Status Item Menu
    NSStatusItem *statusItem;
    NSMenu *statusItemMenu;
    
    // Droplet
    IBOutlet NSWindow *dropletWindow;
    IBOutlet NSBox *dropletBox;
    IBOutlet NSProgressIndicator *dropletProgressIndicator;
    IBOutlet NSTextField *dropletMessageTextField;
    IBOutlet NSTextField *dropletDropFilesLabel;
    IBOutlet NSView *dropletShaderView;
    
    // Menu items
    IBOutlet NSMenuItem *hideMenuItem;
    IBOutlet NSMenuItem *quitMenuItem;
    IBOutlet NSMenuItem *aboutMenuItem;
    IBOutlet NSMenuItem *openRecentMenuItem;
    IBOutlet NSMenu *windowMenu;
    
    NSTextView *outputTextView;
    
    NSTask *task;
    STPrivilegedTask *privilegedTask;
        
    NSPipe *inputPipe;
    NSFileHandle *inputWriteFileHandle;
    NSPipe *outputPipe;
    NSFileHandle *outputReadFileHandle;
    
    NSMutableArray <NSString *> *arguments;
    NSMutableArray <NSString *> *commandLineArguments;
    NSArray <NSString *> *interpreterArgs;
    NSArray <NSString *> *scriptArgs;
    NSString *stdinString;
    
    NSString *interpreterPath;
    NSString *scriptPath;
    NSString *appName;
    
    NSFont *textFont;
    NSColor *textForegroundColor;
    NSColor *textBackgroundColor;
    
    PlatypusExecStyle execStyle;
    PlatypusInterfaceType interfaceType;
    BOOL isDroppable;
    BOOL remainRunning;
    BOOL acceptsFiles;
    BOOL acceptsText;
    BOOL promptForFileOnLaunch;
    BOOL statusItemUsesSystemFont;
    BOOL statusItemIconIsTemplate;
    BOOL runInBackground;
    BOOL isService;
    
    NSArray <NSString *> *droppableSuffixes;
    NSArray <NSString *> *droppableUniformTypes;
    BOOL acceptAnyDroppedItem;
    BOOL acceptDroppedFolders;
    
    NSString *statusItemTitle;
    NSImage *statusItemImage;
    
    BOOL isTaskRunning;
    BOOL outputEmpty;
    BOOL hasTaskRun;
    BOOL hasFinishedLaunching;
    
    NSString *scriptText;
    NSString *remnants;
    
    NSMutableArray <ScriptExecJob *> *jobQueue;
}

- (IBAction)openFiles:(id)sender;
- (IBAction)saveToFile:(id)sender;
- (IBAction)cancel:(id)sender;
- (IBAction)toggleDetails:(id)sender;
- (IBAction)showDetails;
- (IBAction)hideDetails;
- (IBAction)makeTextBigger:(id)sender;
- (IBAction)makeTextSmaller:(id)sender;

@end

static const NSInteger detailsHeight = 224;

@implementation ScriptExecController

- (instancetype)init {
    if (self = [super init]) {
        arguments = [[NSMutableArray alloc] init];
        outputEmpty = YES;
        jobQueue = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)awakeFromNib {
    
    // Load settings from AppSettings.plist in app bundle
    [self loadAppSettings];
    
    // Prepare UI
    [self initialiseInterface];
    
    // Listen for terminate notification
    NSString *notificationName = NSTaskDidTerminateNotification;
    if (execStyle == PlatypusExecStyle_Authenticated) {
        notificationName = STPrivilegedTaskDidTerminateNotification;
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(taskFinished:)
                                                 name:notificationName
                                               object:nil];
}

#pragma mark - App Settings

// Load configuration from AppSettings.plist, sanitize it, etc.
- (void)loadAppSettings {
    
    NSBundle *appBundle = [NSBundle mainBundle];
    NSString *appSettingsPath = [appBundle pathForResource:@"AppSettings.plist" ofType:nil];
    
    // Make sure all config files are present
    if ([FILEMGR fileExistsAtPath:appSettingsPath] == FALSE) {
        [Alerts fatalAlert:@"Corrupt app bundle" subText:@"AppSettings.plist not found in application bundle."];
    }
    
    // Get app name
    // Try to get name from Info.plist
    NSDictionary *infoPlist = [appBundle infoDictionary];
    if (infoPlist[@"CFBundleName"] != nil) {
        appName = [[NSString alloc] initWithString:infoPlist[@"CFBundleName"]];
    } else {
        // If that doesn't work, use name of executable file
        appName = [[NSString alloc] initWithString:[[appBundle executablePath] lastPathComponent]];
    }
    
    runInBackground = [infoPlist[@"LSUIElement"] boolValue];
    isService = (infoPlist[@"NSServices"] != nil);
    
    // Load dictionary containing app settings from property list
    NSDictionary *appSettingsDict = [NSDictionary dictionaryWithContentsOfFile:appSettingsPath];
    if (appSettingsDict == nil) {
        [Alerts fatalAlert:@"Corrupt app settings" subText:@"Unable to read AppSettings.plist"];
    }
    
    // Determine interface type
    NSString *interfaceTypeStr = appSettingsDict[AppSpecKey_InterfaceType];
    if (IsValidInterfaceTypeString(interfaceTypeStr) == NO) {
        [Alerts fatalAlert:@"Corrupt app settings"
             subTextFormat:@"Invalid Interface Type: '%@'.", interfaceTypeStr];
    }
    interfaceType = InterfaceTypeForString(interfaceTypeStr);
    
    // Text styling
    if (IsTextStyledInterfaceType(interfaceType)) {
    
        // Font and size
        NSNumber *userFontSizeNum = [DEFAULTS objectForKey:ScriptExecDefaultsKey_UserFontSize];
        CGFloat fontSize = userFontSizeNum ? [userFontSizeNum floatValue] : [appSettingsDict[AppSpecKey_TextSize] floatValue];
        fontSize = fontSize != 0 ? fontSize : DEFAULT_TEXT_FONT_SIZE;
        
        if (appSettingsDict[AppSpecKey_TextFont] != nil) {
            textFont = [NSFont fontWithName:appSettingsDict[AppSpecKey_TextFont] size:fontSize];
        }
        if (textFont == nil) {
            textFont = [NSFont fontWithName:DEFAULT_TEXT_FONT_NAME size:DEFAULT_TEXT_FONT_SIZE];
        }
        
        // Foreground color
        if (appSettingsDict[AppSpecKey_TextColor] != nil) {
            textForegroundColor = [NSColor colorFromHexString:appSettingsDict[AppSpecKey_TextColor]];
        }
        if (textForegroundColor == nil) {
            textForegroundColor = [NSColor colorFromHexString:DEFAULT_TEXT_FG_COLOR];
        }
        
        // Background color
        if (appSettingsDict[AppSpecKey_TextBackgroundColor] != nil) {
            textBackgroundColor = [NSColor colorFromHexString:appSettingsDict[AppSpecKey_TextBackgroundColor]];
        }
        if (textBackgroundColor == nil) {
            textBackgroundColor = [NSColor colorFromHexString:DEFAULT_TEXT_BG_COLOR];
        }
    }
    
    // Status menu interface has some additional parameters
    if (interfaceType == PlatypusInterfaceType_StatusMenu) {
        NSString *statusItemDisplayType = appSettingsDict[AppSpecKey_StatusItemDisplayType];

        if ([statusItemDisplayType isEqualToString:PLATYPUS_STATUSITEM_DISPLAY_TYPE_TEXT]) {
            statusItemTitle = [appSettingsDict[AppSpecKey_StatusItemTitle] copy];
            if (statusItemTitle == nil) {
                [Alerts alert:@"Error getting title" subText:@"Failed to get Status Item title."];
            }
        }
        else if ([statusItemDisplayType isEqualToString:PLATYPUS_STATUSITEM_DISPLAY_TYPE_ICON]) {
            statusItemImage = [[NSImage alloc] initWithData:appSettingsDict[AppSpecKey_StatusItemIcon]];
            if (statusItemImage == nil) {
                [Alerts alert:@"Error loading icon" subText:@"Failed to load Status Item icon."];
            }
        }
        
        // Fallback if no title or icon is specified
        if (statusItemImage == nil && statusItemTitle == nil) {
            statusItemTitle = DEFAULT_STATUS_ITEM_TITLE;
        }
        
        statusItemUsesSystemFont = [appSettingsDict[AppSpecKey_StatusItemUseSysfont] boolValue];
        
        statusItemIconIsTemplate = [appSettingsDict[AppSpecKey_StatusItemIconIsTemplate] boolValue];
    }
    
    interpreterArgs = [appSettingsDict[AppSpecKey_InterpreterArgs] copy];
    scriptArgs = [appSettingsDict[AppSpecKey_ScriptArgs] copy];
    execStyle = (PlatypusExecStyle)[appSettingsDict[AppSpecKey_Authenticate] intValue];
    remainRunning = [appSettingsDict[AppSpecKey_RemainRunning] boolValue];
    isDroppable = [appSettingsDict[AppSpecKey_Droppable] boolValue];
    promptForFileOnLaunch = [appSettingsDict[AppSpecKey_PromptForFile] boolValue];
    
    
    // Read and store command line arguments to the application
    NSMutableArray *processArgs = [NSMutableArray arrayWithArray:[[NSProcessInfo processInfo] arguments]];
    commandLineArguments = [[NSMutableArray alloc] init];

    if ([processArgs count] > 1) {
        // The first argument is always the path to the binary, so we remove that
        [processArgs removeObjectAtIndex:0];
        BOOL lastWasDocRevFlag = NO;
        for (NSString *arg in processArgs) {
            
            // On older versions of Mac OS X, apps opened from the Finder
            // are passed a process number argument of the form -psn_0_*******
            // We ignore these
            if ([arg hasPrefix:@"-psn_"]) {
                continue;
            }
            // Hack to remove XCode CLI flags -NSDocumentRevisionsDebugMode YES.
            // Really just here to make debugging easier.
            if ([arg isEqualToString:@"YES"] && lastWasDocRevFlag) {
                continue;
            }
            if ([arg isEqualToString:@"-NSDocumentRevisionsDebugMode"]) {
                lastWasDocRevFlag = YES;
                continue;
            } else {
                lastWasDocRevFlag = NO;
            }
            
            [commandLineArguments addObject:arg];
        }
    }

    // We never have privileged execution or droppable with status menu apps
    if (interfaceType == PlatypusInterfaceType_StatusMenu) {
        remainRunning = YES;
        execStyle = PlatypusExecStyle_Normal;
        isDroppable = NO;
    }
    
    // Load settings for drop acceptance, default is to accept nothing
    acceptsFiles = (appSettingsDict[AppSpecKey_AcceptFiles] != nil) ? [appSettingsDict[AppSpecKey_AcceptFiles] boolValue] : NO;
    acceptsText = (appSettingsDict[AppSpecKey_AcceptText] != nil) ? [appSettingsDict[AppSpecKey_AcceptText] boolValue] : NO;
    
    // Equivalent to not being droppable
    if (!acceptsFiles && !acceptsText) {
        isDroppable = FALSE;
    }

    acceptDroppedFolders = NO;
    acceptAnyDroppedItem = NO;
    
    // If app is droppable, the AppSettings.plist contains list of accepted file types / suffixes
    // We use them later as a criterion for drop acceptance
    if (isDroppable && acceptsFiles) {
        // Get list of accepted suffixes
        droppableSuffixes = [[NSArray alloc] init];
        if (appSettingsDict[AppSpecKey_Suffixes] != nil) {
            droppableSuffixes = [appSettingsDict[AppSpecKey_Suffixes] copy];
        }
        
        droppableUniformTypes = [[NSArray alloc] init];
        if (appSettingsDict[AppSpecKey_Utis] != nil) {
            droppableUniformTypes = [appSettingsDict[AppSpecKey_Utis] copy];
        }
        
        if (([droppableSuffixes containsObject:@"*"] && [droppableUniformTypes count] == 0) || [droppableUniformTypes containsObject:@"public.data"]) {
            acceptAnyDroppedItem = YES;
        }
        if ([droppableSuffixes containsObject:@"fold"] || [droppableUniformTypes containsObject:(NSString *)kUTTypeFolder]) {
            acceptDroppedFolders = YES;
        }
    }
    
    // Check the script file
    NSString *path = [appBundle pathForResource:@"script" ofType:nil];
    if ([FILEMGR fileExistsAtPath:[appBundle pathForResource:@"script" ofType:nil]] == NO) {
        [Alerts fatalAlert:@"Corrupt app bundle" subText:@"Script missing from application bundle."];
    }
    // Make sure it's executable
    NSNumber *permissions = [NSNumber numberWithUnsignedLong:493];
    NSDictionary *attributes = @{ NSFilePosixPermissions: permissions};
    [[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:path error:nil];

    scriptPath = [NSString stringWithString:path];
    
    // Get interpreter
    NSString *scriptInterpreterPath = appSettingsDict[AppSpecKey_InterpreterPath];
#ifdef DEBUG
    // For debugging purposes, an empty or missing interpreter means we
    // parse the shebang line for one. Makes it easier to switch scripting
    // languages in the test script without mucking about with AppSettings.plist
    if (scriptInterpreterPath == nil || [scriptInterpreterPath isEqualToString:@""]) {
        scriptInterpreterPath = [PlatypusScriptUtils determineInterpreterPathForScriptFile:scriptPath];
        if (scriptInterpreterPath == nil) {
            scriptInterpreterPath = DEFAULT_INTERPRETER_PATH;
        }
    }
#else
    if (scriptInterpreterPath == nil || [FILEMGR fileExistsAtPath:scriptInterpreterPath] == NO) {
        [Alerts fatalAlert:@"Missing interpreter"
             subTextFormat:@"This application cannot run because the interpreter '%@' does not exist.", scriptInterpreterPath];
    }
#endif
    interpreterPath = [[NSString alloc] initWithString:scriptInterpreterPath];

    // Make sure we can read the script file
    if ([FILEMGR isReadableFileAtPath:scriptPath] == NO) {
        // chmod 774
        chmod([scriptPath cStringUsingEncoding:NSUTF8StringEncoding], S_IRWXU|S_IRWXG|S_IROTH);
    }
    if ([FILEMGR isReadableFileAtPath:scriptPath] == NO) {
        [Alerts fatalAlert:@"Corrupt app bundle" subText:@"Script file is not readable."];
    }
}

#pragma mark - App Delegate handlers

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification {
    // Register ourselves as a URL handler for this URL
    [[NSAppleEventManager sharedAppleEventManager] setEventHandler:self
                                                       andSelector:@selector(getUrl:withReplyEvent:)
                                                     forEventClass:kInternetEventClass
                                                        andEventID:kAEGetURL];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    PLog(@"Application did finish launching");
    hasFinishedLaunching = YES;

    if (isService) {
        [NSApp setServicesProvider:self]; // register as text handling service
//        NSMutableArray *sendTypes = [NSMutableArray array];
//        if (acceptsFiles) {
//            [sendTypes addObject:NSFilenamesPboardType];
//        }
//        if (acceptsText) {
//            [sendTypes addObject:NSStringPboardType];
//        }
//        [NSApp registerServicesMenuSendTypes:sendTypes returnTypes:@[]];
//        NSUpdateDynamicServices();
    }
    
    [[NSUserNotificationCenter defaultUserNotificationCenter] setDelegate:self];
    
    // Status menu apps just run when item is clicked
    // For all others, we run the script once app has launched
    if (interfaceType == PlatypusInterfaceType_StatusMenu) {
        return;
    }
    
    if (promptForFileOnLaunch && isDroppable && [jobQueue count] == 0) {
        [self openFiles:self];
    } else {
        [self executeScript];
    }
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification {
    return YES;
}

- (void)application:(NSApplication *)theApplication openFiles:(NSArray *)filenames {
    PLog(@"Received openFiles event for files: %@", [filenames description]);
    
    if (hasTaskRun == FALSE && commandLineArguments != nil) {
        for (NSString *filePath in filenames) {
            if ([commandLineArguments containsObject:filePath]) {
                return;
            }
        }
    }
    
    // Add the dropped files as a job for processing
    BOOL success = [self addDroppedFilesJob:filenames];
    [NSApp replyToOpenOrPrint:success ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure];
    
    // If no other job is running, we execute
    if (success && !isTaskRunning && hasFinishedLaunching) {
        [self executeScript];
    }
}

- (void)getUrl:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
    NSString *url = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
    PLog(@"Received open URL event for URL %@", url);
    
    // Add URL as a job for processing
    BOOL success = [self addURLJob:url];
    
    // If no other job is running, we execute
    if (!isTaskRunning && success && hasFinishedLaunching) {
        [self executeScript];
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    // Terminate task
    if (task != nil) {
        if ([task isRunning]) {
            [task terminate];
        }
        task = nil;
    }
    
    // Terminate privileged task
    if (privilegedTask != nil) {
        if ([privilegedTask isRunning]) {
            [privilegedTask terminate];
        }
        privilegedTask = nil;
    }
    
    // Hide status item
    if (statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    }
    
    return NSTerminateNow;
}

#pragma mark - Interface manipulation

// Set up any menu items, windows, controls at application launch
- (void)initialiseInterface {
    
    // Put application name into the relevant menu items
    [quitMenuItem setTitle:[NSString stringWithFormat:@"Quit %@", appName]];
    [aboutMenuItem setTitle:[NSString stringWithFormat:@"About %@", appName]];
    [hideMenuItem setTitle:[NSString stringWithFormat:@"Hide %@", appName]];
    
    [openRecentMenuItem setEnabled:acceptsFiles];
    
    // Script output will be dumped in outputTextView
    // By default this is the Text Window text view
    outputTextView = textWindowTextView;

    if (runInBackground == TRUE) {
        // Old Carbon way
//        ProcessSerialNumber process;
//        GetCurrentProcess(&process);
//        SetFrontProcess(&process);
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    }
    
    // Prepare controls etc. for different interface types
    switch (interfaceType) {
        case PlatypusInterfaceType_None:
            // Nothing to do
            break;
            
        case PlatypusInterfaceType_ProgressBar:
        {
            if (isDroppable) {
                [progressBarWindow registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
            }
            
            // Add menu item for Show Details
            [[windowMenu insertItemWithTitle:@"Toggle Details" action:@selector(performClick:) keyEquivalent:@"T" atIndex:2] setTarget:progressBarDetailsTriangle];
            [windowMenu insertItem:[NSMenuItem separatorItem] atIndex:2];
            
            // Style the text field
            outputTextView = progressBarTextView;
            [outputTextView setBackgroundColor:textBackgroundColor];
            [outputTextView setTextColor:textForegroundColor];
            [outputTextView setFont:textFont];
            [[outputTextView textStorage] setFont:textFont];
            
            // Add drag instructions message if droplet
            NSString *progBarMsg = isDroppable ? @"Drag files to process" : @"Running...";
            [progressBarMessageTextField setStringValue:progBarMsg];
            [progressBarIndicator setUsesThreadedAnimation:YES];
            
            // Prepare window
            [progressBarWindow setTitle:appName];
            
            // Center it if first time running the application
            if ([[progressBarWindow frameAutosaveName] isEqualToString:@""]) {
                [progressBarWindow center];
            }
            
            if ([DEFAULTS boolForKey:ScriptExecDefaultsKey_ShowDetails]) {
                NSRect frame = [progressBarWindow frame];
                frame.origin.y += detailsHeight;
                [progressBarWindow setFrame:frame display:NO];
                [self showDetails];
            }
            
            [progressBarWindow makeKeyAndOrderFront:self];
        }
            break;
            
        case PlatypusInterfaceType_TextWindow:
        {
            if (isDroppable) {
                [textWindow registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
                [textWindowMessageTextField setStringValue:@"Drag files on window to process them"];
            }
            
            [textWindowProgressIndicator setUsesThreadedAnimation:YES];
            [outputTextView setBackgroundColor:textBackgroundColor];
            [outputTextView setTextColor:textForegroundColor];
            [outputTextView setFont:textFont];
            [[outputTextView textStorage] setFont:textFont];
            
            // Prepare window
            [textWindow setTitle:appName];
            if ([[textWindow frameAutosaveName] isEqualToString:@""]) {
                [textWindow center];
            }
            [textWindow makeKeyAndOrderFront:self];
        }
            break;
            
        case PlatypusInterfaceType_WebView:
        {
            if (isDroppable) {
                [webViewWindow registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
                [webView registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
                [webViewMessageTextField setStringValue:@"Drag files on window to process them"];
            }
            
            [webViewProgressIndicator setUsesThreadedAnimation:YES];
            
            // Prepare window
            [webViewWindow setTitle:appName];
            [webViewWindow center];
            if ([[webViewWindow frameAutosaveName] isEqualToString:@""]) {
                [webViewWindow center];
            }
            [webViewWindow makeKeyAndOrderFront:self];
        }
            break;
            
        case PlatypusInterfaceType_StatusMenu:
        {
            // Create and activate status item
            statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
            [statusItem setHighlightMode:YES];
            
            // Set status item title and icon
            [statusItem setTitle:statusItemTitle];
            
            NSSize statusItemSize = [statusItemImage size];
            CGFloat rel = 18/statusItemSize.height;
            NSSize finalSize = NSMakeSize(statusItemSize.width * rel, statusItemSize.height * rel);
            [statusItemImage setSize:finalSize];
            [statusItemImage setTemplate:statusItemIconIsTemplate];
            [statusItem setImage:statusItemImage];
            
            // Create menu for our status item
            statusItemMenu = [[NSMenu alloc] initWithTitle:@""];
            [statusItemMenu setDelegate:self];
            [statusItem setMenu:statusItemMenu];
            
            // Create Quit menu item
            NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Quit %@", appName] action:@selector(terminate:) keyEquivalent:@""];
            [statusItemMenu insertItem:menuItem atIndex:0];
            [statusItemMenu insertItem:[NSMenuItem separatorItem] atIndex:0];
            [statusItem setEnabled:YES];
        }
            break;
            
        case PlatypusInterfaceType_Droplet:
        {
            if (isDroppable) {
                [dropletWindow registerForDraggedTypes:@[NSFilenamesPboardType, NSStringPboardType]];
            }
            [dropletProgressIndicator setUsesThreadedAnimation:YES];
            
            // Prepare window
            [dropletWindow setTitle:appName];
            if ([[dropletWindow frameAutosaveName] isEqualToString:@""]) {
                [dropletWindow center];
            }
            [dropletWindow makeKeyAndOrderFront:self];
        }
            break;
    }
}

// Prepare all the controls, windows, etc prior to executing script
- (void)prepareInterfaceForExecution {
    [outputTextView setString:@""];
    
    switch (interfaceType) {
        case PlatypusInterfaceType_None:
        case PlatypusInterfaceType_StatusMenu:
            break;
            
        case PlatypusInterfaceType_ProgressBar:
        {
            // Yes, yes, this is a nasty hack. But styling in NSTextViews
            // doesn't get applied when appending text unless there is already
            // some text in the view. The alternative is to make very expensive
            // calls to [textStorage setAttributes:] for all appended output,
            // which freezes up the app when lots of text is dumped by the script
            [outputTextView setString:@"\u200B"]; // zero-width space character

            [progressBarIndicator setIndeterminate:YES];
            [progressBarIndicator startAnimation:self];
            [progressBarMessageTextField setStringValue:@"Running..."];
            [progressBarCancelButton setTitle:@"Cancel"];
            if (execStyle == PlatypusExecStyle_Authenticated) {
                [progressBarCancelButton setEnabled:NO];
            }
        }
            break;
            
        case PlatypusInterfaceType_TextWindow:
        {
            // Yes, yes, this is a nasty hack. But styling in NSTextViews
            // doesn't get applied when appending text unless there is already
            // some text in the view. The alternative is to make very expensive
            // calls to [textStorage setAttributes:] for all appended output,
            // which freezes up the app when lots of text is dumped by the script
            [outputTextView setString:@"\u200B"]; // zero-width space character

            [textWindowCancelButton setTitle:@"Cancel"];
            if (execStyle == PlatypusExecStyle_Authenticated) {
                [textWindowCancelButton setEnabled:NO];
            }
            [textWindowProgressIndicator startAnimation:self];
        }
            break;
            
        case PlatypusInterfaceType_WebView:
        {
            [webViewCancelButton setTitle:@"Cancel"];
            if (execStyle == PlatypusExecStyle_Authenticated) {
                [webViewCancelButton setEnabled:NO];
            }
            [webViewProgressIndicator startAnimation:self];
        }
            break;
            
        case PlatypusInterfaceType_Droplet:
        {
            [dropletProgressIndicator setIndeterminate:YES];
            [dropletProgressIndicator startAnimation:self];
            [dropletDropFilesLabel setHidden:YES];
            [dropletMessageTextField setHidden:NO];
            [dropletMessageTextField setStringValue:@"Processing..."];
        }
            break;
            
    }
}

// Adjust controls, windows, etc. once script is done executing
- (void)cleanupInterface {
    
    // if there are any remnants, we append them to output
    if (remnants != nil) {
        [self appendString:remnants];
        remnants = nil;
    }
    
    switch (interfaceType) {
            
        case PlatypusInterfaceType_None:
        case PlatypusInterfaceType_StatusMenu:
        {
            
        }
            break;

        case PlatypusInterfaceType_TextWindow:
        {
            // Update controls for text window
            [textWindowCancelButton setTitle:@"Quit"];
            [textWindowCancelButton setEnabled:YES];
            [textWindowProgressIndicator stopAnimation:self];
        }
            break;
            
        case PlatypusInterfaceType_ProgressBar:
        {            
            if (isDroppable) {
                [progressBarMessageTextField setStringValue:@"Drag files to process"];
                [progressBarIndicator setIndeterminate:YES];
            } else {
                // Cleanup - if the script didn't give us a proper status message, then we set one
                NSString *msg = [progressBarMessageTextField stringValue];
                if ([msg isEqualToString:@""] || [msg isEqualToString:@"\n"] || [msg isEqualToString:@"Running..."]) {
                    [progressBarMessageTextField setStringValue:@"Task completed"];
                }
                [progressBarIndicator setIndeterminate:NO];
                [progressBarIndicator setDoubleValue:100];
            }
            
            [progressBarIndicator stopAnimation:self];
            
            // Change button
            [progressBarCancelButton setTitle:@"Quit"];
            [progressBarCancelButton setEnabled:YES];
        }
            break;
            
        case PlatypusInterfaceType_WebView:
        {
            [webViewCancelButton setTitle:@"Quit"];
            [webViewCancelButton setEnabled:YES];
            [webViewProgressIndicator stopAnimation:self];
        }
            break;
            
        case PlatypusInterfaceType_Droplet:
        {
            [dropletProgressIndicator stopAnimation:self];
            [dropletDropFilesLabel setHidden:NO];
            [dropletMessageTextField setHidden:YES];
        }
            break;
    }
}

#pragma mark - Task

// Construct arguments list etc. before actually running the script
- (void)prepareForExecution {
    
    // Clear arguments list and reconstruct it
    [arguments removeAllObjects];
    
    // First, add all specified arguments for interpreter
    [arguments addObjectsFromArray:interpreterArgs];
    
    // Add script as argument to interpreter, if it exists
    if (![FILEMGR fileExistsAtPath:scriptPath]) {
        [Alerts fatalAlert:@"Missing script" subTextFormat:@"Script missing at execution path %@", scriptPath];
    }
    [arguments addObject:scriptPath];
    
    // Add arguments for script
    [arguments addObjectsFromArray:scriptArgs];
    
    // If initial run of app, add any arguments passed in via the command line (argv)
    // Q: Why CLI args for GUI app typically launched from Finder?
    // A: Apparently helpful for certain use cases such as Firefox protocol handlers etc.
    if (commandLineArguments && [commandLineArguments count]) {
        [arguments addObjectsFromArray:commandLineArguments];
        commandLineArguments = nil;
    }
    
    // Finally, dequeue job and add arguments
    if ([jobQueue count] > 0) {
        ScriptExecJob *job = jobQueue[0];

        // We have files in the queue, to append as arguments
        // We take the first job's arguments and put them into the arg list
        if ([job arguments]) {
            [arguments addObjectsFromArray:[job arguments]];
        }
        stdinString = [[job standardInputString] copy];
        
        [jobQueue removeObjectAtIndex:0];
    }
}

- (void)executeScript {
    hasTaskRun = YES;
    
    // Never execute script if there is one running
    if (isTaskRunning) {
        return;
    }
    outputEmpty = NO;
    
    [self prepareForExecution];
    [self prepareInterfaceForExecution];
    
    isTaskRunning = YES;
    
    // Run the task
    if (execStyle == PlatypusExecStyle_Authenticated) {
        [self executeScriptWithPrivileges];
    } else {
        [self executeScriptWithoutPrivileges];
    }
}

- (NSString *)executeScriptForStatusMenu {

    [self prepareForExecution];
    [self prepareInterfaceForExecution];
    
    // Create task and apply settings
    task = [[NSTask alloc] init];
    [task setLaunchPath:interpreterPath];
    [task setCurrentDirectoryPath:[[NSBundle mainBundle] resourcePath]];
    [task setArguments:arguments];

    outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:outputPipe];
    outputReadFileHandle = [outputPipe fileHandleForReading];
    
    // Set it off
    PLog(@"Running task\n%@", [task humanDescription]);
    [task launch];
    // This is blocking
    [task waitUntilExit];
    
    NSData *outData = [outputReadFileHandle readDataToEndOfFile];
    return [[NSString alloc] initWithData:outData encoding:DEFAULT_TEXT_ENCODING];
}

// Launch regular user-privileged process using NSTask
- (void)executeScriptWithoutPrivileges {

    // Create task and apply settings
    task = [[NSTask alloc] init];
    [task setLaunchPath:interpreterPath];
    [task setCurrentDirectoryPath:[[NSBundle mainBundle] resourcePath]];
    [task setArguments:arguments];
    
    // Direct output to file handle and start monitoring it if script provides feedback
    outputPipe = [NSPipe pipe];
    [task setStandardOutput:outputPipe];
    [task setStandardError:outputPipe];
    outputReadFileHandle = [outputPipe fileHandleForReading];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(gotOutputData:) name:NSFileHandleReadCompletionNotification object:outputReadFileHandle];
    [outputReadFileHandle readInBackgroundAndNotify];
    
    // Set up stdin for writing
    inputPipe = [NSPipe pipe];
    [task setStandardInput:inputPipe];
    inputWriteFileHandle = [[task standardInput] fileHandleForWriting];
    
    // Set it off
    PLog(@"Running task\n%@", [task humanDescription]);
    [task launch];
    
    // Write input, if any, to stdin, and then close
    if (stdinString) {
        [inputWriteFileHandle writeData:[stdinString dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [inputWriteFileHandle closeFile];
    stdinString = nil;    
}

// Launch task with admin privileges using Authentication API
- (void)executeScriptWithPrivileges {
    // Create task
    privilegedTask = [[STPrivilegedTask alloc] init];
    [privilegedTask setLaunchPath:interpreterPath];
    [privilegedTask setCurrentDirectoryPath:[[NSBundle mainBundle] resourcePath]];
    [privilegedTask setArguments:arguments];
    
    // Set it off
    PLog(@"Running task\n%@", [privilegedTask description]);
    OSStatus err = [privilegedTask launch];
    if (err != errAuthorizationSuccess) {
        if (err == errAuthorizationCanceled) {
            outputEmpty = YES;
            [self taskFinished:nil];
            return;
        }  else {
            // Something went wrong
            [Alerts fatalAlert:@"Failed to execute script"
                 subTextFormat:@"Error %d occurred while executing script with privileges.", (int)err];
        }
    }
    
    // Success! Now, start monitoring output file handle for data
    outputReadFileHandle = [privilegedTask outputFileHandle];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(gotOutputData:) name:NSFileHandleReadCompletionNotification object:outputReadFileHandle];
    [outputReadFileHandle readInBackgroundAndNotify];
}

#pragma mark - Task completion

// OK, called when we receive notification that task is finished
// Some cleaning up to do, controls need to be adjusted, etc.
- (void)taskFinished:(NSNotification *)aNotification {
    // Ignore if not current script task
    if (([aNotification object] != task && [aNotification object] != privilegedTask) || !isTaskRunning) {
        return;
    }
    isTaskRunning = NO;
    PLog(@"Task finished");
        
    // Did we receive all the data?
    // If no data left, we do clean up
    if (outputEmpty) {
        [self cleanup];
    }
    
    // If there are more jobs waiting for us, execute
    if ([jobQueue count] > 0 /*&& remainRunning*/) {
        [self executeScript];
    }
}

- (void)cleanup {
    if (isTaskRunning) {
        return;
    }
    // Stop observing the filehandle for data since task is done
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSFileHandleReadCompletionNotification
                                                  object:outputReadFileHandle];
    
    // We make sure to clear the filehandle of any remaining data
    if (outputReadFileHandle != nil) {
        NSData *data;
        while ((data = [outputReadFileHandle availableData]) && [data length]) {
            [self appendOutput:data];
        }
    }
    
    // Now, reset all controls etc., general cleanup since task is done
    [self cleanupInterface];
}

#pragma mark - Output

// Read from the file handle and append it to the text window
- (void)gotOutputData:(NSNotification *)aNotification {
    // Get the data from notification
    NSData *data = [aNotification userInfo][NSFileHandleNotificationDataItem];
    
    // Make sure there's actual data
    if ([data length]) {
        outputEmpty = NO;
        
        // Append the output to the text field
        [self appendOutput:data];
        
        // We schedule the file handle to go and read more data in the background again.
        [[aNotification object] readInBackgroundAndNotify];
    }
    else {
        PLog(@"Output empty");
        outputEmpty = YES;
        if (!isTaskRunning) {
            [self cleanup];
        }
        if (!remainRunning) {
            [[NSApplication sharedApplication] terminate:self];
        }
    }
}

- (void)appendOutput:(NSData *)data {
    // Create string from raw output data
    NSMutableString *outputString = [[NSMutableString alloc] initWithData:data encoding:DEFAULT_TEXT_ENCODING];
    
    if (outputString == nil) {
        PLog(@"Warning: Output string is nil");
        return;
    }
    PLog(@"Output:%@", outputString);
    
    if (remnants != nil && [remnants length] > 0) {
        [outputString insertString:remnants atIndex:0];
    }
    
    // Parse line by line
    NSMutableArray <NSString *> *lines = [[outputString componentsSeparatedByString:@"\n"] mutableCopy];
    
    // If the string did not end with a newline, it wasn't a complete line of output
    // Thus, we store this last non-newline-terminated string
    // It'll be prepended next time we get output
    if ([[lines lastObject] length] > 0) {
        remnants = [[lines lastObject] copy];
    } else {
        remnants = nil;
    }
    
    [lines removeLastObject];
    
    
    NSURL *locationURL = nil;
    
    // Parse output looking for commands; if none, append line to output text field
    for (NSString *theLine in lines) {
        
        if ([theLine length] == 0) {
            continue;
        }
        
        if ([theLine isEqualToString:@"QUITAPP"]) {
            [[NSApplication sharedApplication] terminate:self];
            continue;
        }
        
        if ([theLine isEqualToString:@"REFRESH"]) {
            [self clearOutputBuffer];
            continue;
        }
        
        if ([theLine hasPrefix:@"NOTIFICATION:"]) {
            NSString *notificationString = [theLine substringFromIndex:13];
            [self showNotification:notificationString];
            continue;
        }
        
        if ([theLine hasPrefix:@"ALERT:"]) {
            NSString *alertString = [theLine substringFromIndex:6];
            NSArray *components = [alertString componentsSeparatedByString:CMDLINE_ARG_SEPARATOR];
            [Alerts alert:components[0] subText:[components count] > 1 ? components[1] : components[0]];
            continue;
        }
        
        // Special commands to control progress bar interface
        if (interfaceType == PlatypusInterfaceType_ProgressBar) {
            
            // Set progress bar status
            // Lines starting with PROGRESS:\d+ are interpreted as percentage to set progress bar
            if ([theLine hasPrefix:@"PROGRESS:"]) {
                NSString *progressPercentString = [theLine substringFromIndex:9];
                if ([progressPercentString hasSuffix:@"%"]) {
                    progressPercentString = [progressPercentString substringToIndex:[progressPercentString length]-1];
                }
                
                // Parse percentage using number formatter
                NSNumberFormatter *numFormatter = [[NSNumberFormatter alloc] init];
                numFormatter.numberStyle = NSNumberFormatterDecimalStyle;
                NSNumber *percentageNumber = [numFormatter numberFromString:progressPercentString];
                
                if (percentageNumber != nil) {
                    [progressBarIndicator setIndeterminate:NO];
                    [progressBarIndicator setDoubleValue:[percentageNumber doubleValue]];
                }
                continue;
            }
            // Set visibility of details text field
            else if ([theLine isEqualToString:@"DETAILS:SHOW"]) {
                [self showDetails];
                continue;
            }
            else if ([theLine isEqualToString:@"DETAILS:HIDE"]) {
                [self hideDetails];
                continue;
            }
        }
        
        if (interfaceType == PlatypusInterfaceType_WebView && [[outputTextView textStorage] length] == 0 && [theLine hasPrefix:@"Location:"]) {
            NSString *urlString = [theLine substringFromIndex:9];
            urlString = [urlString stringByReplacingOccurrencesOfString:@" " withString:@""];
            locationURL = [NSURL URLWithString:urlString];
        }
        
        [self appendString:theLine];
        
        // OK, line wasn't a command understood by the wrapper
        // Show it in GUI text field
        if (interfaceType == PlatypusInterfaceType_Droplet) {
            [dropletMessageTextField setStringValue:theLine];
        }
        if (interfaceType == PlatypusInterfaceType_ProgressBar) {
            [progressBarMessageTextField setStringValue:theLine];
        }
    }
    
    // If web output, we continually re-render to accomodate incoming data
    if (interfaceType == PlatypusInterfaceType_WebView) {
        if (locationURL) {
            // Load the provided URL
            [[webView mainFrame] loadRequest:[NSURLRequest requestWithURL:locationURL]];
        } else {
            // Otherwise, just load script output as HTML string
            NSURL *resourcePathURL = [NSURL fileURLWithPath:[[NSBundle mainBundle] resourcePath]];
            [[webView mainFrame] loadHTMLString:[outputTextView string] baseURL:resourcePathURL];
        }
    }
    
    if (IsTextViewScrollableInterfaceType(interfaceType)) {
        [outputTextView scrollRangeToVisible:NSMakeRange([[outputTextView textStorage] length], 0)];
    }
}

- (void)clearOutputBuffer {
    NSTextStorage *textStorage = [outputTextView textStorage];
    NSRange range = NSMakeRange(0, [textStorage length]-1);
    [textStorage beginEditing];
    [textStorage replaceCharactersInRange:range withString:@""];
    [textStorage endEditing];
}

- (void)appendString:(NSString *)string {
    //PLog(@"Appending output: \"%@\"", string);

    if (interfaceType == PlatypusInterfaceType_None) {
        fprintf(stderr, "%s\n", [string cStringUsingEncoding:DEFAULT_TEXT_ENCODING]);
        return;
    }
    
    NSTextStorage *textStorage = [outputTextView textStorage];
    NSRange appendRange = NSMakeRange([textStorage length], 0);
    [textStorage beginEditing];
    [textStorage replaceCharactersInRange:appendRange withString:string];
    [textStorage replaceCharactersInRange:NSMakeRange([textStorage length], 0) withString:@"\n"];
    [textStorage endEditing];
}

#pragma mark - Interface actions

// Run open panel, made available to apps that accept files
- (IBAction)openFiles:(id)sender {
    
    // Create open panel
    NSOpenPanel *oPanel = [NSOpenPanel openPanel];
    [oPanel setAllowsMultipleSelection:YES];
    [oPanel setCanChooseFiles:YES];
    [oPanel setCanChooseDirectories:acceptDroppedFolders];
    
    // Set acceptable file types - default allows all
    if (!acceptAnyDroppedItem) {
        NSArray *fileTypes = [droppableUniformTypes count] > 0 ? droppableUniformTypes : droppableSuffixes;
        [oPanel setAllowedFileTypes:fileTypes];
    }
    
    if ([oPanel runModal] == NSFileHandlingPanelOKButton) {
        // Convert URLs to paths
        NSMutableArray *filePaths = [NSMutableArray array];        
        for (NSURL *url in [oPanel URLs]) {
            [filePaths addObject:[url path]];
        }
        
        BOOL success = [self addDroppedFilesJob:filePaths];
        
        if (!isTaskRunning && success) {
            [self executeScript];
        }
        
    } else {
        // Canceled in open file dialog
        if (!remainRunning) {
            [[NSApplication sharedApplication] terminate:self];
        }
    }
}

// Show / hide the details text field in progress bar interface
- (IBAction)toggleDetails:(id)sender {
    NSRect winRect = [progressBarWindow frame];
    
    NSSize minSize = [progressBarWindow minSize];
    NSSize maxSize = [progressBarWindow maxSize];
    
    if ([sender state] == NSOffState) {
        winRect.origin.y += detailsHeight;
        winRect.size.height -= detailsHeight;
        minSize.height -= detailsHeight;
        maxSize.height -= detailsHeight;

    }
    else {
        winRect.origin.y -= detailsHeight;
        winRect.size.height += detailsHeight;
        minSize.height += detailsHeight;
        maxSize.height += detailsHeight;
    }
    
    [DEFAULTS setBool:([sender state] == NSOnState) forKey:ScriptExecDefaultsKey_ShowDetails];
    [progressBarWindow setMinSize:minSize];
    [progressBarWindow setMaxSize:maxSize];
    [progressBarWindow setShowsResizeIndicator:([sender state] == NSOnState)];
    [progressBarWindow setFrame:winRect display:TRUE animate:TRUE];
}

// Show the details text field in progress bar interface
- (IBAction)showDetails {
    if ([progressBarDetailsTriangle state] == NSOffState) {
        [progressBarDetailsTriangle performClick:progressBarDetailsTriangle];
    }
}

// Hide the details text field in progress bar interface
- (IBAction)hideDetails {
    if ([progressBarDetailsTriangle state] != NSOffState) {
        [progressBarDetailsTriangle performClick:progressBarDetailsTriangle];
    }
}

// Save output in text field to file when Save to File menu item is invoked
- (IBAction)saveToFile:(id)sender {
    if (IsTextStyledInterfaceType(interfaceType) == NO) {
        return;
    }
    NSString *outSuffix = (interfaceType == PlatypusInterfaceType_WebView) ? @"html" : @"txt";
    NSString *fileName = [NSString stringWithFormat:@"%@-Output.%@", appName, outSuffix];
    
    NSSavePanel *sPanel = [NSSavePanel savePanel];
    [sPanel setPrompt:@"Save"];
    [sPanel setNameFieldStringValue:fileName];
    
    if ([sPanel runModal] == NSFileHandlingPanelOKButton) {
        NSError *err;
        BOOL success = [[outputTextView string] writeToFile:[[sPanel URL] path] atomically:YES encoding:DEFAULT_TEXT_ENCODING error:&err];
        if (!success) {
            [Alerts alert:@"Error writing file" subText:[err localizedDescription]];
        }
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)anItem {
    
    // Status item menus are always enabled
    if (interfaceType == PlatypusInterfaceType_StatusMenu) {
        return YES;
    }
    // Save to file
    if (IsTextStyledInterfaceType(interfaceType) && [[anItem title] isEqualToString:@"Save to File…"]) {
        return YES;
    }
    // Open should only work if it's a droppable app that accepts files
    if ((isDroppable && acceptsFiles) && [[anItem title] isEqualToString:@"Open…"]) {
        return YES;
    }
    // Change text size
    if (IsTextSizableInterfaceType(interfaceType) && [[anItem title] hasPrefix:@"Make Text"]) {
        return YES;
    }
    
    return NO;
}

- (IBAction)cancel:(id)sender {
    if (task != nil && [task isRunning]) {
        PLog(@"Task cancelled");
        [task terminate];
    }
    
    if ([[sender title] isEqualToString:@"Quit"]) {
        [[NSApplication sharedApplication] terminate:self];
    }
}

#pragma mark - Text resizing

- (void)changeFontSize:(CGFloat)delta {
    
    if (interfaceType == PlatypusInterfaceType_WebView) {
        // Web View
        if (delta > 0) {
            [webView makeTextLarger:self];
        } else {
            [webView makeTextSmaller:self];
        }
    } else {
        // Text field
        CGFloat newFontSize = [textFont pointSize] + delta;
        if (newFontSize < 5.0) {
            newFontSize = 5.0;
        }

        textFont = [[NSFontManager sharedFontManager] convertFont:textFont toSize:newFontSize];
        [outputTextView setFont:textFont];
        [DEFAULTS setObject:@((float)newFontSize) forKey:ScriptExecDefaultsKey_UserFontSize];
        [outputTextView didChangeText];
    }
}

- (IBAction)makeTextBigger:(id)sender {
    [self changeFontSize:1];
}

- (IBAction)makeTextSmaller:(id)sender {
    [self changeFontSize:-1];
}

#pragma mark - Service handling

- (void)dropService:(NSPasteboard *)pb userData:(NSString *)userData error:(NSString **)err {
    PLog(@"Received drop service data");
    NSArray *types = [pb types];
    BOOL ret = 0;
    id data = nil;
    
    if (acceptsFiles && [types containsObject:NSFilenamesPboardType] && (data = [pb propertyListForType:NSFilenamesPboardType])) {
        ret = [self addDroppedFilesJob:data];  // Files
    } else if (acceptsText && [types containsObject:NSURLPboardType] && [NSURL URLFromPasteboard:pb] != nil) {
        NSURL *fileURL = [NSURL URLFromPasteboard:pb];
        ret = [self addDroppedTextJob:[fileURL absoluteString]];  // URL
    } else if (acceptsText && [types containsObject:NSStringPboardType] && (data = [pb stringForType:NSStringPboardType])) {
        ret = [self addDroppedTextJob:data];  // Text
    } else {
        // Unknown
        *err = @"Data type in pasteboard cannot be handled by this application.";
        return;
    }
    
    if (isTaskRunning == NO && ret) {
        [self executeScript];
    }
}

#pragma mark - Text snippet drag handling

- (void)doString:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
    if (isDroppable == NO || acceptsText == NO) {
        return;
    }
    
    NSString *pboardString = [pboard stringForType:NSStringPboardType];
    BOOL success = [self addDroppedTextJob:pboardString];
    
    if (!isTaskRunning && success) {
        [self executeScript];
    }
}

#pragma mark - Add job to queue

- (BOOL)addDroppedTextJob:(NSString *)text {
    if (!isDroppable) {
        return NO;
    }
    ScriptExecJob *job = [ScriptExecJob jobWithArguments:nil andStandardInput:text];
    [jobQueue addObject:job];
    return YES;
}

// Processing dropped files
- (BOOL)addDroppedFilesJob:(NSArray <NSString *> *)files {
    if (!isDroppable || !acceptsFiles) {
        return NO;
    }
    
    // We only accept the drag if at least one of the files meets the required types
    NSMutableArray *acceptedFiles = [NSMutableArray array];
    for (NSString *file in files) {
        if ([self isAcceptableFileType:file]) {
            [acceptedFiles addObject:file];
        }
    }
    if ([acceptedFiles count] == 0) {
        return NO;
    }
    
    // Add to Open Recent menu
    for (NSString *path in acceptedFiles) {
        [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:[NSURL fileURLWithPath:path]];
    }
    
    // We create a job and add the files as arguments
    ScriptExecJob *job = [ScriptExecJob jobWithArguments:acceptedFiles andStandardInput:nil];
    [jobQueue addObject:job];
    
    return YES;
}

- (BOOL)addURLJob:(NSString *)urlStr {
    ScriptExecJob *job = [ScriptExecJob jobWithArguments:@[urlStr] andStandardInput:nil];
    [jobQueue addObject:job];
    return YES;
}

- (BOOL)addMenuItemSelectedJob:(NSString *)menuItemTitle {
    ScriptExecJob *job = [ScriptExecJob jobWithArguments:@[menuItemTitle] andStandardInput:nil];
    [jobQueue addObject:job];
    return YES;
}

/*********************************************
 Returns whether a given file matches the file
 suffixes/UTIs specified in AppSettings.plist
 *********************************************/

- (BOOL)isAcceptableFileType:(NSString *)file {
    
    // Check if it's a folder. If so, we only accept it if folders are accepted
    BOOL isDir;
    if ([FILEMGR fileExistsAtPath:file isDirectory:&isDir] && isDir && acceptDroppedFolders) {
        return YES;
    }
    
    if (acceptAnyDroppedItem) {
        return YES;
    }
    
//    if ([droppableUniformTypes count] == 0) {
        for (NSString *suffix in droppableSuffixes) {
            if ([file hasSuffix:suffix]) {
                return YES;
            }
        }
//    }

    for (NSString *uti in droppableUniformTypes) {
        NSError *outErr = nil;
        NSString *fileType = [WORKSPACE typeOfFile:file error:&outErr];
        if (fileType == nil) {
            NSLog(@"Unable to determine file type for %@: %@", file, [outErr localizedDescription]);
        } else if ([WORKSPACE type:fileType conformsToType:uti]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - Drag and drop handling

// Check file types against acceptable drop types here before accepting them
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender {
    // Prevent dragging from NSOpenPanels
    // draggingSource returns nil if the source is not in the same application
    // as the destination. We decline any drags from within the app.
    if ([sender draggingSource]) {
        return NSDragOperationNone;
    }
    
    BOOL acceptDrag = NO;
    NSPasteboard *pboard = [sender draggingPasteboard];
    
    // If this is a file being dragged
    if ([[pboard types] containsObject:NSFilenamesPboardType] && acceptsFiles) {
        // Loop through files, see if any of the dragged files are acceptable
        NSArray *files = [pboard propertyListForType:NSFilenamesPboardType];
        
        for (NSString *file in files) {
            if ([self isAcceptableFileType:file]) {
                acceptDrag = YES;
            }
        }
    }
    // String
    else if ([[pboard types] containsObject:NSStringPboardType] && acceptsText) {
        acceptDrag = YES;
    }
        
    if (acceptDrag) {
        // Shade the window if interface type is droplet
        if (interfaceType == PlatypusInterfaceType_Droplet) {
            [dropletShaderView setAlphaValue:0.3];
            [dropletShaderView setHidden:NO];
        }
        return NSDragOperationLink;
    }
    
    return NSDragOperationNone;
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender {
    return YES;
}

- (void)draggingExited:(id <NSDraggingInfo>)sender {
    // Hide droplet shading on drag exit
    if (interfaceType == PlatypusInterfaceType_Droplet) {
        [dropletShaderView setHidden:YES];
    }
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    
    // Determine drag data type and dispatch to job queue
    if ([[pboard types] containsObject:NSStringPboardType]) {
        return [self addDroppedTextJob:[pboard stringForType:NSStringPboardType]];
    } else if ([[pboard types] containsObject:NSFilenamesPboardType]) {
        return [self addDroppedFilesJob:[pboard propertyListForType:NSFilenamesPboardType]];
    }
    return NO;
}

// Once the drag is over, we immediately execute w. files as arguments if not already processing
- (void)concludeDragOperation:(id <NSDraggingInfo>)sender {
    // Shade droplet
    if (interfaceType == PlatypusInterfaceType_Droplet) {
        [dropletShaderView setHidden:YES];
    }
    // Fire off the job queue if nothing is running
    if (!isTaskRunning && [jobQueue count] > 0) {
        [NSTimer scheduledTimerWithTimeInterval:0.0f target:self selector:@selector(executeScript) userInfo:nil repeats:NO];
    }
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender {
    // This is needed to keep link instead of the green plus sign on web view
    // and also required to reject non-acceptable dragged items
    return [self draggingEntered:sender];
}

#pragma mark - Web View

/**************************************************
 Called whenever web view re-renders.
 Scroll to the bottom on each re-rendering.
 **************************************************/

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    NSScrollView *scrollView = [[[[webView mainFrame] frameView] documentView] enclosingScrollView];
    NSRect bounds = [[[[webView mainFrame] frameView] documentView] bounds];
    [[scrollView documentView] scrollPoint:NSMakePoint(0, bounds.size.height)];
}

#pragma mark - Status Menu

/**************************************************
 Called whenever status item is clicked.  We run
 script, get output and generate menu with the ouput
 **************************************************/

- (void)menuNeedsUpdate:(NSMenu *)menu {
    
    // Run script and wait until we've received all the script output
    NSString *outputStr = [self executeScriptForStatusMenu];
    
    // Create an array of lines by separating output by newline
    NSMutableArray <NSString *> *lines = [[outputStr componentsSeparatedByString:@"\n"] mutableCopy];
    
    // Clean out any trailing newlines
    while ([[lines lastObject] isEqualToString:@""]) {
        [lines removeLastObject];
    }
    
    // Remove all items of previous output
    while ([statusItemMenu numberOfItems] > 2) {
        [statusItemMenu removeItemAtIndex:0];
    }
    
    // Populate menu with output from task
    for (NSInteger i = [lines count] - 1; i >= 0; i--) {
        NSString *line = lines[i];
        NSImage *icon = nil;
        
        // ---- creates a separator item
        if ([line hasPrefix:@"----"]) {
            [menu insertItem:[NSMenuItem separatorItem] atIndex:0];
            continue;
        }
        
        // Parse syntax setting item icon
        if ([line hasPrefix:@"MENUITEMICON|"]) {
            NSArray *tokens = [line componentsSeparatedByString:CMDLINE_ARG_SEPARATOR];
            if ([tokens count] < 3) {
                continue;
            }
            NSString *imageToken = tokens[1];
            // Is it a bundled image?
            icon = [NSImage imageNamed:imageToken];
            
            // If not, it could be a URL
            if (icon == nil) {
                // Or a file system path
                BOOL isDir;
                if ([FILEMGR fileExistsAtPath:imageToken isDirectory:&isDir] && !isDir) {
                    icon = [[NSImage alloc] initByReferencingFile:imageToken];
                } else {
                    NSURL *url = [NSURL URLWithString:imageToken];
                    if (url != nil) {
                        icon = [[NSImage alloc] initWithContentsOfURL:url];
                    }
                }
            }
            
            [icon setSize:NSMakeSize(16, 16)];
            line = tokens[2];
        }
        
        // Parse syntax to handle submenus
        NSMenu *submenu = nil;
        if ([line hasPrefix:@"SUBMENU|"]) {
            NSMutableArray *tokens = [[line componentsSeparatedByString:CMDLINE_ARG_SEPARATOR] mutableCopy];
            if ([tokens count] < 3) {
                continue;
            }
            NSString *menuName = tokens[1];
            [tokens removeObjectAtIndex:0];
            [tokens removeObjectAtIndex:0];
            
            // Create submenu
            submenu = [[NSMenu alloc] initWithTitle:menuName];
            for (NSString *t in tokens) {
                NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:t action:@selector(statusMenuItemSelected:) keyEquivalent:@""];
                [submenu addItem:item];
            }
            
            line = menuName;
        }
        
        // Create the menu item
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:line action:@selector(statusMenuItemSelected:) keyEquivalent:@""];
        if (submenu) {
            [menuItem setAction:nil];
            [menuItem setSubmenu:submenu];
        }
        
        // Set the formatted menu item string
        if (statusItemUsesSystemFont) {
            [menuItem setTitle:line];
        } else {
            // Create a dict of text attributes based on settings
            NSDictionary *textAttributes = @{NSForegroundColorAttributeName: textForegroundColor,
                                            NSFontAttributeName: textFont};
            
            NSAttributedString *attStr = [[NSAttributedString alloc] initWithString:line attributes:textAttributes];
            [menuItem setAttributedTitle:attStr];
        }
        
        if (icon != nil) {
            [menuItem setImage:icon];
        }
        
        [menu insertItem:menuItem atIndex:0];
    }
}

- (IBAction)statusMenuItemSelected:(id)sender {
    [self addMenuItemSelectedJob:[sender title]];
    if (!isTaskRunning && [jobQueue count] > 0) {
        [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(executeScript) userInfo:nil repeats:NO];
    }
}

#pragma mark - Window delegate methods

- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *win = [notification object];
    if (win == dropletWindow && interfaceType == PlatypusInterfaceType_Droplet) {
        [[NSApplication sharedApplication] terminate:self];
    }
}

#pragma mark - Utility methods

- (void)showNotification:(NSString *)notificationText {
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    [notification setTitle:appName];
    [notification setInformativeText:notificationText];
    [notification setSoundName:NSUserNotificationDefaultSoundName];
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

@end
