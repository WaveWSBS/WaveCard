#ifndef WAVECARD_WALLET_TRACE_FILTER_H
#define WAVECARD_WALLET_TRACE_FILTER_H

#import <Foundation/Foundation.h>
#include <stdlib.h>

// The transport must retain the complete formatted record, including embedded
// newlines: passIDs lists are often emitted as multiline NFC messages.
static BOOL WaveCardTraceLineHasPassSignal(NSString *line) {
    if (getenv("WAVECARD_SYSLOG_UNFILTERED")) return YES;
    static NSArray<NSString *> *existingSignals;
    static NSArray<NSString *> *walletSignals;
    static NSSet<NSString *> *walletProcesses;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        existingSignals = @[@"Passes/Cards", @".pkpass", @"NanoPasses", @".pkcache", @"passIDs"];
        walletSignals = @[@"PDCardFileManager:", @"PDPassLibrary:",
            @"VerificationCheck.", @"selected pass uniqueID", @"Dashboard loading"];
        walletProcesses = [NSSet setWithArray:@[@"passd", @"nanopassd", @"nfcd", @"passbook", @"wallet",
            @"walletuiservice", @"passbookuiservice", @"pdcardfilemanager", @"pdpasslibrary"]];
    });
    for (NSString *signal in existingSignals) {
        if ([line rangeOfString:signal options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    NSRange colon = [line rangeOfString:@":"];
    NSRange newline = [line rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]];
    if (colon.location == NSNotFound || (newline.location != NSNotFound && newline.location < colon.location)) return NO;
    NSString *header = [[line substringToIndex:colon.location] lowercaseString];
    NSRange opening = [header rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"(["]];
    NSString *process = opening.location == NSNotFound ? header : [header substringToIndex:opening.location];
    process = [[process stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lastPathComponent];
    NSString *module = @"";
    NSRange moduleStart = [header rangeOfString:@"("];
    if (moduleStart.location != NSNotFound) {
        module = [header substringFromIndex:NSMaxRange(moduleStart)];
        NSRange end = [module rangeOfString:@")"];
        if (end.location != NSNotFound) module = [module substringToIndex:end.location];
    }
    BOOL walletModule = [module hasPrefix:@"passkit"] || [module hasPrefix:@"passbook"] ||
        [module hasPrefix:@"wallet"] || [module hasPrefix:@"stockholm"];
    if (![walletProcesses containsObject:process] && !walletModule) return NO;
    for (NSString *signal in walletSignals) {
        if ([line rangeOfString:signal options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    // Keep activation diagnostics for future device-matched AID mapping, without
    // forwarding all NFC events or treating requestedApplet.identifier as a hash.
    return [line rangeOfString:@"setActivePaymentApplet" options:NSCaseInsensitiveSearch].location != NSNotFound &&
        [line rangeOfString:@"requestedApplet" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

#endif
