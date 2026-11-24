#import "Shared.h"
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>
#import <time.h>

NSString *const ZKGroupID = @"group.com.zakatrans.livecap";
NSString *const ZKNotifySub = @"com.zakatrans.livecap.subtitle";
NSString *const ZKNotifyLog = @"com.zakatrans.livecap.log";

static NSString *const kGlobalDirA = @"/var/mobile/Library/Application Support/LiveCap";
static NSString *const kGlobalDirB = @"/private/var/mobile/Library/Application Support/LiveCap";

@implementation ZKStore

+ (BOOL)isExtension {
    NSString *b = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return [b hasSuffix:@".ext"];
}

+ (BOOL)writable:(NSString *)p {
    if (!p.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    @try {
        if (![fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil]) {
            BOOL isDir = NO;
            if (!([fm fileExistsAtPath:p isDirectory:&isDir] && isDir)) return NO;
        }
        NSString *t = [p stringByAppendingPathComponent:@".zk_probe"];
        if ([@"1" writeToFile:t atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            [fm removeItemAtPath:t error:nil];
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// 扫描容器目录，找出录屏扩展自己的数据目录（主 App 侧才需要）
+ (NSArray<NSString *> *)extDirs {
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *out = [NSMutableArray array];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *base = @"/var/mobile/Containers/Data/Application";
        NSArray *names = [fm contentsOfDirectoryAtPath:base error:nil];
        for (NSString *n in names) {
            @try {
                NSString *c = [base stringByAppendingPathComponent:n];
                NSString *meta = [c stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
                NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:meta];
                NSString *bid = m[@"MCMMetadataIdentifier"];
                if (![bid isKindOfClass:[NSString class]]) continue;
                if ([bid hasPrefix:@"com.zakatrans.livecap"]) {
                    NSString *docs = [c stringByAppendingPathComponent:@"Documents/LiveCap"];
                    if (![out containsObject:docs]) [out addObject:docs];
                    if (![out containsObject:c]) [out addObject:c];
                }
            } @catch (__unused NSException *e) {}
        }
        // 固定路径也放进候选（若两端都拿到了全局权限，就落在这里）
        for (NSString *g in @[kGlobalDirA, kGlobalDirB]) {
            if (![out containsObject:g]) [out addObject:g];
        }
        cached = out;
    });
    return cached;
}

+ (NSArray<NSString *> *)dirs {
    static NSArray *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *cands = [NSMutableArray array];

        // 1) 全局固定路径（TrollStore + 放开沙箱时两端共用）
        [cands addObject:kGlobalDirA];
        [cands addObject:kGlobalDirB];

        // 2) App Group（有 provisioning 授权时有效）
        @try {
            NSURL *u = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:ZKGroupID];
            if (u.path.length) [cands addObject:[u.path stringByAppendingPathComponent:@"LiveCap"]];
        } @catch (__unused NSException *e) {}

        // 3) 自己的沙箱 Documents
        @try {
            NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            if (d.length) [cands addObject:[d stringByAppendingPathComponent:@"LiveCap"]];
        } @catch (__unused NSException *e) {}

        // 4) 扩展容器（主 App 能写进去，方便把设置递给扩展）
        if (![self isExtension]) {
            for (NSString *d in [self extDirs]) {
                if ([d hasSuffix:@"/Documents/LiveCap"]) [cands addObject:d];
            }
        }

        NSMutableArray *ok = [NSMutableArray array];
        for (NSString *p in cands) {
            if ([ok containsObject:p]) continue;
            if ([self writable:p]) [ok addObject:p];
        }
        if (!ok.count) {
            NSString *t = [NSTemporaryDirectory() stringByAppendingPathComponent:@"LiveCap"];
            [self writable:t];
            [ok addObject:t];
        }
        cached = ok;
    });
    return cached;
}

+ (NSString *)dir { NSArray *d = [self dirs]; return d.count ? d.firstObject : NSTemporaryDirectory(); }

+ (NSString *)path:(NSString *)name { return [[self dir] stringByAppendingPathComponent:name]; }

