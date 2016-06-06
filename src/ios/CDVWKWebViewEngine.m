/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVWKWebViewEngine.h"
#import "CDVWKWebViewUIDelegate.h"
#import <Cordova/NSDictionary+CordovaPreferences.h>

#import <objc/message.h>

#define CDV_BRIDGE_NAME @"cordova"
#define CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR @"loadFileURL:allowingReadAccessToURL:"

@interface CDVWKWebViewEngine ()

@property (nonatomic, strong, readwrite) UIView* engineWebView;
@property (nonatomic, strong, readwrite) id <WKUIDelegate> uiDelegate;
@property (nonatomic, weak, readwrite) id <WKNavigationDelegate> navigationDelegate;

@end

// see forwardingTargetForSelector: selector comment for the reason for this pragma
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CDVWKWebViewEngine

@synthesize engineWebView = _engineWebView;
@synthesize pluginContext = _pluginContext;

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super init];
    if (self) {
        if (NSClassFromString(@"WKWebView") == nil) {
            return nil;
        }
        self.uiDelegate = [[CDVWKWebViewUIDelegate alloc] initWithTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]];

        WKUserContentController* userContentController = [[WKUserContentController alloc] init];
        [userContentController addScriptMessageHandler:self name:CDV_BRIDGE_NAME];

        WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
        configuration.userContentController = userContentController;

        // the configuration property on WKWebView has the 'copy' attribute, so any changes
        // to the configuration have to happen before the web view is initialized
        [self updateConfigSettings:self.commandDelegate.settings forConfig:configuration];
		
        WKWebView* wkWebView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];

        wkWebView.UIDelegate = self.uiDelegate;

        self.engineWebView = wkWebView;

        NSLog(@"Using WKWebView");
    }

    return self;
}

-(void) dispose
{
    WKWebView* wkWebView = (WKWebView*)_engineWebView;
    [wkWebView.configuration.userContentController removeScriptMessageHandlerForName:CDV_BRIDGE_NAME];
	wkWebView.UIDelegate = nil;
	wkWebView.navigationDelegate = nil;
	[wkWebView stopLoading];
    _engineWebView = nil;
}

