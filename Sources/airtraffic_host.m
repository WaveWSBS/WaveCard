#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>

typedef void *ATHostConnectionRef;

extern ATHostConnectionRef ATHostConnectionCreate(CFStringRef deviceIdentifier);
extern void ATHostConnectionRelease(ATHostConnectionRef connection);
extern void ATHostConnectionSendHostInfo(ATHostConnectionRef connection,
                                         CFDictionaryRef hostInfo);
extern void ATHostConnectionSendSyncRequest(ATHostConnectionRef connection,
                                            CFArrayRef dataclasses,
                                            CFDictionaryRef anchors,
                                            CFDictionaryRef hostInfo);
extern void ATHostConnectionSendMetadataSyncFinished(
    ATHostConnectionRef connection,
    CFDictionaryRef syncTypes,
    CFDictionaryRef anchors);
extern void ATHostConnectionSendAssetCompleted(ATHostConnectionRef connection,
                                               CFStringRef assetIdentifier,
                                               CFStringRef dataclass,
                                               CFStringRef assetPath);
extern void ATHostConnectionSendMessage(ATHostConnectionRef connection, CFDictionaryRef message);
extern unsigned int ATHostConnectionGetCurrentSessionNumber(ATHostConnectionRef connection);
extern unsigned int ATHostConnectionGetGrappaSessionId(ATHostConnectionRef connection);
extern CFDictionaryRef ATHostConnectionReadMessage(ATHostConnectionRef connection);
extern CFStringRef ATCFMessageGetName(CFDictionaryRef message);
extern CFTypeRef ATCFMessageGetParam(CFDictionaryRef message, CFStringRef key);

static volatile sig_atomic_t CurrentStage = 0;

static void TimeoutHandler(int signalNumber) {
    (void)signalNumber;
    // Only async-signal-safe writes are allowed here.
    const char prefix[] = "{\"ok\":false,\"error\":\"timeout\",\"stage\":\"";
    (void)write(STDOUT_FILENO, prefix, sizeof(prefix) - 1);
    switch (CurrentStage) {
        case 1: (void)write(STDOUT_FILENO, "wait-SyncAllowed", sizeof("wait-SyncAllowed") - 1); break;
        case 2: (void)write(STDOUT_FILENO, "wait-ReadyForSync", sizeof("wait-ReadyForSync") - 1); break;
        case 3: (void)write(STDOUT_FILENO, "wait-AssetManifest", sizeof("wait-AssetManifest") - 1); break;
        case 4: (void)write(STDOUT_FILENO, "complete-assets", sizeof("complete-assets") - 1); break;
        default: (void)write(STDOUT_FILENO, "connect", sizeof("connect") - 1); break;
    }
    if (CurrentStage >= 4) {
        const char suffix[] = "\",\"assetCompletionStarted\":true}\n";
        (void)write(STDOUT_FILENO, suffix, sizeof(suffix) - 1);
    } else {
        const char suffix[] = "\",\"assetCompletionStarted\":false}\n";
        (void)write(STDOUT_FILENO, suffix, sizeof(suffix) - 1);
    }
    _exit(124);
}

static void PrintJSON(NSDictionary *object) {
    if (object[@"ok"] && ![object[@"ok"] boolValue]) {
        NSMutableDictionary *result = object.mutableCopy;
        // Set the stage before sending any completion message. An interrupted
        // caller must preserve relocated originals unless this is explicitly false.
        result[@"assetCompletionStarted"] = CurrentStage >= 4 ? @YES : @NO;
        object = result;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:nil];
    if (!data) return;
    (void)write(STDOUT_FILENO, data.bytes, data.length);
    (void)write(STDOUT_FILENO, "\n", 1);
}

/// The legacy transport forwards Ping to its caller; reply on the active sync
/// session instead of treating heartbeats as readiness or resource messages.
static void ReplyToPing(ATHostConnectionRef connection, NSString *name) {
    if (![name isEqual:@"Ping"]) return;
    NSDictionary *pong = @{ @"Command": @"Pong",
        @"Session": @(ATHostConnectionGetCurrentSessionNumber(connection)) };
    ATHostConnectionSendMessage(connection, (__bridge CFDictionaryRef)pong);
    PrintJSON(@{ @"type": @"atc_message_sent", @"message": @"Pong" });
}

static NSDictionary *HostInfo(void) {
    return @{
        @"Type": @"iTunes",
        @"Version": @"13.7.0.161",
        @"MacOSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"SyncHostName": @"airlift",
        @"LibraryID": NSUUID.UUID.UUIDString,
        @"SyncedDataclasses": @[ @"Book" ],
        @"SyncedAssetTypes": @[ @"Book" ],
        @"Wakeable": @NO,
    };
}

