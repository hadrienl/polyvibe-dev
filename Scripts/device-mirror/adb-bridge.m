// One Android phone's screen as H.264 on stdout, its touches from stdin (#526): the same protocol
// as sim-bridge and emu-bridge, through scrcpy's server (Apache 2.0, the version below exactly) run
// on the phone. Nothing is spawned: the user's adb server is spoken to on 127.0.0.1, which pushes
// the server, starts it and carries its sockets.
//
//   adb-bridge <serial> <scrcpy-server>     the adb server's port, if not 5037, in ANDROID_ADB_SERVER_PORT
//   stdout: big-endian u32 length, then u8 isKey; if key: u16 + SPS, u16 + PPS; then AVCC NAL units.
//   stdin:  lines "d x y", "m x y", "u x y" from 0 to 1, top left origin; "k" asks a key frame.
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <libkern/OSByteOrder.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <sys/socket.h>
#import <unistd.h>

static const char *scrcpyVersion = "5.0.1";
static const char *devicePath = "/data/local/tmp/vibe-scrcpy-server.jar";
static const char *serial;
static int video = -1, control = -1;
static pthread_mutex_t controlling = PTHREAD_MUTEX_INITIALIZER;
// The size of the picture now, which the server counts touches in.
static volatile int width = 0, height = 0;

static void writeAll(int fd, const void *bytes, size_t count) {
  const uint8_t *cursor = bytes;
  while (count > 0) {
    ssize_t written = write(fd, cursor, count);
    if (written <= 0) exit(0);
    cursor += written;
    count -= (size_t)written;
  }
}

static bool readAll(int fd, void *bytes, size_t count) {
  uint8_t *cursor = bytes;
  while (count > 0) {
    ssize_t got = read(fd, cursor, count);
    if (got <= 0) return false;
    cursor += got;
    count -= (size_t)got;
  }
  return true;
}

static void fail(const char *message) {
  fprintf(stderr, "adb-bridge: %s\n", message);
  exit(1);
}

// MARK: - adb

/// Sends a request to the adb server and reads its answer: whether it said OKAY.
static bool request(int fd, const char *service) {
  char header[5];
  snprintf(header, sizeof header, "%04x", (unsigned)strlen(service));
  writeAll(fd, header, 4);
  writeAll(fd, service, strlen(service));
  char status[4];
  if (!readAll(fd, status, 4)) return false;
  if (memcmp(status, "OKAY", 4) == 0) return true;
  char length[5] = {0};
  if (readAll(fd, length, 4)) {
    size_t size = strtoul(length, NULL, 16);
    char *text = calloc(size + 1, 1);
    if (readAll(fd, text, size)) fprintf(stderr, "adb-bridge: %s: %s\n", service, text);
    free(text);
  }
  return false;
}

/// A connection to `service` on the phone, through the adb server, or -1.
static int connectTo(const char *service) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  const char *port = getenv("ANDROID_ADB_SERVER_PORT");
  struct sockaddr_in address = {.sin_family = AF_INET,
                                .sin_port = htons((uint16_t)(port ? atoi(port) : 5037))};
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  // The server may still be starting: the application starts it as it starts this bridge.
  for (int attempt = 0; connect(fd, (struct sockaddr *)&address, sizeof address) != 0; attempt++) {
    if (attempt == 50) fail("no adb server on 127.0.0.1");
    usleep(200000);
    close(fd);
    fd = socket(AF_INET, SOCK_STREAM, 0);
  }
  int yes = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
  char transport[512];
  snprintf(transport, sizeof transport, "host:transport:%s", serial);
  if (!request(fd, transport) || !request(fd, service)) {
    close(fd);
    return -1;
  }
  return fd;
}

static void syncPacket(int fd, const char *identifier, uint32_t value, const void *body) {
  uint32_t little = CFSwapInt32HostToLittle(value);
  writeAll(fd, identifier, 4);
  writeAll(fd, &little, 4);
  if (body) writeAll(fd, body, value);
}

