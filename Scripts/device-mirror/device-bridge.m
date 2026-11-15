// An iPhone plugged into the Mac (#527): its screen as H.264 on stdout, the gestures of stdin
// replayed by WebDriverAgent. It leaves when stdin closes.
//
//   device-bridge --list    the iPhones plugged in by USB, a line "UDID<tab>name" each
//   device-bridge <UDID>
//   stdout: big-endian u32 length, then u8 isKey; if key: u16 + SPS, u16 + PPS; then AVCC NAL units.
//   stdin:  lines "d x y", "m x y", "u x y", coordinates from 0 to 1, top left origin; "k" asks
//           for a key frame.
//
// The screen comes from AVFoundation, as in QuickTime: once CoreMediaIO allows screen capture
// devices, the iPhone is a muxed AVCaptureDevice, which the camera permission covers. Nothing
// public injects a touch into an iPhone: WebDriverAgent, an XCTest runner signed with the user's
// team, does, behind HTTP on port 8100 of the device, reached through usbmuxd. A touch cannot be
// followed as it moves: the gesture is sent once the finger is up, a tap or a drag replayed with
// its timing.
#import <AVFoundation/AVFoundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <mach/mach_time.h>
#import <sys/socket.h>
#import <sys/un.h>

static void writeAll(const void *bytes, size_t count) {
  const char *cursor = bytes;
  while (count > 0) {
    ssize_t written = write(STDOUT_FILENO, cursor, count);
    if (written <= 0) exit(0);
    cursor += written;
    count -= (size_t)written;
  }
}

static double nowMs(void) {
  static mach_timebase_info_data_t base;
  if (!base.denom) mach_timebase_info(&base);
  return (double)mach_absolute_time() * base.numer / base.denom / 1e6;
}

// MARK: - usbmuxd

static bool readAll(int fd, void *bytes, size_t count) {
  char *cursor = bytes;
  while (count > 0) {
    ssize_t got = read(fd, cursor, count);
    if (got <= 0) return false;
    cursor += got;
    count -= (size_t)got;
  }
  return true;
}

static bool sendAll(int fd, const void *bytes, size_t count) {
  const char *cursor = bytes;
  while (count > 0) {
    ssize_t sent = write(fd, cursor, count);
    if (sent <= 0) return false;
    cursor += sent;
    count -= (size_t)sent;
  }
  return true;
}

static int usbmuxOpen(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  strlcpy(address.sun_path, "/var/run/usbmuxd", sizeof address.sun_path);
  if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) {
    close(fd);
    return -1;
  }
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
  return fd;
}

// A plist message: u32 little-endian length (header included), version 1, type 8, tag.
static NSDictionary *usbmuxExchange(int fd, NSDictionary *message) {
  NSMutableDictionary *full = [message mutableCopy];
  full[@"ClientVersionString"] = @"vibe-device-bridge";
  full[@"ProgName"] = @"device-bridge";
  NSData *body = [NSPropertyListSerialization dataWithPropertyList:full
                                                            format:NSPropertyListXMLFormat_v1_0
                                                           options:0
                                                             error:nil];
  uint32_t header[4] = {(uint32_t)(16 + body.length), 1, 8, 1};
  if (!sendAll(fd, header, 16) || !sendAll(fd, body.bytes, body.length)) return nil;
  if (!readAll(fd, header, 16) || header[0] < 16) return nil;
  NSMutableData *reply = [NSMutableData dataWithLength:header[0] - 16];
  if (!readAll(fd, reply.mutableBytes, reply.length)) return nil;
  return [NSPropertyListSerialization propertyListWithData:reply options:0 format:NULL error:nil];
}