+ (NSArray<NSString *> *)readPathsFor:(NSString *)name {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *d in [self dirs]) {
        NSString *p = [d stringByAppendingPathComponent:name];
        if (![a containsObject:p]) [a addObject:p];
    }
    if (![self isExtension]) {
        for (NSString *d in [self extDirs]) {
            NSString *p = [d stringByAppendingPathComponent:name];
            if (![a containsObject:p]) [a addObject:p];
        }
    }
    return a;
}

+ (NSDictionary *)read:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    NSTimeInterval bestT = -1;
    for (NSString *p in [self readPathsFor:name]) {
        @try {
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            if (!at) continue;
            NSTimeInterval t = [at[NSFileModificationDate] timeIntervalSince1970];
            if (t > bestT) { bestT = t; best = p; }
        } @catch (__unused NSException *e) {}
    }
    if (!best) return @{};
    @try {
        NSData *d = [NSData dataWithContentsOfFile:best];
        if (!d) return @{};
        id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        return [o isKindOfClass:[NSDictionary class]] ? o : @{};
    } @catch (__unused NSException *e) { return @{}; }
}

+ (void)writeData:(NSData *)d to:(NSString *)name {
    if (!d) return;
    for (NSString *dir in [self dirs]) {
        @try { [d writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]; }
        @catch (__unused NSException *e) {}
    }
}

+ (void)write:(NSDictionary *)dict to:(NSString *)name {
    @try {
        NSData *d = [NSJSONSerialization dataWithJSONObject:dict ?: @{} options:0 error:nil];
        [self writeData:d to:name];
    } @catch (__unused NSException *e) {}
}

+ (NSString *)setting:(NSString *)k {
    @try {
        NSString *v = [self read:@"zk_settings.json"][k];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (__unused NSException *e) { return nil; }
}

+ (void)setSetting:(NSString *)k v:(NSString *)v {
    @try {
        NSMutableDictionary *d = [[self read:@"zk_settings.json"] mutableCopy] ?: [NSMutableDictionary dictionary];
        if (v) d[k] = v; else [d removeObjectForKey:k];
        [self write:d to:@"zk_settings.json"];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 翻译上下文

// 当前会话号：只在内存里缓存，换了会话立刻更新。
// 写成 static 是为了 appendLine 这种高频调用不用每次都读盘。
static NSString *_zkSid = nil;

+ (NSString *)sessionId {
    if (_zkSid.length) return _zkSid;
    @try {
        NSString *s = [self read:@"zk_session.json"][@"sid"];
        if ([s isKindOfClass:[NSString class]] && s.length) { _zkSid = [s copy]; return _zkSid; }
    } @catch (__unused NSException *e) {}
    // 老版本升级上来还没有会话文件：现造一个
    NSString *s = [NSString stringWithFormat:@"%.0f", [NSDate date].timeIntervalSince1970 * 1000];
    _zkSid = [s copy];
    [self write:@{@"sid": s} to:@"zk_session.json"];
    return _zkSid;
}

+ (void)beginNewSession {
    NSString *s = [NSString stringWithFormat:@"%.0f-%u",
                   [NSDate date].timeIntervalSince1970 * 1000, (unsigned)arc4random_uniform(9999)];
    _zkSid = [s copy];
    [self write:@{@"sid": s} to:@"zk_session.json"];
    [self write:@{@"lines": @[]} to:@"zk_lines.json"];
    [self write:@{@"pairs": @[]} to:@"zk_ctx.json"];
    [self write:@{@"orig": @"", @"trans": @""} to:@"zk_sub.json"];
}

+ (NSArray<NSDictionary *> *)ctxPairs {
    @try {
        NSDictionary *d = [self read:@"zk_ctx.json"];
        NSArray *a = d[@"pairs"];
        if (![a isKindOfClass:[NSArray class]]) return @[];
        NSString *sid = [self sessionId];
        NSMutableArray *out = [NSMutableArray array];
        for (id raw in a) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            id s = ((NSDictionary *)raw)[@"sid"];
            if (![s isKindOfClass:[NSString class]] || ![s isEqualToString:sid]) continue;  // 上一场的，丢掉
            [out addObject:raw];
        }
        return out;
    } @catch (__unused NSException *e) { return @[]; }
}

+ (void)pushCtxPair:(NSString *)en zh:(NSString *)zh {
    if (!en.length || !zh.length) return;
    @try {
        NSMutableArray *a = [[self ctxPairs] mutableCopy] ?: [NSMutableArray array];
        [a addObject:@{@"en": en, @"zh": zh, @"sid": [self sessionId]}];
        // 只留最近 10 句：再多对速度没好处，也容易跑题
        while (a.count > 10) [a removeObjectAtIndex:0];
        [self write:@{@"pairs": a} to:@"zk_ctx.json"];
    } @catch (__unused NSException *e) {}
}

+ (void)clearCtx {
    [self write:@{@"pairs": @[]} to:@"zk_ctx.json"];
}

+ (void)setSubtitle:(NSString *)orig trans:(NSString *)trans {
    @try {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"orig"] = orig ?: @"";
        if (trans) d[@"trans"] = trans;
        d[@"t"] = @([[NSDate date] timeIntervalSince1970]);
        [self write:d to:@"zk_sub.json"];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)ZKNotifySub, NULL, NULL, true);
    } @catch (__unused NSException *e) {}
}