/// `adb push` of the server, by the sync protocol.
static void push(const char *path) {
  NSData *server = [NSData dataWithContentsOfFile:@(path)];
  if (!server) fail("the scrcpy server is missing");
  int fd = connectTo("sync:");
  if (fd < 0) fail("the phone cannot be reached: is it authorized?");
  char target[256];
  snprintf(target, sizeof target, "%s,%d", devicePath, 0100644);
  syncPacket(fd, "SEND", (uint32_t)strlen(target), target);
  for (NSUInteger offset = 0; offset < server.length; offset += 65536) {
    uint32_t size = (uint32_t)MIN((NSUInteger)65536, server.length - offset);
    syncPacket(fd, "DATA", size, (const uint8_t *)server.bytes + offset);
  }
  syncPacket(fd, "DONE", (uint32_t)time(NULL), NULL);
  uint8_t answer[8];
  if (!readAll(fd, answer, 8) || memcmp(answer, "OKAY", 4) != 0) fail("the server was not pushed");
  syncPacket(fd, "QUIT", 0, NULL);
  close(fd);
}

/// Reads what `fd` sends until it ends, then leaves: the server or one of its sockets has gone.
static void *drain(void *argument) {
  int fd = (int)(intptr_t)argument;
  uint8_t ignored[4096];
  while (read(fd, ignored, sizeof ignored) > 0) {
  }
  exit(0);
}

static void drainInBackground(int fd) {
  pthread_t thread;
  pthread_create(&thread, NULL, drain, (void *)(intptr_t)fd);
}

/// A socket of the server, which listens once it has started: retried until it answers, for up to
/// 30 s, the time a slow emulator takes.
static int serverSocket(const char *name, bool hasDummyByte) {
  for (int attempt = 0; attempt < 300; attempt++) {
    int fd = connectTo(name);
    if (fd >= 0) {
      uint8_t dummy;
      // adb accepts even when nothing listens on the phone: the first byte tells.
      if (!hasDummyByte || readAll(fd, &dummy, 1)) return fd;
      close(fd);
    }
    usleep(100000);
  }
  fail("the scrcpy server did not start");
  return -1;
}

// MARK: - Video

static NSData *sps, *pps;

static void emit(bool isKey, NSData *pictures) {
  if (pictures.length == 0 || (isKey && (!sps || !pps))) return;
  NSMutableData *payload = [NSMutableData data];
  uint8_t key = isKey;
  [payload appendBytes:&key length:1];
  if (isKey) {
    for (NSData *set in @[ sps, pps ]) {
      uint16_t length = CFSwapInt16HostToBig((uint16_t)set.length);
      [payload appendBytes:&length length:2];
      [payload appendData:set];
    }
  }
  [payload appendData:pictures];
  uint32_t length = CFSwapInt32HostToBig((uint32_t)payload.length);
  writeAll(1, &length, 4);
  writeAll(1, payload.bytes, payload.length);
}

/// MediaCodec's Annex B as AVCC: each NAL unit after its length instead of a start code. Its
/// parameter sets are kept, for the key frames.
static void unit(NSMutableData *pictures, const uint8_t *bytes, size_t start, size_t end) {
  // A unit never ends with a zero: those are the next start code's, or padding.
  while (end > start && bytes[end - 1] == 0) end--;
  if (end <= start) return;
  const uint8_t *unit = bytes + start;
  size_t length = end - start;
  int type = unit[0] & 0x1f;
  if (type == 7) {
    sps = [NSData dataWithBytes:unit length:length];
  } else if (type == 8) {
    pps = [NSData dataWithBytes:unit length:length];
  } else {
    uint32_t big = CFSwapInt32HostToBig((uint32_t)length);
    [pictures appendBytes:&big length:4];
    [pictures appendBytes:unit length:length];
  }
}

static NSData *avcc(const uint8_t *bytes, size_t size) {
  NSMutableData *pictures = [NSMutableData data];
  size_t start = SIZE_MAX, index = 0;
  while (index + 3 <= size) {
    if (bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1) {
      if (start != SIZE_MAX) unit(pictures, bytes, start, index);
      index += 3;
      start = index;
    } else {
      index++;
    }
  }
  if (start != SIZE_MAX) unit(pictures, bytes, start, size);
  return pictures;
}