// A raw TCP stream to a port of the device, or -1.
static int usbmuxConnect(NSNumber *deviceID, uint16_t port) {
  int fd = usbmuxOpen();
  if (fd < 0) return -1;
  NSDictionary *reply = usbmuxExchange(fd, @{
    @"MessageType" : @"Connect",
    @"DeviceID" : deviceID,
    @"PortNumber" : @(CFSwapInt16HostToBig(port))
  });
  if ([reply[@"Number"] intValue] != 0 || !reply) {
    close(fd);
    return -1;
  }
  return fd;
}

static NSString *bare(NSString *udid) {
  return [[udid stringByReplacingOccurrencesOfString:@"-" withString:@""] uppercaseString];
}

// The USB devices usbmuxd knows: their serial number, the UDID, to their DeviceID.
static NSDictionary<NSString *, NSNumber *> *usbDevices(void) {
  int fd = usbmuxOpen();
  if (fd < 0) return @{};
  NSDictionary *reply = usbmuxExchange(fd, @{@"MessageType" : @"ListDevices"});
  close(fd);
  NSMutableDictionary *devices = [NSMutableDictionary dictionary];
  for (NSDictionary *entry in reply[@"DeviceList"]) {
    NSDictionary *properties = entry[@"Properties"];
    if (![properties[@"ConnectionType"] isEqual:@"USB"]) continue;
    NSString *serial = properties[@"SerialNumber"];
    if (serial) devices[serial] = properties[@"DeviceID"];
  }
  return devices;
}

// What lockdownd tells anyone without a session: the name the user gave the device.
static NSString *deviceName(NSNumber *deviceID) {
  int fd = usbmuxConnect(deviceID, 62078);
  if (fd < 0) return nil;
  NSData *body = [NSPropertyListSerialization
      dataWithPropertyList:@{@"Label" : @"device-bridge", @"Request" : @"GetValue", @"Key" : @"DeviceName"}
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:nil];
  uint32_t length = CFSwapInt32HostToBig((uint32_t)body.length);
  NSString *name = nil;
  if (sendAll(fd, &length, 4) && sendAll(fd, body.bytes, body.length) && readAll(fd, &length, 4)) {
    NSMutableData *reply = [NSMutableData dataWithLength:CFSwapInt32BigToHost(length)];
    if (readAll(fd, reply.mutableBytes, reply.length)) {
      NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:reply
                                                                      options:0
                                                                       format:NULL
                                                                        error:nil];
      name = plist[@"Value"];
    }
  }
  close(fd);
  return name;
}

// MARK: - WebDriverAgent

static NSNumber *usbDeviceID;
static NSString *session;
static CGSize screenPoints;

// One HTTP request to WebDriverAgent, a connection each; its JSON "value", or nil.
static id wda(NSString *method, NSString *path, id json) {
  int fd = usbmuxConnect(usbDeviceID, 8100);
  if (fd < 0) return nil;
  struct timeval timeout = {.tv_sec = 30};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
  NSData *body = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:nil] : [NSData data];
  NSString *head = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: localhost\r\nContent-Type: "
                                              @"application/json\r\nContent-Length: %lu\r\n"
                                              @"Connection: close\r\n\r\n",
                                              method, path, (unsigned long)body.length];
  NSMutableData *request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [request appendData:body];
  NSMutableData *reply = [NSMutableData data];
  if (sendAll(fd, request.bytes, request.length)) {
    char buffer[16384];
    ssize_t got;
    while ((got = read(fd, buffer, sizeof buffer)) > 0) [reply appendBytes:buffer length:(size_t)got];
  }
  close(fd);
  NSRange split = [reply rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                             options:0
                               range:NSMakeRange(0, reply.length)];
  if (split.location == NSNotFound) return nil;
  NSData *content = [reply subdataWithRange:NSMakeRange(NSMaxRange(split), reply.length - NSMaxRange(split))];
  NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:content options:0 error:nil];
  return [parsed isKindOfClass:NSDictionary.class] ? parsed[@"value"] : nil;
}