+ (NSDictionary *)subtitle { return [self read:@"zk_sub.json"]; }

#pragma mark - 字幕流（长文本阅读模式）

// 最多留 60 句：画中画里只看得见最后几行，留太多只会拖慢每次重排
#define ZK_LINES_MAX 60

+ (NSArray<NSDictionary *> *)lines {
    NSDictionary *d = [self read:@"zk_lines.json"];
    NSArray *a = d[@"lines"];
    if (![a isKindOfClass:[NSArray class]]) return @[];
    NSString *sid = [self sessionId];
    NSMutableArray *out = [NSMutableArray array];
    for (id raw in a) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        id s = ((NSDictionary *)raw)[@"sid"];
        if (![s isKindOfClass:[NSString class]] || ![s isEqualToString:sid]) continue;  // 上一场的，不带进来
        [out addObject:raw];
    }
    return out;
}

+ (void)appendLineEn:(NSString *)en zh:(NSString *)zh {
    if (!en.length && !zh.length) return;
    @try {
        NSMutableArray *a = [[self lines] mutableCopy] ?: [NSMutableArray array];
        [a addObject:@{@"en": en ?: @"", @"zh": zh ?: @"", @"sid": [self sessionId],
                       @"t": @([[NSDate date] timeIntervalSince1970])}];
        while (a.count > ZK_LINES_MAX) [a removeObjectAtIndex:0];
        [self write:@{@"lines": a} to:@"zk_lines.json"];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)ZKNotifySub, NULL, NULL, true);
    } @catch (__unused NSException *e) {}
}

+ (void)updateLastLineZh:(NSString *)zh {
    if (!zh.length) return;
    @try {
        NSDictionary *d = [self read:@"zk_lines.json"];
        NSArray *raw = d[@"lines"];
        if (![raw isKindOfClass:[NSArray class]] || !raw.count) return;
        NSMutableArray *a = [raw mutableCopy];
        NSString *sid = [self sessionId];
        // 从后往前找当前会话的最后一行：译文可能连补两次（分段），每次都补到最后一行
        for (NSInteger i = (NSInteger)a.count - 1; i >= 0; i--) {
            id o = a[(NSUInteger)i];
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            NSString *s = ((NSDictionary *)o)[@"sid"];
            if (![s isKindOfClass:[NSString class]] || ![s isEqualToString:sid]) continue;
            NSMutableDictionary *m = [((NSDictionary *)o) mutableCopy];
            NSString *old = m[@"zh"];
            if ([old isKindOfClass:[NSString class]] && old.length) return;   // 已经有译文了，不覆盖
            m[@"zh"] = zh;
            a[(NSUInteger)i] = m;
            [self write:@{@"lines": a} to:@"zk_lines.json"];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)ZKNotifySub, NULL, NULL, true);
            return;
        }
    } @catch (__unused NSException *e) {}
}

