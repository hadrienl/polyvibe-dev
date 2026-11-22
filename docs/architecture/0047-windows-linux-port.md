# Windows and Linux port

Status: accepted, being carried out in #481.

## Decision

Vibe Manager runs on Windows and on Linux from the same Swift code base. SwiftUI exists on neither,
so the views are rewritten; everything below them is shared.

- **Toolchain:** Swift 6.4.2 on both. Swift 6.2 cannot build swift-crypto against Visual Studio 18
  on the Windows runner (`STL1000`). `swift build --build-system native` on both: the new build
  system fails to `Touch` resource bundles on Windows, and one build system for both keeps their
  failures comparable.
- **Platforms:** Windows 10 1809 at least, the first with ConPTY; x64 first. Linux: Ubuntu 24.04 at
  least (GTK 4.14, WebKitGTK 6.0), x86_64 first, GNOME and KDE, Wayland and X11. Neither Flatpak
  nor Snap: their sandbox gets in the way of the shells, git and agents run in projects.
- **Manifest:** outside macOS, `Package.swift` declares only the modules already ported, and no
  external dependency unless a ported module needs it. The Mac's manifest does not change.
- **Interface:** SwiftCrossUI, with its WinUI backend on Windows and its GTK 4 backend on Linux,
  subject to the go/no-go of #491. If it fails: WinUI 3 driven directly from Swift on Windows,
  adwaita-swift or GTK directly on Linux. Either way the shared core stays.
- **Rejected:** .NET, which would share nothing with the Mac and double every change to the core.

## Consequences

The Mac's behaviour does not change. Code for both other platforms sits behind
`#if !canImport(Darwin)`, code for one of them behind `#if os(Windows)` or `#if os(Linux)`, or it
implements an existing port of `VibeApplication`. `.github/workflows/windows.yml` and
`.github/workflows/linux.yml` report each module, and a module becomes required with the ticket
that ports it. Later tickets of #481 record their own choices here, including any test skipped on
one platform and why.
