import AVFoundation
import AppKit
import CompanionCore
import SwiftUI
import VibeConversationUI
import VibeDevices

/// A simulator in a tab of the web view. `sim-bridge`, a process of its own, holds the
/// private frameworks; this view shows its H.264 and sends it the mouse as touches.
struct DeviceMirrorView: NSViewRepresentable {
  let udid: String

  func makeNSView(context: Context) -> DeviceMirrorNSView {
    let view = DeviceMirrorNSView()
    view.start(udid: udid)
    return view
  }

  func updateNSView(_ view: DeviceMirrorNSView, context: Context) {
    view.start(udid: udid)
  }

  static func dismantleNSView(_ view: DeviceMirrorNSView, coordinator: ()) {
    view.stop()
  }
}

final class DeviceMirrorNSView: NSView {
  private let video = AVSampleBufferDisplayLayer()
  private var session: DeviceMirrorSession?
  private var udid: String?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    video.videoGravity = .resizeAspect
    layer?.addSublayer(video)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    video.frame = bounds
    CATransaction.commit()
  }

  func start(udid: String) {
    guard self.udid != udid else { return }
    stop()
    self.udid = udid
    session = DeviceMirrorSession(udid: udid, video: video)
  }

  func stop() {
    session?.stop()
    session = nil
    udid = nil
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) { send("d", event) }
  override func mouseDragged(with event: NSEvent) { send("m", event) }
  override func mouseUp(with event: NSEvent) { send("u", event) }

  private func send(_ phase: String, _ event: NSEvent) {
    guard let session, let size = session.videoSize, size.width > 0 else { return }
    let shown = AVMakeRect(aspectRatio: size, insideRect: bounds)
    let point = convert(event.locationInWindow, from: nil)
    let x = min(max((point.x - shown.minX) / shown.width, 0), 1)
    let y = min(max((point.y - shown.minY) / shown.height, 0), 1)
    session.send("\(phase) \(x) \(y)\n")
  }
}

/// The bridge and the thread that reads it.
private final class DeviceMirrorSession: @unchecked Sendable {
  private let video: AVSampleBufferDisplayLayer
  private let lock = NSLock()
  private var size: CGSize?
  private var bridge: DeviceBridge?
  private var isStopped = false

  var videoSize: CGSize? {
    lock.withLock { size }
  }

  init(udid: String, video: AVSampleBufferDisplayLayer) {
    self.video = video
    video.sampleBufferRenderer.flush()
    guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
    // Opened once the Xcode a simulator's bridge loads is known, off the main thread.
    Task.detached { [self] in
      guard let opened = try? await DeviceBridge.opening(device: udid, bridgesIn: folder) else {
        return
      }
      let kept = lock.withLock {
        guard !isStopped else { return false }
        bridge = opened
        return true
      }
      guard kept else { return opened.stop() }
      Thread.detachNewThread { [self] in read(opened) }
    }
  }

  func stop() {
    lock.withLock {
      isStopped = true
      return bridge
    }?.stop()
  }

  func send(_ line: String) {
    lock.withLock { bridge }?.send(line)
  }

  private func read(_ bridge: DeviceBridge) {
    var decoder = CompanionMirror.FrameDecoder()
    while let frame = bridge.nextFrame() {
      guard let sample = decoder.sample(from: frame) else { continue }
      let shown = decoder.size
      lock.withLock { size = shown }
      video.sampleBufferRenderer.enqueue(sample)
    }
  }
}

/// Beside the web view's button, what opens a simulator in one of its tabs.
/// Its list opens in the same kind of popover as the session's notes, beside it.
struct DeviceMirrorToolbarButton: View {
  let model: AppModel
  @State private var popover = ToolbarPopover()

  var body: some View {
    Button {
      toggle()
    } label: {
      Label {
        Text("Simulators", bundle: .module)
      } icon: {
        Image(systemName: "iphone")
      }
    }
    .disabled(!model.isWebViewAvailable)
    .instantTooltip(Text("Simulators", bundle: .module))
    .background(
      // Out of the toolbar, the button takes its list with it: no list left open without a button.
      ToolbarPopoverAnchor(
        entered: { [popover] in popover.anchor = $0 },
        left: { [popover] in popover.close(animated: false) }
      )
      .allowsHitTesting(false))
  }

  private func toggle() {
    if popover.isShown {
      popover.close()
      return
    }
    // The click that closed the list, now acting on the button: the list stays away.
    guard !popover.pressEndsClosingClick() else { return }
    popover.show(
      DeviceMirrorPicker { [weak popover, model] udid, name in
        popover?.close()
        guard let url = URL(string: "vibe-device://\(udid)") else { return }
        model.openDeviceTab(url, title: name)
      })
  }
}

struct DeviceMirrorPicker: View {
  let open: (_ udid: String, _ name: String) -> Void
  @State private var listing: DeviceCatalog.Listing?
  @State private var simulators: [DeviceCatalog.Device] = []

  private var devices: [DeviceCatalog.Device] { simulators + (listing?.devices ?? []) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if listing != nil || !simulators.isEmpty {
        if devices.isEmpty && (listing?.unavailablePhones.isEmpty ?? true) {
          Text("No simulator or emulator running", bundle: .module).padding(8)
        }
        ForEach(devices, id: \.id) { device in
          Button(device.name) { open(device.id, device.name) }
            .buttonStyle(.borderless)
            .padding(6)
        }
        ForEach(listing?.unavailablePhones ?? [], id: \.serial) { phone in
          unavailable(phone).foregroundStyle(.secondary).padding(6)
        }
        if let listing, let help = androidHelp(listing) {
          help.font(.caption).foregroundStyle(.secondary).padding(6)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        ProgressView().padding(8)
      }
    }
    .padding(6)
    .frame(minWidth: 200, maxWidth: 320, alignment: .leading)
    .task {
      // Again each second while open: a phone shows up, or is authorized, as the user watches.
      while !Task.isCancelled {
        listing = await DeviceCatalog.listing(includeSimulators: false)
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .task {
      // simctl can take tens of seconds; it must not delay adb or its next refresh.
      while !Task.isCancelled {
        simulators = await DeviceCatalog.simulators()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func unavailable(_ phone: DeviceCatalog.UnavailablePhone) -> Text {
    switch phone.problem {
    case .unauthorized:
      Text("\(phone.serial) — accept USB debugging on the phone", bundle: .module)
    case .offline:
      Text("\(phone.serial) — offline, plug the cable in again", bundle: .module)
    }
  }

  /// What a user with an Android phone needs to see it here, while none is listed.
  private func androidHelp(_ listing: DeviceCatalog.Listing) -> Text? {
    if !listing.hasADB {
      return Text(
        "Android phone: install adb (Android Studio, or brew install --cask android-platform-tools).",
        bundle: .module)
    }
    let hasPhone =
      !listing.unavailablePhones.isEmpty
      || listing.devices.contains { DeviceCatalog.isPhone($0.id) }
    return hasPhone
      ? nil : Text("Android phone: turn on USB debugging in Developer options.", bundle: .module)
  }
}