// 精确版：从后往前找原文完全相同的那一行
+ (void)updateLineZh:(NSString *)zh forEn:(NSString *)en {
    if (!zh.length || !en.length) return;
    @try {
        NSDictionary *d = [self read:@"zk_lines.json"];
        NSArray *raw = d[@"lines"];
        if (![raw isKindOfClass:[NSArray class]] || !raw.count) return;
        NSMutableArray *a = [raw mutableCopy];
        NSString *sid = [self sessionId];
        for (NSInteger i = (NSInteger)a.count - 1; i >= 0; i--) {
            id o = a[(NSUInteger)i];
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *dd = (NSDictionary *)o;
            NSString *s = dd[@"sid"];
            if (![s isKindOfClass:[NSString class]] || ![s isEqualToString:sid]) continue;
            NSString *e = dd[@"en"];
            if (![e isKindOfClass:[NSString class]] || ![e isEqualToString:en]) continue;
            NSMutableDictionary *m = [dd mutableCopy];
            NSString *old = m[@"zh"];
            if ([old isKindOfClass:[NSString class]] && old.length) return;
            m[@"zh"] = zh;
            a[(NSUInteger)i] = m;
            [self write:@{@"lines": a} to:@"zk_lines.json"];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)ZKNotifySub, NULL, NULL, true);
            return;
        }
    } @catch (__unused NSException *e) {}
}

+ (void)clearLines {
    [self write:@{@"lines": @[]} to:@"zk_lines.json"];
}

+ (void)log:(NSString *)fmt, ... {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@%@\n", [f stringFromDate:[NSDate date]],
                          [self isExtension] ? @"[ext] " : @"", s];
        NSString *name = [self isExtension] ? @"zk_ext_log.txt" : @"zk_log.txt";
        for (NSString *dir in [self dirs]) {
            NSString *p = [dir stringByAppendingPathComponent:name];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (__unused NSException *e) {}
}

+ (NSString *)tailOf:(NSString *)p lines:(NSInteger)n {
    @try {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!s.length) return nil;
        NSArray *lines = [s componentsSeparatedByString:@"\n"];
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *l in lines) if (l.length) [keep addObject:l];
        if ((NSInteger)keep.count > n) keep = [[keep subarrayWithRange:NSMakeRange(keep.count - n, n)] mutableCopy];
        return [keep componentsJoinedByString:@"\n"];
    } @catch (__unused NSException *e) { return nil; }
}

+ (NSString *)logTail {
    NSMutableArray *parts = [NSMutableArray array];
    NSString *app = [self tailOf:[self path:@"zk_log.txt"] lines:40];
    if (app.length) [parts addObject:app];
    if (![self isExtension]) {
        NSMutableArray *extLines = [NSMutableArray array];
        for (NSString *d in [self extDirs]) {
            NSString *t = [self tailOf:[d stringByAppendingPathComponent:@"zk_ext_log.txt"] lines:25];
            if (t.length) [extLines addObject:t];
        }
        if (extLines.count) [parts addObject:[extLines componentsJoinedByString:@"\n"]];
    }
    return [parts componentsJoinedByString:@"\n"];
}

#pragma mark - 心跳

+ (void)beat:(NSDictionary *)d {
    NSMutableDictionary *m = [d mutableCopy] ?: [NSMutableDictionary dictionary];
    m[@"t"] = @([[NSDate date] timeIntervalSince1970]);
    [self write:m to:@"zk_beat.json"];
}

+ (NSDictionary *)beat { return [self read:@"zk_beat.json"]; }

#pragma mark - PCM

+ (NSString *)pcmPath { return [self path:@"zk_pcm.f32"]; }

+ (void)resetPCM {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [self dirs]) {
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"zk_pcm.f32"] error:nil];
    }
}

+ (void)appendPCM:(const void *)bytes length:(NSUInteger)n {
    if (!bytes || n == 0) return;
    NSData *d = [NSData dataWithBytes:bytes length:n];
    NSString *p = [self pcmPath];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [d writeToFile:p atomically:NO];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

+ (NSString *)pcmFileForRead {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSString *p in [self readPathsFor:@"zk_pcm.f32"]) {
        @try {
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            if (!at) continue;
            unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
            if (sz > bestSize) { bestSize = sz; best = p; }
        } @catch (__unused NSException *e) {}
    }
    return best;
}