// A session on whatever is in front, which waits for nothing: no quiescence, no idling.
static bool ensureSession(void) {
  if (session) return true;
  NSDictionary *created = wda(@"POST", @"/session", @{
    @"capabilities" : @{
      @"alwaysMatch" : @{
        @"shouldWaitForQuiescence" : @NO,
        @"waitForIdleTimeout" : @0,
        @"eventloopIdleDelaySec" : @0,
        @"disableAutomaticScreenshots" : @YES
      }
    }
  });
  NSString *identifier = [created isKindOfClass:NSDictionary.class] ? created[@"sessionId"] : nil;
  if (!identifier) {
    fprintf(stderr, "device-bridge: WebDriverAgent does not answer on port 8100\n");
    return false;
  }
  wda(@"POST", [NSString stringWithFormat:@"/session/%@/appium/settings", identifier],
      @{@"settings" : @{@"waitForIdleTimeout" : @0, @"animationCoolOffTimeout" : @0, @"snapshotMaxDepth" : @1}});
  NSDictionary *size = wda(@"GET", [NSString stringWithFormat:@"/session/%@/window/size", identifier], nil);
  screenPoints = CGSizeMake([size[@"width"] doubleValue], [size[@"height"] doubleValue]);
  session = identifier;
  fprintf(stderr, "device-bridge: WebDriverAgent session, screen %.0f×%.0f points\n",
          screenPoints.width, screenPoints.height);
  return true;
}

typedef struct {
  double x, y, at;
} Sample;

static double measuredGesture = 0;

// A gesture, once the finger is up: a tap, or every move replayed with its timing.
static void replay(NSArray<NSValue *> *samples) {
  if (!ensureSession()) return;
  Sample first, last;
  [samples.firstObject getValue:&first];
  [samples.lastObject getValue:&last];
  double w = screenPoints.width, h = screenPoints.height;
  double distance = hypot((last.x - first.x) * w, (last.y - first.y) * h);
  double held = last.at - first.at;
  double start = nowMs();
  NSString *kind;
  if (distance < 8 && held < 400) {
    kind = @"tap";
  } else {
    kind = distance < 8 ? @"press" : @"drag";
  }
  // W3C actions even for a tap: /wda/tap takes twice as long (1.4 s against 0.75 s, #527).
  NSMutableArray *actions = [NSMutableArray array];
  [actions addObject:@{@"type" : @"pointerMove", @"duration" : @0, @"x" : @(round(first.x * w)), @"y" : @(round(first.y * h))}];
  [actions addObject:@{@"type" : @"pointerDown", @"button" : @0}];
  if (![kind isEqual:@"tap"]) {
    // At most a move every 50 ms: XCTest synthesizes the path between them.
    Sample previous = first;
    for (NSValue *value in samples) {
      Sample sample;
      [value getValue:&sample];
      bool isLast = value == samples.lastObject;
      if (sample.at - previous.at < 50 && !isLast) continue;
      [actions addObject:@{
        @"type" : @"pointerMove",
        @"duration" : @(MAX(1, (long)round(sample.at - previous.at))),
        @"x" : @(round(sample.x * w)),
        @"y" : @(round(sample.y * h))
      }];
      previous = sample;
    }
  }
  [actions addObject:@{@"type" : @"pointerUp", @"button" : @0}];
  wda(@"POST", [NSString stringWithFormat:@"/session/%@/actions", session], @{
    @"actions" : @[ @{
      @"type" : @"pointer",
      @"id" : @"finger",
      @"parameters" : @{@"pointerType" : @"touch"},
      @"actions" : actions
    } ]
  });
  double done = nowMs();
  measuredGesture = done;
  fprintf(stderr, "device-bridge: %s of %.0f ms, %.0f points, sent %.0f ms after the finger left, "
                  "WebDriverAgent took %.0f ms\n",
          kind.UTF8String, held, distance, start - last.at, done - start);
}

static volatile bool keyRequested = false;
static double lastGestureEnd = 0;

static dispatch_queue_t gestures;

