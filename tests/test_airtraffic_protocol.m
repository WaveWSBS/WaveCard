#import <Foundation/Foundation.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/wait.h>

static NSMutableArray<NSNumber *> *ScheduledAlarms;
static unsigned int ProtocolTestAlarm(unsigned int seconds) {
    [ScheduledAlarms addObject:@(seconds)];
    return 0;
}

// Exercise the real state machine with an in-memory transport. Only deliberate
// pacing sleeps are elided; all message parsing, validation and exits are real.
static unsigned int ProtocolTestSleep(unsigned int seconds) {
    (void)seconds;
    return 0;
}
static int ProtocolTestUSleep(useconds_t microseconds) {
    (void)microseconds;
    return 0;
}
#define main WaveCardAirTrafficMain
#define sleep ProtocolTestSleep
#define usleep ProtocolTestUSleep
#define alarm ProtocolTestAlarm
#include "../Sources/airtraffic_host.m"
#undef alarm
#undef usleep
#undef sleep
#undef main

static NSArray<NSDictionary *> *MockMessages;
static NSUInteger MockNextMessage;
static BOOL MockConnectionFails;
static NSUInteger CreateCalls;
static NSUInteger ReleaseCalls;
static NSUInteger SyncRequests;
static NSUInteger MetadataCompletions;
static NSUInteger ReadCalls;
static NSMutableArray<NSDictionary *> *CompletedAssets;
static NSMutableArray<NSDictionary *> *SentMessages;
static unsigned int MockCurrentSession;
static int Failures;
static int Assertions;

ATHostConnectionRef ATHostConnectionCreate(CFStringRef deviceIdentifier) {
    (void)deviceIdentifier;
    CreateCalls++;
    return MockConnectionFails ? NULL : (ATHostConnectionRef)0x1234;
}
void ATHostConnectionRelease(ATHostConnectionRef connection) {
    (void)connection;
    ReleaseCalls++;
}
void ATHostConnectionSendHostInfo(ATHostConnectionRef connection,
                                  CFDictionaryRef hostInfo) {
    (void)connection;
    (void)hostInfo;
}
void ATHostConnectionSendSyncRequest(ATHostConnectionRef connection,
                                     CFArrayRef dataclasses,
                                     CFDictionaryRef anchors,
                                     CFDictionaryRef hostInfo) {
    (void)connection;
    (void)dataclasses;
    (void)anchors;
    (void)hostInfo;
    SyncRequests++;
    MockCurrentSession += 7; // Deliberately differ from the incoming Ping's session.
}
void ATHostConnectionSendMessage(ATHostConnectionRef connection, CFDictionaryRef message) {
    (void)connection;
    [SentMessages addObject:[(__bridge NSDictionary *)message copy]];
}
unsigned int ATHostConnectionGetCurrentSessionNumber(ATHostConnectionRef connection) {
    (void)connection;
    return MockCurrentSession;
}
unsigned int ATHostConnectionGetGrappaSessionId(ATHostConnectionRef connection) {
    (void)connection;
    return SyncRequests ? 0x4a1b : 0;
}
void ATHostConnectionSendMetadataSyncFinished(ATHostConnectionRef connection,
                                             CFDictionaryRef syncTypes,
                                             CFDictionaryRef anchors) {
    (void)connection;
    (void)syncTypes;
    (void)anchors;
    MetadataCompletions++;
}
void ATHostConnectionSendAssetCompleted(ATHostConnectionRef connection,
                                        CFStringRef assetIdentifier,
                                        CFStringRef dataclass,
                                        CFStringRef assetPath) {
    (void)connection;
    [CompletedAssets addObject:@{
        @"identifier": (__bridge NSString *)assetIdentifier,
        @"dataclass": (__bridge NSString *)dataclass,
        @"path": (__bridge NSString *)assetPath,
    }];
}
CFDictionaryRef ATHostConnectionReadMessage(ATHostConnectionRef connection) {
    (void)connection;
    ReadCalls++;
    if (MockNextMessage >= MockMessages.count) return NULL;
    return CFRetain((__bridge CFDictionaryRef)MockMessages[MockNextMessage++]);
}
CFStringRef ATCFMessageGetName(CFDictionaryRef message) {
    return (__bridge CFStringRef)((__bridge NSDictionary *)message)[@"Command"];
}
CFTypeRef ATCFMessageGetParam(CFDictionaryRef message, CFStringRef key) {
    NSDictionary *params = ((__bridge NSDictionary *)message)[@"Params"];
    return (__bridge CFTypeRef)params[(__bridge NSString *)key];
}