static BOOL ManifestContains(NSDictionary *manifest, NSString *identifier) {
    NSArray *books = [manifest[@"Book"] isKindOfClass:NSArray.class]
        ? manifest[@"Book"] : nil;
    for (id entry in books) {
        if ([entry isKindOfClass:NSDictionary.class] &&
            [entry[@"AssetID"] isEqual:identifier] &&
            [entry[@"IsDownload"] isKindOfClass:NSNumber.class] &&
            [entry[@"IsDownload"] boolValue]) return YES;
    }
    return NO;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        CurrentStage = 0;
        BOOL probeOnly = argc == 3 && strcmp(argv[1], "--probe") == 0;
        if (!probeOnly && (argc < 6 || argc % 2 != 0)) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"usage: airtraffic_host udid id path [id path ...] | --probe udid" });
            return 64;
        }

        NSUInteger pairCount = probeOnly ? 0 : (NSUInteger)(argc - 2) / 2;
        if (pairCount > 2048) {
            PrintJSON(@{ @"ok": @NO, @"error": @"too many assets" });
            return 64;
        }

        NSString *deviceIdentifier = [NSString stringWithUTF8String:argv[probeOnly ? 2 : 1]];
        NSMutableArray<NSDictionary *> *assets = NSMutableArray.array;
        for (int index = probeOnly ? argc : 2; index < argc; index += 2) {
            NSString *identifier = [NSString stringWithUTF8String:argv[index]];
            NSString *destination =
                [NSString stringWithUTF8String:argv[index + 1]];
            if (!identifier.length || !destination.length) {
                PrintJSON(@{ @"ok": @NO, @"error": @"empty argument" });
                return 64;
            }
            [assets addObject:@{ @"identifier": identifier,
                                 @"destination": destination }];
        }
        if (!deviceIdentifier.length) {
            PrintJSON(@{ @"ok": @NO, @"error": @"empty device identifier" });
            return 64;
        }

        // A cold media-sync handshake can take longer than 30 seconds. Keep it
        // bounded, and allow an isolated diagnostic to select the same deadline.
        unsigned int readyTimeout = 90;
        const char *configuredTimeout = getenv("WAVECARD_ATC_READY_TIMEOUT");
        if (configuredTimeout) {
            BOOL digitsOnly = *configuredTimeout != '\0';
            for (const char *cursor = configuredTimeout; *cursor; cursor++) {
                if (*cursor < '0' || *cursor > '9') { digitsOnly = NO; break; }
            }
            char *end = NULL;
            long parsed = strtol(configuredTimeout, &end, 10);
            if (!digitsOnly || *end || parsed < 10 || parsed > 120) {
                PrintJSON(@{ @"ok": @NO, @"error": @"Ready timeout must be 10...120 seconds" });
                return 64;
            }
            readyTimeout = (unsigned int)parsed;
        }

        signal(SIGPIPE, SIG_IGN);
        signal(SIGALRM, TimeoutHandler);
        CurrentStage = 0;
        alarm(30);
        PrintJSON(@{ @"type": @"atc_stage", @"stage": @"connect" });
        ATHostConnectionRef connection =
            ATHostConnectionCreate((__bridge CFStringRef)deviceIdentifier);
        if (!connection) {
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"AirTraffic connection failed" });
            return 2;
        }

        CurrentStage = 1;
        alarm(30);
        PrintJSON(@{ @"type": @"atc_stage", @"stage": @"wait-SyncAllowed" });
        BOOL syncAllowed = NO;
        for (NSUInteger index = 0; index < 8 && !syncAllowed; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            ReplyToPing(connection, name);
            PrintJSON(@{ @"type": @"atc_message", @"stage": @"wait-SyncAllowed", @"message": name ?: @"unknown" });
            syncAllowed = [name isEqual:@"SyncAllowed"];
            BOOL failed = [name isEqual:@"SyncFailed"] || [name isEqual:@"SyncFinished"];
            CFRelease(raw);
            if (failed) {
                ATHostConnectionRelease(connection);
                PrintJSON(@{ @"ok": @NO, @"error": @"sync ended before readiness", @"stage": @"wait-SyncAllowed" });
                return 3;
            }
        }
        if (!syncAllowed) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"SyncAllowed not observed" });
            return 3;
        }

        NSDictionary *hostInfo = HostInfo();
        ATHostConnectionSendHostInfo(
            connection, (__bridge CFDictionaryRef)hostInfo);
        usleep(200000);
        ATHostConnectionSendSyncRequest(
            connection,
            (__bridge CFArrayRef)@[ @"Book" ],
            (__bridge CFDictionaryRef)@{},
            (__bridge CFDictionaryRef)hostInfo);
        PrintJSON(@{ @"type": @"atc_handshake_context",
                     @"initialized": ATHostConnectionGetGrappaSessionId(connection) != 0 ? @YES : @NO });

        CurrentStage = 2;
        alarm(readyTimeout);
        PrintJSON(@{ @"type": @"atc_stage", @"stage": @"wait-ReadyForSync" });
        BOOL ready = NO;
        for (NSUInteger index = 0; index < 12 && !ready; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            ReplyToPing(connection, name);
            PrintJSON(@{ @"type": @"atc_message", @"stage": @"wait-ReadyForSync", @"message": name ?: @"unknown" });
            ready = [name isEqual:@"ReadyForSync"];
            BOOL failed = [name isEqual:@"SyncFailed"] || [name isEqual:@"SyncFinished"];
            CFRelease(raw);
            if (failed) {
                ATHostConnectionRelease(connection);
                PrintJSON(@{ @"ok": @NO, @"error": @"sync ended before readiness", @"stage": @"wait-ReadyForSync" });
                return 3;
            }
        }
        if (!ready) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"ReadyForSync not observed" });
            return 4;
        }

        if (probeOnly) {
            ATHostConnectionRelease(connection);
            alarm(0);
            PrintJSON(@{ @"ok": @YES, @"probe": @YES, @"readyForSync": @YES });
            return 0;
        }

        ATHostConnectionSendMetadataSyncFinished(
            connection,
            (__bridge CFDictionaryRef)@{ @"Book": @1 },
            (__bridge CFDictionaryRef)@{});

        CurrentStage = 3;
        alarm(60);
        PrintJSON(@{ @"type": @"atc_stage", @"stage": @"wait-AssetManifest" });
        NSDictionary *manifest = nil;
        for (NSUInteger index = 0; index < 20 && !manifest; index++) {
            CFDictionaryRef raw = ATHostConnectionReadMessage(connection);
            if (!raw) {
                usleep(100000);
                continue;
            }
            NSString *name = (__bridge NSString *)ATCFMessageGetName(raw);
            ReplyToPing(connection, name);
            if ([name isEqual:@"AssetManifest"]) {
                id value = (__bridge id)ATCFMessageGetParam(
                    raw, CFSTR("AssetManifest"));
                if ([value isKindOfClass:NSDictionary.class])
                    manifest = [value copy];
            } else if ([name isEqual:@"SyncFailed"] ||
                       [name isEqual:@"SyncFinished"]) {
                CFRelease(raw);
                break;
            }
            CFRelease(raw);
        }

        if (!manifest) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO, @"error": @"AssetManifest not received",
                         @"stage": @"wait-AssetManifest" });
            return 6;
        }

        NSUInteger missing = 0;
        for (NSDictionary *asset in assets)
            if (!ManifestContains(manifest, asset[@"identifier"])) missing++;
        if (missing) {
            ATHostConnectionRelease(connection);
            PrintJSON(@{ @"ok": @NO,
                         @"error": @"expected assets absent from manifest",
                         @"missingCount": @(missing) });
            return 5;
        }

        CurrentStage = 4;
        alarm(60);
        PrintJSON(@{ @"type": @"atc_stage", @"stage": @"complete-assets" });
        for (NSUInteger index = 0; index < assets.count; index++) {
            NSDictionary *asset = assets[index];
            ATHostConnectionSendAssetCompleted(
                connection,
                (__bridge CFStringRef)asset[@"identifier"],
                CFSTR("Book"),
                (__bridge CFStringRef)asset[@"destination"]);
            if (index > 0) {
                NSString *leaf = [asset[@"destination"] lastPathComponent];
                PrintJSON(@{
                    @"type": @"atc_progress",
                    @"index": @(index),
                    @"total": @(assets.count - 1),
                    @"leaf": leaf ?: @"",
                });
            }
            if (index + 1 < assets.count) {
                if (index == 0) {
                    usleep(400000);
                } else {
                    usleep(60000);
                }
            }
        }
        sleep(2);
        ATHostConnectionRelease(connection);
        alarm(0);
        PrintJSON(@{ @"ok": @YES,
                     @"syncAllowed": @YES,
                     @"readyForSync": @YES,
                     @"fileCompleteMessages": @(assets.count) });
        return 0;
    }
}