static void readTouches(void) {
  NSMutableArray<NSValue *> *samples = nil;
  char line[64];
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'k') {
      keyRequested = true;
      continue;
    }
    char phase;
    double x, y;
    if (sscanf(line, "%c %lf %lf", &phase, &x, &y) != 3) continue;
    Sample sample = {x, y, nowMs()};
    if (phase == 'd') samples = [NSMutableArray array];
    if (!samples) continue;
    [samples addObject:[NSValue valueWithBytes:&sample objCType:@encode(Sample)]];
    if (phase == 'u') {
      NSArray *gesture = samples;
      samples = nil;
      lastGestureEnd = sample.at;
      dispatch_async(gestures, ^{
        replay(gesture);
      });
    }
  }
  exit(0);
}

// MARK: - Screen

@interface Encoder : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

static void encoded(void *unused, void *frame, OSStatus status, VTEncodeInfoFlags flags,
                    CMSampleBufferRef sample) {
  if (status != noErr || !sample) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  bool isKey = true;
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef first = CFArrayGetValueAtIndex(attachments, 0);
    isKey = !CFDictionaryContainsKey(first, kCMSampleAttachmentKey_NotSync);
  }
  NSMutableData *payload = [NSMutableData data];
  uint8_t key = isKey;
  [payload appendBytes:&key length:1];
  if (isKey) {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    for (size_t index = 0; index < 2; index++) {
      const uint8_t *set = NULL;
      size_t size = 0;
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &set, &size, NULL, NULL);
      uint16_t length = CFSwapInt16HostToBig((uint16_t)size);
      [payload appendBytes:&length length:2];
      [payload appendBytes:set length:size];
    }
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  size_t total = 0;
  char *bytes = NULL;
  CMBlockBufferGetDataPointer(block, 0, NULL, &total, &bytes);
  [payload appendBytes:bytes length:total];
  uint32_t length = CFSwapInt32HostToBig((uint32_t)payload.length);
  writeAll(&length, 4);
  writeAll(payload.bytes, payload.length);
}

@implementation Encoder {
  VTCompressionSessionRef session;
  size_t width, height;
  int64_t index;
  CVPixelBufferRef last;
  // What the measures of #527 report every five seconds.
  int frames;
  double captureDelay, encodeStart, windowStart, awaitedGesture;
}

- (void)encode:(CVPixelBufferRef)buffer forceKey:(bool)forceKey {
  size_t w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
  if (w != width || h != height || !session) {
    width = w;
    height = h;
    if (session) {
      VTCompressionSessionInvalidate(session);
      CFRelease(session);
    }
    VTCompressionSessionCreate(
        NULL, (int32_t)w, (int32_t)h, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)@{(id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES},
        NULL, NULL, encoded, NULL, &session);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @6000000);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef) @240);
    forceKey = true;
    fprintf(stderr, "device-bridge: screen of %zu×%zu pixels\n", w, h);
  }
  NSDictionary *properties = forceKey ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
  VTCompressionSessionEncodeFrame(session, buffer, CMTimeMake(index++, 60), kCMTimeInvalid,
                                  (__bridge CFDictionaryRef)properties, NULL, NULL);
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sample
           fromConnection:(AVCaptureConnection *)connection {
  CVPixelBufferRef buffer = CMSampleBufferGetImageBuffer(sample);
  if (!buffer) return;
  double now = nowMs();
  // The time the device stamped, on the host clock, against now: what USB and CoreMedia add.
  CMTime stamped = CMSampleBufferGetPresentationTimeStamp(sample);
  double stampedMs = CMTimeGetSeconds(CMSyncConvertTime(stamped, connection.inputPorts.firstObject.clock ?: CMClockGetHostTimeClock(), CMClockGetHostTimeClock())) * 1000;
  double hostMs = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1000;
  captureDelay += hostMs - stampedMs;
  frames++;
  if (lastGestureEnd > awaitedGesture) {
    awaitedGesture = lastGestureEnd;
    fprintf(stderr, "device-bridge: first frame %.0f ms after the finger left (WebDriverAgent %s)\n",
            now - lastGestureEnd, measuredGesture > lastGestureEnd ? "answered" : "still busy");
  }
  if (!windowStart) windowStart = now;
  if (now - windowStart > 5000) {
    fprintf(stderr, "device-bridge: %.1f frames/s, %.1f ms from the device's stamp to the bridge\n",
            frames * 1000 / (now - windowStart), captureDelay / frames);
    frames = 0;
    captureDelay = 0;
    windowStart = now;
  }
  if (last) CVPixelBufferRelease(last);
  last = CVPixelBufferRetain(buffer);
  bool key = keyRequested;
  keyRequested = false;
  [self encode:buffer forceKey:key];
}