- (void)pluginInitialize
{
    // viewController would be available now. we attempt to set all possible delegates to it, by default

    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    if ([self.viewController conformsToProtocol:@protocol(WKUIDelegate)]) {
        wkWebView.UIDelegate = (id <WKUIDelegate>)self.viewController;
    }

    if ([self.viewController conformsToProtocol:@protocol(WKNavigationDelegate)]) {
        wkWebView.navigationDelegate = (id <WKNavigationDelegate>)self.viewController;
    } else {
        wkWebView.navigationDelegate = (id <WKNavigationDelegate>)self;
    }

    if ([self.viewController conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
        [wkWebView.configuration.userContentController addScriptMessageHandler:(id < WKScriptMessageHandler >)self.viewController name:@"cordova"];
    }

    [self updateSettings:self.commandDelegate.settings];
}

- (id)loadRequest:(NSURLRequest*)request allowingReadAccessToURL:(NSURL*)readAccessUrl
{
    if ([self canLoadRequest:request]) { // can load, differentiate between file urls and other schemes
        if (request.URL.fileURL) {
            SEL wk_sel = NSSelectorFromString(CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR);
            NSURL* accessUrl = readAccessUrl ? readAccessUrl : [request.URL URLByDeletingLastPathComponent];
            return ((id (*)(id, SEL, id, id))objc_msgSend)(_engineWebView, wk_sel, request.URL, accessUrl);
        } else {
            return [(WKWebView*)_engineWebView loadRequest:request];
        }
    } else { // can't load, print out error
        NSString* errorHtml = [NSString stringWithFormat:
                               @"<!doctype html>"
                               @"<title>Error</title>"
                               @"<div style='font-size:2em'>"
                               @"   <p>The WebView engine '%@' is unable to load the request: %@</p>"
                               @"   <p>Most likely the cause of the error is that the loading of file urls is not supported in iOS %@.</p>"
                               @"</div>",
                               NSStringFromClass([self class]),
                               [request.URL description],
                               [[UIDevice currentDevice] systemVersion]
                               ];
        return [self loadHTMLString:errorHtml baseURL:nil];
    }
}

- (id)loadRequest:(NSURLRequest*)request
{
	return [self loadRequest:request allowingReadAccessToURL:nil];
}

- (id)loadHTMLString:(NSString*)string baseURL:(NSURL*)baseURL
{
    return [(WKWebView*)_engineWebView loadHTMLString:string baseURL:baseURL];
}

- (NSURL*) URL
{
    return [(WKWebView*)_engineWebView URL];
}

- (BOOL) canLoadRequest:(NSURLRequest*)request
{
    // See: https://issues.apache.org/jira/browse/CB-9636
    SEL wk_sel = NSSelectorFromString(CDV_WKWEBVIEW_FILE_URL_LOAD_SELECTOR);
    
    // if it's a file URL, check whether WKWebView has the selector (which is in iOS 9 and up only)
    if (request.URL.fileURL) {
        return [_engineWebView respondsToSelector:wk_sel];
    } else {
        return YES;
    }
}

- (void)updateConfigSettings:(NSDictionary*)settings forConfig:(WKWebViewConfiguration*)configuration
{
    configuration.preferences.minimumFontSize = [settings cordovaFloatSettingForKey:@"MinimumFontSize" defaultValue:0.0];
    configuration.allowsInlineMediaPlayback = [settings cordovaBoolSettingForKey:@"AllowInlineMediaPlayback" defaultValue:NO];
    configuration.suppressesIncrementalRendering = [settings cordovaBoolSettingForKey:@"SuppressesIncrementalRendering" defaultValue:NO];

    // for iOS 9, mediaPlaybackRequiresUserAction and mediaPlaybackAllowsAirPlay were deprecated in favor of
    // requiresUserActionForMediaPlayback and allowsAirPlayForMediaPlayback so map the config.xml settings accordingly
    if (IsAtLeastiOSVersion(@"9.0")) {
        configuration.requiresUserActionForMediaPlayback = [settings cordovaBoolSettingForKey:@"MediaPlaybackRequiresUserAction" defaultValue:YES];
        configuration.allowsAirPlayForMediaPlayback = [settings cordovaBoolSettingForKey:@"MediaPlaybackAllowsAirPlay" defaultValue:YES];
    } else {
        configuration.mediaPlaybackRequiresUserAction = [settings cordovaBoolSettingForKey:@"MediaPlaybackRequiresUserAction" defaultValue:YES];
        configuration.mediaPlaybackAllowsAirPlay = [settings cordovaBoolSettingForKey:@"MediaPlaybackAllowsAirPlay" defaultValue:YES];
    }
	
    /*
     configuration.preferences.javaScriptEnabled = [settings cordovaBoolSettingForKey:@"JavaScriptEnabled" default:YES];
     configuration.preferences.javaScriptCanOpenWindowsAutomatically = [settings cordovaBoolSettingForKey:@"JavaScriptCanOpenWindowsAutomatically" default:NO];
     */
}

- (void)updateSettings:(NSDictionary*)settings
{
    WKWebView* wkWebView = (WKWebView*)_engineWebView;
	
    // By default, DisallowOverscroll is false (thus bounce is allowed)
    BOOL bounceAllowed = !([settings cordovaBoolSettingForKey:@"DisallowOverscroll" defaultValue:NO]);
	
    // prevent webView from bouncing
    if (!bounceAllowed) {
        if ([wkWebView respondsToSelector:@selector(scrollView)]) {
            ((UIScrollView*)[wkWebView scrollView]).bounces = NO;
        } else {
            for (id subview in wkWebView.subviews) {
                if ([[subview class] isSubclassOfClass:[UIScrollView class]]) {
                    ((UIScrollView*)subview).bounces = NO;
                }
            }
        }
    }
}

- (void)updateWithInfo:(NSDictionary*)info
{
    NSDictionary* scriptMessageHandlers = [info objectForKey:kCDVWebViewEngineScriptMessageHandlers];
    NSDictionary* settings = [info objectForKey:kCDVWebViewEngineWebViewPreferences];
    id navigationDelegate = [info objectForKey:kCDVWebViewEngineWKNavigationDelegate];
    id uiDelegate = [info objectForKey:kCDVWebViewEngineWKUIDelegate];

    WKWebView* wkWebView = (WKWebView*)_engineWebView;

    if (scriptMessageHandlers && [scriptMessageHandlers isKindOfClass:[NSDictionary class]]) {
        NSArray* allKeys = [scriptMessageHandlers allKeys];

        for (NSString* key in allKeys) {
            id object = [scriptMessageHandlers objectForKey:key];
            if ([object conformsToProtocol:@protocol(WKScriptMessageHandler)]) {
                [wkWebView.configuration.userContentController addScriptMessageHandler:object name:key];
            }
        }
    }

    if (navigationDelegate && [navigationDelegate conformsToProtocol:@protocol(WKNavigationDelegate)]) {
        self.navigationDelegate = navigationDelegate;
    }

    if (uiDelegate && [uiDelegate conformsToProtocol:@protocol(WKUIDelegate)]) {
        wkWebView.UIDelegate = uiDelegate;
    }

    if (settings && [settings isKindOfClass:[NSDictionary class]]) {
        [self updateSettings:settings];
    }
}

// This forwards the methods that are in the header that are not implemented here.
// Both WKWebView and UIWebView implement the below:
//     loadHTMLString:baseURL:
//     loadRequest:
- (id)forwardingTargetForSelector:(SEL)aSelector
{
    return _engineWebView;
}

#pragma mark WKScriptMessageHandler implementation

- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
    if (![message.name isEqualToString:CDV_BRIDGE_NAME]) {
        return;
    }

    CDVViewController* vc = (CDVViewController*)self.viewController;

    NSArray* jsonEntry = message.body; // NSString:callbackId, NSString:service, NSString:action, NSArray:args
    CDVInvokedUrlCommand* command = [CDVInvokedUrlCommand commandFromJson:jsonEntry];
	command.pluginContext = self.pluginContext;
    CDV_EXEC_LOG(@"Exec(%@): Calling %@.%@", command.callbackId, command.className, command.methodName);

    if (![vc.commandQueue execute:command]) {
#ifdef DEBUG
        NSError* error = nil;
        NSString* commandJson = nil;
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:jsonEntry
                                                           options:0
                                                             error:&error];
        
        if (error == nil) {
            commandJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }

            static NSUInteger maxLogLength = 1024;
            NSString* commandString = ([commandJson length] > maxLogLength) ?
                [NSString stringWithFormat : @"%@[...]", [commandJson substringToIndex:maxLogLength]] :
                commandJson;

            NSLog(@"FAILED pluginJSON = %@", commandString);
#endif
    }
}