+ (NSString *)diagLine {
    NSDictionary *b = [self beat];
    NSString *dir = [self dir];
    NSString *shortDir = dir.length > 46 ? [@"…" stringByAppendingString:[dir substringFromIndex:dir.length - 46]] : dir;
    if (!b.count) return [NSString stringWithFormat:@"存储：%@\n扩展：未上报", shortDir];
    NSTimeInterval t = [b[@"t"] doubleValue];
    double ago = [[NSDate date] timeIntervalSince1970] - t;
    return [NSString stringWithFormat:@"存储：%@\n扩展：%.0f秒前上报 · 音频 %@ 帧 · 连接 %@",
            shortDir, ago, b[@"bufs"] ?: @"0", b[@"conn"] ?: @"?"];
}

@end

#pragma mark - 崩溃断点（信号安全，可写在崩溃现场）

static int gCrumbFd = -1;

static void zkCrumbOpen(void) {
    if (gCrumbFd >= 0) return;
    @try {
        NSString *p = [[ZKStore dir] stringByAppendingPathComponent:@"zk_crumb.txt"];
        gCrumbFd = open([p fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
    } @catch (__unused NSException *e) {}
}

void ZKCrumb(const char *tag) {
    if (!tag) return;
    if (gCrumbFd < 0) zkCrumbOpen();
    if (gCrumbFd < 0) return;
    char buf[192];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    int n = snprintf(buf, sizeof(buf), "%02d:%02d:%02d %s\n",
                     tmv.tm_hour, tmv.tm_min, tmv.tm_sec, tag);
    if (n > 0) {
        ssize_t w = write(gCrumbFd, buf, (size_t)n);
        (void)w;
    }
}

static void zkSignalTrap(int sig) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "SIGNAL %d\n", sig);
    if (gCrumbFd >= 0 && n > 0) {
        ssize_t w = write(gCrumbFd, buf, (size_t)n);
        (void)w;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void zkExceptionTrap(NSException *e) {
    @try {
        NSString *s = [NSString stringWithFormat:@"EXCEPTION %@: %@\n",
                       e.name ?: @"?", e.reason ?: @""];
        if (gCrumbFd >= 0) {
            ssize_t w = write(gCrumbFd, [s UTF8String], strlen([s UTF8String]));
            (void)w;
        }
    } @catch (__unused NSException *x) {}
}

void ZKInstallCrashHandlers(void) {
    zkCrumbOpen();
    NSSetUncaughtExceptionHandler(&zkExceptionTrap);
    int sigs[] = {SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE, SIGTRAP};
    for (int i = 0; i < 6; i++) signal(sigs[i], zkSignalTrap);
}

NSString *ZKCrashTail(void) {
    @try {
        NSString *p = [[ZKStore dir] stringByAppendingPathComponent:@"zk_crumb.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!s.length) return nil;
        NSArray *lines = [s componentsSeparatedByString:@"\n"];
        NSInteger hit = -1;
        for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
            NSString *l = lines[i];
            if ([l containsString:@"SIGNAL"] || [l containsString:@"EXCEPTION"]) hit = i;
        }
        if (hit <= 0) return nil;
        NSString *step = lines[hit - 1];
        NSRange sp = [step rangeOfString:@" "];
        if (sp.location != NSNotFound && step.length > sp.location + 1) {
            step = [step substringFromIndex:sp.location + 1];
        }
        NSString *how = [lines[hit] containsString:@"SIGNAL"] ? @"闪退" : @"异常";
        return [NSString stringWithFormat:@"上次中断：%@（%@）", step, how];
    } @catch (__unused NSException *e) { return nil; }
}

void ZKCrumbsReset(void) {
    if (gCrumbFd < 0) zkCrumbOpen();
    if (gCrumbFd >= 0) {
        if (ftruncate(gCrumbFd, 0) == 0) lseek(gCrumbFd, 0, SEEK_END);
    }
}