static void Expect(BOOL condition, NSString *description) {
    Assertions++;
    if (!condition) Failures++;
    printf("%s - %s\n", condition ? "ok" : "not ok", description.UTF8String);
}

static NSDictionary *Message(NSString *name, id manifest) {
    return manifest
        ? @{ @"Command": name, @"Params": @{ @"AssetManifest": manifest } }
        : @{ @"Command": name };
}

static NSDictionary *RunScenarioMode(NSArray<NSDictionary *> *messages,
                                     BOOL connectionFails,
                                     BOOL invalidArguments,
                                     BOOL probeOnly) {
    MockMessages = messages;
    MockNextMessage = 0;
    MockConnectionFails = connectionFails;
    CreateCalls = ReleaseCalls = SyncRequests = MetadataCompletions = ReadCalls = 0;
    CompletedAssets = NSMutableArray.array;
    SentMessages = NSMutableArray.array;
    MockCurrentSession = 0;
    ScheduledAlarms = NSMutableArray.array;

    FILE *capture = tmpfile();
    if (!capture) {
        perror("tmpfile");
        exit(2);
    }
    fflush(stdout);
    int savedStdout = dup(STDOUT_FILENO);
    if (savedStdout < 0 || dup2(fileno(capture), STDOUT_FILENO) < 0) {
        perror("redirect stdout");
        exit(2);
    }
    const char *argv[] = {
        "airtraffic_host", "mock-device", "asset-a", "destination-a",
        "asset-b", "destination-b",
    };
    const char *probeArgv[] = { "airtraffic_host", "--probe", "mock-device" };
    int code = probeOnly
        ? WaveCardAirTrafficMain(3, probeArgv)
        : WaveCardAirTrafficMain(invalidArguments ? 2 : 6, argv);
    // Early-return paths normally end the process. This harness invokes main
    // repeatedly, so cancel each invocation's alarm explicitly.
    alarm(0);
    fflush(stdout);
    if (dup2(savedStdout, STDOUT_FILENO) < 0) {
        perror("restore stdout");
        exit(2);
    }
    close(savedStdout);
    fseek(capture, 0, SEEK_END);
    long length = ftell(capture);
    rewind(capture);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)MAX(length, 0)];
    if (data.length && fread(data.mutableBytes, 1, data.length, capture) != data.length) {
        perror("read capture");
        exit(2);
    }
    fclose(capture);

    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSMutableArray<NSDictionary *> *events = NSMutableArray.array;
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id event = lineData.length
            ? [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil] : nil;
        if ([event isKindOfClass:NSDictionary.class]) [events addObject:event];
    }
    if (code != 0) {
        id completion = events.lastObject[@"assetCompletionStarted"];
        Expect(completion && CFGetTypeID((__bridge CFTypeRef)completion) == CFBooleanGetTypeID() &&
               ![completion boolValue], @"every pre-transfer terminal error explicitly proves completion never started");
    }
    return @{ @"code": @(code), @"events": events,
              @"result": events.lastObject ?: @{}, @"output": output ?: @"" };
}

static NSDictionary *RunScenario(NSArray<NSDictionary *> *messages,
                                 BOOL connectionFails,
                                 BOOL invalidArguments) {
    return RunScenarioMode(messages, connectionFails, invalidArguments, NO);
}

static NSDictionary *RunProbe(NSArray<NSDictionary *> *messages, BOOL connectionFails) {
    return RunScenarioMode(messages, connectionFails, NO, YES);
}

static void TestTimeoutRecoveryContract(void) {
    for (int stage = 0; stage <= 4; stage++) {
        int descriptors[2];
        if (pipe(descriptors) != 0) exit(2);
        pid_t child = fork();
        if (child < 0) exit(2);
        if (child == 0) {
            close(descriptors[0]);
            dup2(descriptors[1], STDOUT_FILENO);
            close(descriptors[1]);
            CurrentStage = stage;
            TimeoutHandler(SIGALRM);
            _exit(99);
        }
        close(descriptors[1]);
        NSMutableData *data = NSMutableData.data;
        char buffer[512];
        ssize_t count;
        while ((count = read(descriptors[0], buffer, sizeof(buffer))) > 0)
            [data appendBytes:buffer length:(NSUInteger)count];
        close(descriptors[0]);
        int status = 0;
        waitpid(child, &status, 0);
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        id completion = result[@"assetCompletionStarted"];
        Expect(WIFEXITED(status) && WEXITSTATUS(status) == 124,
               @"signal deadline exits with the timeout status");
        Expect(completion && CFGetTypeID((__bridge CFTypeRef)completion) == CFBooleanGetTypeID() &&
               [completion boolValue] == (stage >= 4),
               @"signal deadline distinguishes pre-transfer from potentially relocated originals");
    }
}