static void readVideo(void) {
  uint8_t codec[4];
  if (!readAll(video, codec, 4)) exit(0);
  if (memcmp(codec, "h264", 4) != 0) fail("the phone cannot encode H.264");
  size_t bufferSize = 1 << 20;
  uint8_t *buffer = malloc(bufferSize);
  for (;;) {
    uint8_t header[12];
    if (!readAll(video, header, 12)) exit(0);
    if (header[0] & 0x80) {
      // A session: the picture's size, again after each rotation.
      width = (int)OSReadBigInt32(header, 4);
      height = (int)OSReadBigInt32(header, 8);
      continue;
    }
    bool isConfig = header[0] & 0x40, isKey = header[0] & 0x20;
    size_t size = OSReadBigInt32(header, 8);
    if (size > bufferSize) {
      bufferSize = size;
      buffer = realloc(buffer, bufferSize);
    }
    if (!readAll(video, buffer, size)) exit(0);
    @autoreleasepool {
      NSData *pictures = avcc(buffer, size);
      if (!isConfig) emit(isKey, pictures);
    }
  }
}

// MARK: - Touches

static void sendControl(const uint8_t *message, size_t size) {
  pthread_mutex_lock(&controlling);
  writeAll(control, message, size);
  pthread_mutex_unlock(&controlling);
}

static void touch(char phase, double x, double y) {
  int shownWidth = width, shownHeight = height;
  if (!shownWidth) return;
  // INJECT_TOUCH_EVENT: action, pointer, position in the picture now, pressure, no buttons.
  uint8_t message[32] = {2, phase == 'd' ? 0 : phase == 'u' ? 1 : 2};
  OSWriteBigInt64(message, 2, (uint64_t)-2);  // A finger, not the mouse.
  OSWriteBigInt32(message, 10, (uint32_t)MIN((int)(x * shownWidth), shownWidth - 1));
  OSWriteBigInt32(message, 14, (uint32_t)MIN((int)(y * shownHeight), shownHeight - 1));
  OSWriteBigInt16(message, 18, (uint16_t)shownWidth);
  OSWriteBigInt16(message, 20, (uint16_t)shownHeight);
  OSWriteBigInt16(message, 22, phase == 'u' ? 0 : 0xffff);
  sendControl(message, sizeof message);
}

static void *readTouches(void *unused) {
  char line[64];
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'k') {
      // RESET_VIDEO, once the capture has begun: before, it ends the server (5.0.1). The first
      // frame is a key frame anyway.
      const uint8_t resetVideo = 17;
      if (width) sendControl(&resetVideo, 1);
      continue;
    }
    char phase;
    double x, y;
    if (sscanf(line, "%c %lf %lf", &phase, &x, &y) == 3) touch(phase, x, y);
  }
  // The tab or the phone's stream has ended: so does the server, its sockets closed.
  exit(0);
}

// MARK: - Main

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) return 2;
    serial = argv[1];
    push(argv[2]);
    uint32_t scid = arc4random() & 0x7fffffff;
    char command[1024];
    snprintf(command, sizeof command,
             "shell:CLASSPATH=%s app_process / com.genymobile.scrcpy.Server %s scid=%08x "
             "log_level=warn tunnel_forward=true audio=false video_codec=h264 max_size=1600 "
             "max_fps=60 send_device_meta=false clipboard_autosync=false cleanup=true",
             devicePath, scrcpyVersion, scid);
    int shell = connectTo(command);
    if (shell < 0) fail("the scrcpy server could not be started");
    drainInBackground(shell);
    char name[64];
    snprintf(name, sizeof name, "localabstract:scrcpy_%08x", scid);
    // In the order the server accepts them: video, which sends the dummy byte, then control.
    video = serverSocket(name, true);
    control = serverSocket(name, false);
    drainInBackground(control);
    pthread_t touches;
    pthread_create(&touches, NULL, readTouches, NULL);
    readVideo();
  }
}