#pragma mark WKNavigationDelegate implementation

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
    if (_navigationDelegate && [_navigationDelegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)]) {
        [_navigationDelegate webView:webView didStartProvisionalNavigation:navigation];
    }

    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginResetNotification object:webView]];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
    if (_navigationDelegate && [_navigationDelegate respondsToSelector:@selector(webView:didFinishNavigation:)]) {
        [_navigationDelegate webView:webView didFinishNavigation:navigation];
    }

    CDVViewController* vc = (CDVViewController*)self.viewController;
    [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];
    
    [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPageDidLoadNotification object:webView]];
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation
{
    if (_navigationDelegate && [_navigationDelegate respondsToSelector:@selector(webView:didCommitNavigation:)]) {
        [_navigationDelegate webView:webView didCommitNavigation:navigation];
    }
}

- (void)webView:(WKWebView*)theWebView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
    CDVViewController* vc = (CDVViewController*)self.viewController;
    [CDVUserAgentUtil releaseLock:vc.userAgentLockToken];
}

- (BOOL)defaultResourcePolicyForURL:(NSURL*)url
{
    // all file:// urls are allowed
    if ([url isFileURL]) {
        return YES;
    }
    
    return NO;
}

-(void)decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL* url = [navigationAction.request URL];
    CDVViewController* vc = (CDVViewController*)self.viewController;
    
    /*
     * Give plugins the chance to handle the url
     */
    BOOL anyPluginsResponded = NO;
    BOOL shouldAllowRequest = NO;
    
    for (NSString* pluginName in vc.pluginObjects) {
        CDVPlugin* plugin = [vc.pluginObjects objectForKey:pluginName];
        SEL selector = NSSelectorFromString(@"shouldOverrideLoadWithRequest:navigationType:");
        if ([plugin respondsToSelector:selector]) {
            anyPluginsResponded = YES;
            shouldAllowRequest = (((BOOL (*)(id, SEL, id, int))objc_msgSend)(plugin, selector, navigationAction.request, navigationAction.navigationType));
            if (!shouldAllowRequest) {
                break;
            }
        }
    }
    
    if (anyPluginsResponded) {
        return decisionHandler(shouldAllowRequest);
    }
    
    /*
     * Handle all other types of urls (tel:, sms:), and requests to load a url in the main webview.
     */
    BOOL shouldAllowNavigation = [self defaultResourcePolicyForURL:url];
    if (shouldAllowNavigation) {
        return decisionHandler(WKNavigationActionPolicyAllow);
    } else {
        [[NSNotificationCenter defaultCenter] postNotification:[NSNotification notificationWithName:CDVPluginHandleOpenURLNotification object:url]];
    }
    
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (void) webView: (WKWebView *)webView decidePolicyForNavigationAction: (WKNavigationAction*)navigationAction decisionHandler: (void (^)(WKNavigationActionPolicy)) decisionHandler
{
    if (_navigationDelegate && [_navigationDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [_navigationDelegate webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:^(WKNavigationActionPolicy policy) {
            if (policy == WKNavigationActionPolicyAllow)
            {
                [self decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
            }
            else
            {
                decisionHandler(WKNavigationActionPolicyCancel);
            }
        }];
    }
    else
    {
        [self decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
    }
}
@end
