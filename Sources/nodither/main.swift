// nodither: stop temporal dithering on external displays (Apple Silicon, SDR).
//   apply [monitor ...]    set each external display's link to 8-bit (RGB full range when offered),
//                          then set enableDither = No
//   status                 show enableDither and the current link format per external display
//   install [monitor ...]  copy this binary to ~/.local/bin and load a LaunchAgent that runs
//                          `agent` at login and whenever a display is attached
//   uninstall              unload the LaunchAgent, restore the link and dithering defaults, remove files
//   agent [monitor ...]    (run by the LaunchAgent) wait for displays to settle, then `apply`
// Monitor names are case-insensitive substrings; without any, all external displays are managed.

import CoreGraphics
import Foundation
import IOKit
import XPC

// MARK: - Private API (resolved at runtime; nil if a macOS update removes it)

private func sym<T>(_ lib: String, _ name: String, _: T.Type) -> T? {
    guard let handle = dlopen(lib, RTLD_LAZY), let p = dlsym(handle, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
private let ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"

private let SLSGetCurrentDisplayMode = sym(skyLight, "SLSGetCurrentDisplayMode",
    (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> CGError).self)
// (display, mode, LinkDescription *out, int *inOutCount, int *outCurrentIndex)
private let SLSGetDisplayOutputModeLinkDescriptions = sym(skyLight, "SLSGetDisplayOutputModeLinkDescriptions",
    (@convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> CGError).self)
// (config, display, LinkDescription): the 16-byte struct is passed by value in two registers.
private let SLSConfigureDisplayOutputMode = sym(skyLight, "SLSConfigureDisplayOutputMode",
    (@convention(c) (CGDisplayConfigRef, CGDirectDisplayID, UInt64, UInt64) -> CGError).self)

private let IOAVVideoInterfaceCreateWithService = sym(ioKit, "IOAVVideoInterfaceCreateWithService",
    (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self)
private let IOAVVideoInterfaceCopyDisplayAttributes = sym(ioKit, "IOAVVideoInterfaceCopyDisplayAttributes",
    (@convention(c) (CFTypeRef) -> Unmanaged<CFDictionary>?).self)
private let IOAVVideoInterfaceGetLinkData = sym(ioKit, "IOAVVideoInterfaceGetLinkData",
    (@convention(c) (CFTypeRef, UnsafeMutableRawPointer) -> IOReturn).self)

/// WindowServer's description of a display link ("output mode").
struct LinkDescription: Equatable {
    var bitDepth: UInt32
    var range: UInt32     // 1 = full, 0 = limited
    var eotf: UInt32      // 0 = SDR
    var encoding: UInt32  // 0 = RGB, 1 = YCbCr 4:4:4, 2 = YCbCr 4:2:2

    static let zero = LinkDescription(bitDepth: 0, range: 0, eotf: 0, encoding: 0)

    var name: String {
        let encodings: [UInt32: String] = [0: "RGB", 1: "YCbCr 4:4:4", 2: "YCbCr 4:2:2"]
        return "\(bitDepth)-bit \(encodings[encoding] ?? "encoding \(encoding)"), \(range == 1 ? "full" : "limited") range"
    }
}

/// Monitor name filters from the command line; empty means every external display.
var only = Array(CommandLine.arguments.dropFirst(2))
func managed(_ name: String?) -> Bool {
    guard !only.isEmpty else { return true }
    return name.map { n in only.contains { n.localizedCaseInsensitiveContains($0) } } ?? false
}

/// Set when any step fails; becomes the exit status, which `launchctl print` shows.
var failed = false
func fail(_ message: String) {
    print(message)
    failed = true
}

// MARK: - IORegistry

/// All services of an IOKit class; the caller releases them.
func services(_ cls: String) -> [io_service_t] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    return Array(AnyIterator { let s = IOIteratorNext(iter); return s == 0 ? nil : s })
}

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// A monitor from DisplayAttributes.ProductAttributes. The framebuffer, the DCP video interface
/// and CoreGraphics all report the same product ID and serial, which ties the three together.
struct Monitor {
    let id: String
    let name: String

    init?(_ displayAttributes: Any?) {
        guard let p = (displayAttributes as? [String: Any])?["ProductAttributes"] as? [String: Any] else { return nil }
        id = "\(p["ProductID"] as? Int ?? 0)/\(p["SerialNumber"] as? Int ?? 0)"
        name = p["ProductName"] as? String ?? "display \(id)"
    }

    static func id(_ display: CGDirectDisplayID) -> String {
        "\(CGDisplayModelNumber(display))/\(CGDisplaySerialNumber(display))"
    }
}

/// External display pipes, matched via IOMobileFramebufferAP like Stillcolor (parent class of
/// AppleCLCD2 and IOMobileFramebufferShim). `monitor` is nil when nothing is connected.
func externalFramebuffers() -> [(service: io_service_t, monitor: Monitor?)] {
    services("IOMobileFramebufferAP").compactMap { service in
        guard property(service, "external") as? Bool == true else { IOObjectRelease(service); return nil }
        return (service, Monitor(property(service, "DisplayAttributes")))
    }
}

/// Current link per monitor id, as reported by the display coprocessor (DCP) itself.
func currentLinks() -> [String: String] {
    guard let create = IOAVVideoInterfaceCreateWithService, let copyAttributes = IOAVVideoInterfaceCopyDisplayAttributes,
          let getLinkData = IOAVVideoInterfaceGetLinkData else { return [:] }
    let encodings: [UInt32: String] = [0: "RGB", 2: "YCbCr 4:2:2", 3: "YCbCr 4:4:4"]
    var links: [String: String] = [:]
    for service in services("DCPAVVideoInterfaceProxy") {
        defer { IOObjectRelease(service) }
        guard let iface = create(kCFAllocatorDefault, service)?.takeRetainedValue(),
              let monitor = Monitor(copyAttributes(iface)?.takeRetainedValue()) else { continue }
        // The active color element starts at offset 8: depth, pixel encoding, dynamic range (0 = full), ...
        var data = [UInt32](repeating: 0, count: 64)
        guard getLinkData(iface, &data) == kIOReturnSuccess, data[2] != 0 else { continue }
        links[monitor.id] = "\(data[2])-bit \(encodings[data[3]] ?? "encoding \(data[3])"), \(data[4] == 0 ? "full" : "limited") range"
    }
    return links
}

// MARK: - Commands

func externalDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
}

/// Set each managed external display's link to the preferred 8-bit link, or with `restore` to
/// WindowServer's own choice (the first link it lists, which is what it picks by default).
func setLinks(restore: Bool = false) {
    guard let getMode = SLSGetCurrentDisplayMode, let getLinks = SLSGetDisplayOutputModeLinkDescriptions,
          let configure = SLSConfigureDisplayOutputMode else {
        return fail("link: SkyLight output-mode API not found on this macOS, skipping")
    }
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    var config: CGDisplayConfigRef?
    for id in externalDisplays() {
        let name = fbs.lazy.compactMap(\.monitor).first { $0.id == Monitor.id(id) }?.name ?? "display \(id)"
        guard managed(name) else { continue }
        var mode: Int32 = 0
        var descs = [LinkDescription](repeating: .zero, count: 32)
        var count = Int32(descs.count), current: Int32 = -1
        guard getMode(id, &mode) == .success, getLinks(id, mode, &descs, &count, &current) == .success else {
            fail("\(name): could not read link modes")
            continue
        }
        descs = Array(descs.prefix(Int(count)))
        // Any 8-bit SDR link leaves the monitor nothing to dither; encoding and range only affect
        // color accuracy. Prefer RGB, then YCbCr 4:4:4, then 4:2:2, and full range over limited.
        let target = restore ? descs.first : descs.filter { $0.bitDepth == 8 && $0.eotf == 0 }
            .min { ($0.encoding, $0.range == 1 ? 0 : 1) < ($1.encoding, $1.range == 1 ? 0 : 1) }
        guard let target else {
            fail("\(name): no \(restore ? "" : "8-bit ")link offered for the current mode")
            continue
        }
        if descs.indices.contains(Int(current)), descs[Int(current)] == target {
            print("\(name): link already \(target.name)")
            continue
        }
        if config == nil, CGBeginDisplayConfiguration(&config) != .success {
            return fail("could not begin display configuration")
        }
        let err = configure(config!, id, UInt64(target.bitDepth) | UInt64(target.range) << 32,
                            UInt64(target.eotf) | UInt64(target.encoding) << 32)
        err == .success ? print("\(name): set link to \(target.name)") : fail("\(name): set link failed (\(err.rawValue))")
    }
    if let config, CGCompleteDisplayConfiguration(config, .permanently) != .success {
        fail("display configuration failed")
    }
}

func setDither(_ enabled: Bool) {
    let fbs = externalFramebuffers()
    if fbs.isEmpty { fail("no external display pipes found") }
    if !only.isEmpty, !fbs.contains(where: { $0.monitor != nil && managed($0.monitor?.name) }) {
        fail("no connected monitor matches \(only.joined(separator: ", "))")
    }
    for fb in fbs {
        defer { IOObjectRelease(fb.service) }
        guard managed(fb.monitor?.name) else { continue }
        let name = fb.monitor?.name ?? "(no display)"
        let kr = IORegistryEntrySetCFProperty(fb.service, "enableDither" as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        kr == KERN_SUCCESS ? print("\(name): enableDither = \(enabled ? "Yes" : "No")")
                           : fail("\(name): enableDither failed: \(String(cString: mach_error_string(kr)))")
    }
}

func apply() {
    setLinks()
    setDither(false)
}

/// Launched by launchd at login and when a display attaches; nothing stays resident between runs.
func agent() {
    print("[\(Date())] agent")
    // launchd keeps relaunching the job until its IOKit match events are received.
    let lock = NSLock()
    var lastEvent = Date()
    xpc_set_event_stream_handler("com.apple.iokit.matching", .global()) { _ in
        lock.withLock { lastEvent = Date() }
    }
    // Wait until WindowServer has every connected external display online and
    // nothing new has attached for 2 s (max 30 s), so the link is up before we touch it.
    // Go again if another display attached after that, since its event was delivered to us.
    var settled: Date
    repeat {
        let start = Date()
        repeat {
            settled = lock.withLock { lastEvent }
            let fbs = externalFramebuffers()
            let connected = fbs.filter { $0.monitor != nil }.count
            fbs.forEach { IOObjectRelease($0.service) }
            if connected > 0, externalDisplays().count >= connected, Date().timeIntervalSince(settled) >= 2 { break }
            usleep(250_000)
        } while Date().timeIntervalSince(start) < 30
        apply()
    } while lock.withLock({ lastEvent }) != settled
}

func status() {
    let links = currentLinks()
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    for case let (service, monitor?) in fbs {
        let dither = (property(service, "enableDither") as? Bool).map { $0 ? "Yes" : "No" } ?? "?"
        print(monitor.name)
        print("  enableDither  \(dither)")
        print("  link          \(links[monitor.id] ?? "unknown")")
    }
}

let label = "local.nodither"
let home = FileManager.default.homeDirectoryForCurrentUser
let installedBinary = home.appendingPathComponent(".local/bin/nodither")
let agentPlist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")

@discardableResult
func launchctl(_ args: String...) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func install() throws {
    let fm = FileManager.default
    let me = Bundle.main.executableURL!.resolvingSymlinksInPath()
    try fm.createDirectory(at: installedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
    if me.path != installedBinary.path {
        try? fm.removeItem(at: installedBinary)
        try fm.copyItem(at: me, to: installedBinary)
    }
    let log = home.appendingPathComponent("Library/Logs/nodither.log").path
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [installedBinary.path, "agent"] + only,
        "RunAtLoad": true,
        // launchd watches IOKit and starts us only when a monitor's AV service appears.
        "LaunchEvents": ["com.apple.iokit.matching": ["display attached": [
            "IOProviderClass": "DCPAVServiceProxy",
            "IOPropertyMatch": ["Location": "External"],
            "IOMatchLaunchStream": true,
        ]]],
        "StandardOutPath": log,
        "StandardErrorPath": log,
    ]
    try fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentPlist)
    let domain = "gui/\(getuid())"
    launchctl("bootout", "\(domain)/\(label)")
    let rc = launchctl("bootstrap", domain, agentPlist.path)
    rc == 0 ? print("installed \(installedBinary.path)\nloaded \(agentPlist.path) (log: \(log))")
            : fail("launchctl bootstrap failed (\(rc))")
}

func uninstall() {
    // Restore exactly the monitors the installed agent managed.
    if let args = NSDictionary(contentsOf: agentPlist)?["ProgramArguments"] as? [String] {
        only = Array(args.dropFirst(2))
    }
    launchctl("bootout", "gui/\(getuid())/\(label)")
    setLinks(restore: true)
    setDither(true)
    try? FileManager.default.removeItem(at: agentPlist)
    try? FileManager.default.removeItem(at: installedBinary)
    print("removed \(agentPlist.path) and \(installedBinary.path)")
}

switch CommandLine.arguments.dropFirst().first {
case "apply": apply()
case "agent": agent()
case "status": status()
case "install": do { try install() } catch { fail("install failed: \(error)") }
case "uninstall": uninstall()
default:
    print("usage: nodither apply [monitor ...] | install [monitor ...] | status | uninstall")
    exit(2)
}
exit(failed ? 1 : 0)