// The screen sends nothing while it does not change, and a decoder that dropped frames needs a
// key frame: the last picture again.
- (void)repeatIfAsked {
  if (!keyRequested || !last) return;
  keyRequested = false;
  [self encode:last forceKey:true];
}
@end

static AVCaptureDevice *screen(NSString *name) {
  CMIOObjectPropertyAddress allow = {kCMIOHardwarePropertyAllowScreenCaptureDevices,
                                     kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
  UInt32 yes = 1;
  CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &allow, 0, NULL, sizeof yes, &yes);
  // The devices come a moment after the property is set.
  for (int attempt = 0; attempt < 50; attempt++) {
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeExternal ]
                              mediaType:AVMediaTypeMuxed
                               position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *device in discovery.devices)
      if (!name || [device.localizedName isEqual:name]) return device;
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  return nil;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    signal(SIGPIPE, SIG_DFL);
    NSDictionary<NSString *, NSNumber *> *devices = usbDevices();
    if (!strcmp(argv[1], "--list")) {
      for (NSString *serial in devices) {
        NSString *name = deviceName(devices[serial]) ?: @"iPhone";
        printf("%s\t%s\n", serial.UTF8String, name.UTF8String);
      }
      return 0;
    }
    NSString *udid = @(argv[1]);
    for (NSString *serial in devices)
      if ([bare(serial) isEqual:bare(udid)]) usbDeviceID = devices[serial];
    if (!usbDeviceID) {
      fprintf(stderr, "device-bridge: %s is not plugged in by USB\n", argv[1]);
      return 4;
    }
    NSString *name = deviceName(usbDeviceID);
    AVCaptureDevice *device = screen(name);
    if (!device) {
      fprintf(stderr, "device-bridge: no screen for %s; is the iPhone unlocked and trusting this Mac?\n",
              name.UTF8String);
      return 5;
    }
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL allowed) {
                               granted = allowed;
                               dispatch_semaphore_signal(answered);
                             }];
    dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
    if (!granted) {
      fprintf(stderr, "device-bridge: the camera permission was refused\n");
      return 6;
    }
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
      fprintf(stderr, "device-bridge: %s\n", error.description.UTF8String);
      return 7;
    }
    AVCaptureSession *capture = [AVCaptureSession new];
    [capture addInput:input];
    AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    Encoder *encoder = [Encoder new];
    dispatch_queue_t frames = dispatch_queue_create("frames", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:encoder queue:frames];
    [capture addOutput:output];
    [capture startRunning];
    fprintf(stderr, "device-bridge: capturing %s\n", device.localizedName.UTF8String);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, frames);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      [encoder repeatIfAsked];
    });
    dispatch_resume(timer);
    // WebDriverAgent's session while the screen comes, rather than on the first touch.
    gestures = dispatch_queue_create("gestures", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gestures, ^{
      ensureSession();
    });
    dispatch_async(dispatch_queue_create("touches", DISPATCH_QUEUE_SERIAL), ^{
      readTouches();
    });
    [NSRunLoop.currentRunLoop run];
  }
}