int main(void) {
    @autoreleasepool {
        TestTimeoutRecoveryContract();
        const char *previousTimeout = getenv("WAVECARD_ATC_READY_TIMEOUT");
        NSString *savedTimeout = previousTimeout ? [NSString stringWithUTF8String:previousTimeout] : nil;
        unsetenv("WAVECARD_ATC_READY_TIMEOUT");
        NSDictionary *allowed = Message(@"SyncAllowed", nil);
        NSDictionary *ready = Message(@"ReadyForSync", nil);
        NSDictionary *failed = Message(@"SyncFailed", nil);
        NSDictionary *finished = Message(@"SyncFinished", nil);

        NSDictionary *run = RunProbe(@[allowed, ready, failed], NO);
        Expect([run[@"code"] intValue] == 0 && [run[@"result"][@"ok"] boolValue] &&
               [run[@"result"][@"probe"] boolValue] && [run[@"result"][@"readyForSync"] boolValue],
               @"readiness probe reports a successful handshake");
        Expect(SyncRequests == 1 && MetadataCompletions == 0 && CompletedAssets.count == 0,
               @"probe mode sends no metadata completion or asset transfer");
        Expect(MockNextMessage == 2 && ReleaseCalls == 1,
               @"probe returns and releases immediately after ReadyForSync");
        Expect([ScheduledAlarms containsObject:@90], @"default readiness deadline is 90 seconds");

        NSMutableArray<NSDictionary *> *handshakeContexts = NSMutableArray.array;
        for (NSDictionary *event in run[@"events"]) {
            if ([event[@"type"] isEqual:@"atc_handshake_context"]) [handshakeContexts addObject:event];
        }
        Expect(handshakeContexts.count == 1, @"sync request logs exactly one handshake-initialization context");
        NSDictionary *context = handshakeContexts.firstObject ?: @{};
        id initialized = context[@"initialized"];
        Expect(initialized && CFGetTypeID((__bridge CFTypeRef)initialized) == CFBooleanGetTypeID() && [initialized boolValue],
               @"handshake context reports initialization as a JSON boolean");
        Expect([[NSSet setWithArray:context.allKeys] isEqual:[NSSet setWithArray:@[@"type", @"initialized"]]],
               @"handshake context contains no session identifier or authentication-material fields");

        run = RunProbe(@[allowed, failed], NO);
        Expect([run[@"code"] intValue] == 3 && ![run[@"result"][@"ok"] boolValue],
               @"probe reports a rejected handshake as failure");
        Expect(MetadataCompletions == 0 && CompletedAssets.count == 0 && ReleaseCalls == 1,
               @"failed probe sends no metadata or assets and releases its connection");

        for (NSString *invalidTimeout in @[@"", @"9", @"121", @"30s", @" 10", @"+10"]) {
            setenv("WAVECARD_ATC_READY_TIMEOUT", invalidTimeout.UTF8String, 1);
            run = RunProbe(@[allowed, ready], NO);
            Expect([run[@"code"] intValue] == 64 && CreateCalls == 0 && ScheduledAlarms.count == 0,
                   [NSString stringWithFormat:@"invalid readiness timeout '%@' is rejected before connecting", invalidTimeout]);
            Expect([run[@"result"][@"error"] isEqual:@"Ready timeout must be 10...120 seconds"],
                   @"invalid timeout has a structured configuration error");
        }
        for (NSNumber *validTimeout in @[@10, @37, @120]) {
            setenv("WAVECARD_ATC_READY_TIMEOUT", validTimeout.stringValue.UTF8String, 1);
            run = RunProbe(@[allowed, ready], NO);
            Expect([run[@"code"] intValue] == 0 && [ScheduledAlarms containsObject:validTimeout],
                   [NSString stringWithFormat:@"valid readiness timeout %@ is applied", validTimeout]);
            Expect(MetadataCompletions == 0 && CompletedAssets.count == 0,
                   @"timeout overrides do not change non-mutating probe behavior");
        }
        unsetenv("WAVECARD_ATC_READY_TIMEOUT");

        run = RunScenario(@[], YES, NO);
        Expect([run[@"code"] intValue] == 2, @"connection creation failure is reported");
        Expect([run[@"result"][@"error"] isEqual:@"AirTraffic connection failed"], @"connection failure has a structured reason");
        Expect(CreateCalls == 1 && ReleaseCalls == 0 && SyncRequests == 0,
               @"failed creation never starts sync or releases an invalid connection");

        run = RunScenario(@[], NO, YES);
        Expect([run[@"code"] intValue] == 64 && CreateCalls == 0,
               @"invalid arguments are rejected before opening a connection");

        run = RunScenario(@[failed], NO, NO);
        Expect([run[@"code"] intValue] == 3, @"SyncFailed before SyncAllowed ends the handshake");
        Expect([run[@"result"][@"stage"] isEqual:@"wait-SyncAllowed"], @"early failure identifies its handshake stage");
        Expect(SyncRequests == 0 && MetadataCompletions == 0 && CompletedAssets.count == 0,
               @"early failure sends no sync request, metadata completion or asset messages");
        Expect(ReleaseCalls == 1, @"early failure releases its connection exactly once");

        run = RunScenario(@[allowed, failed], NO, NO);
        Expect([run[@"code"] intValue] == 3, @"SyncFailed while waiting for ReadyForSync ends the handshake");
        Expect([run[@"result"][@"stage"] isEqual:@"wait-ReadyForSync"], @"readiness failure identifies its stage");
        Expect(SyncRequests == 1 && MetadataCompletions == 0 && CompletedAssets.count == 0,
               @"readiness failure cannot advance to asset completion");
        Expect(ReleaseCalls == 1, @"readiness failure releases its connection exactly once");

        NSDictionary *ping = @{ @"Command": @"Ping", @"Session": @0, @"Id": @99, @"Type": @0 };
        run = RunScenario(@[allowed, ping, failed], NO, NO);
        Expect([run[@"code"] intValue] == 3 && [run[@"result"][@"stage"] isEqual:@"wait-ReadyForSync"],
               @"Ping does not satisfy the readiness transition");
        Expect([SentMessages isEqual:@[@{ @"Command": @"Pong", @"Session": @7 }]],
               @"readiness heartbeat emits only legacy Pong and the active session, without copying Type or Id");
        Expect(MetadataCompletions == 0 && CompletedAssets.count == 0,
               @"readiness heartbeat cannot trigger metadata or asset transfer");

        run = RunScenario(@[allowed, ready, ping, failed], NO, NO);
        Expect([run[@"code"] intValue] == 6, @"Ping does not satisfy the asset-manifest transition");
        Expect([SentMessages isEqual:@[@{ @"Command": @"Pong", @"Session": @7 }]],
               @"manifest heartbeat is answered on the active sync session");
        Expect(MetadataCompletions == 1 && CompletedAssets.count == 0 && ReleaseCalls == 1,
               @"manifest heartbeat causes no asset transfer and preserves failure cleanup");

        run = RunScenario(@[ping, failed], NO, NO);
        Expect([run[@"code"] intValue] == 3 && SyncRequests == 0,
               @"Ping before SyncAllowed does not start a sync request");
        Expect([SentMessages isEqual:@[@{ @"Command": @"Pong", @"Session": @0 }]],
               @"pre-sync heartbeat uses the current pre-sync session");

        for (NSDictionary *terminal in @[failed, finished]) {
            run = RunScenario(@[allowed, ready, terminal], NO, NO);
            NSString *name = terminal[@"Command"];
            Expect([run[@"code"] intValue] == 6,
                   [NSString stringWithFormat:@"%@ before manifest is a manifest-stage failure", name]);
            Expect([run[@"result"][@"error"] isEqual:@"AssetManifest not received"],
                   [NSString stringWithFormat:@"%@ is not misclassified as missing files", name]);
            Expect([run[@"result"][@"stage"] isEqual:@"wait-AssetManifest"], @"manifest failure identifies its stage");
            Expect(CompletedAssets.count == 0 && MetadataCompletions == 1 && ReleaseCalls == 1,
                   @"terminal sync response sends no assets and releases the connection");
        }

        run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @"invalid shape")], NO, NO);
        Expect([run[@"code"] intValue] == 6, @"malformed manifest cannot be treated as an empty valid manifest");
        Expect(ReadCalls <= 22 && CompletedAssets.count == 0, @"an exhausted mock transport exits after bounded reads");

        run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @{ @"Book": @[] })], NO, NO);
        Expect([run[@"code"] intValue] == 5, @"completed empty manifest reports unavailable expected assets");
        Expect([run[@"result"][@"error"] isEqual:@"expected assets absent from manifest"], @"only a received valid manifest yields the filename-fallback error");
        Expect([run[@"result"][@"missingCount"] intValue] == 2 && CompletedAssets.count == 0,
               @"empty manifest counts all missing assets without sending any");

        NSDictionary *a = @{ @"AssetID": @"asset-a", @"IsDownload": @YES };
        NSDictionary *b = @{ @"AssetID": @"asset-b", @"IsDownload": @YES };
        NSDictionary *unrelated = @{ @"AssetID": @"unrelated", @"IsDownload": @YES };
        run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @{ @"Book": @[a, unrelated] })], NO, NO);
        Expect([run[@"code"] intValue] == 5 && [run[@"result"][@"missingCount"] intValue] == 1,
               @"partial manifest reports the exact missing expected count");
        Expect(CompletedAssets.count == 0, @"partial manifest cannot send a partially validated asset set");

        NSDictionary *notDownload = @{ @"AssetID": @"asset-b", @"IsDownload": @NO };
        run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @{ @"Book": @[a, notDownload] })], NO, NO);
        Expect([run[@"code"] intValue] == 5 && [run[@"result"][@"missingCount"] intValue] == 1,
               @"an identifier without download permission is not accepted");

        // Device-provided plist fields must not receive NSNumber messages unless
        // they are numbers. Both values previously raised boolValue exceptions.
        for (id invalidDownload in @[NSNull.null, @[@YES]]) {
            NSDictionary *invalid = @{ @"AssetID": @"asset-b", @"IsDownload": invalidDownload };
            run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @{ @"Book": @[a, invalid] })], NO, NO);
            NSString *kind = [invalidDownload isKindOfClass:NSArray.class] ? @"array" : @"NSNull";
            Expect([run[@"code"] intValue] == 5,
                   [NSString stringWithFormat:@"%@ IsDownload exits with a structured missing-assets failure", kind]);
            Expect([run[@"result"][@"error"] isEqual:@"expected assets absent from manifest"] &&
                   [run[@"result"][@"missingCount"] intValue] == 1,
                   @"invalid download flag is counted as missing without throwing");
            Expect(CompletedAssets.count == 0 && ReleaseCalls == 1,
                   @"invalid download flag sends no assets and releases its connection");
        }

        run = RunScenario(@[allowed, ready, Message(@"AssetManifest", @{ @"Book": @[a, b, unrelated] })], NO, NO);
        Expect([run[@"code"] intValue] == 0 && [run[@"result"][@"ok"] boolValue], @"complete manifest finishes successfully");
        Expect([run[@"result"][@"fileCompleteMessages"] intValue] == 2, @"success reports the expected number of asset messages");
        Expect([CompletedAssets isEqual:@[
            @{ @"identifier": @"asset-a", @"dataclass": @"Book", @"path": @"destination-a" },
            @{ @"identifier": @"asset-b", @"dataclass": @"Book", @"path": @"destination-b" },
        ]], @"only explicitly requested assets are sent, once each and in order");
        Expect(SyncRequests == 1 && MetadataCompletions == 1 && ReleaseCalls == 1,
               @"successful sync sends each handshake transition and releases once");

        if (savedTimeout) setenv("WAVECARD_ATC_READY_TIMEOUT", savedTimeout.UTF8String, 1);
        else unsetenv("WAVECARD_ATC_READY_TIMEOUT");
        const char *restoredTimeout = getenv("WAVECARD_ATC_READY_TIMEOUT");
        Expect(savedTimeout ? (restoredTimeout && [savedTimeout isEqualToString:[NSString stringWithUTF8String:restoredTimeout]]) : !restoredTimeout,
               @"readiness timeout environment is restored after the suite");
        printf("%d assertions, %d failures\n", Assertions, Failures);
        return Failures ? 1 : 0;
    }
}
