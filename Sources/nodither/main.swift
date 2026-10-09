// nodither: stop temporal dithering on external displays (Apple Silicon, SDR).
//   apply      set each external display's link to 8-bit RGB (full range), then set enableDither = No
//   status     show enableDither and the current link format per external display
//   install    copy this binary to ~/.local/bin and load a LaunchAgent that runs `agent`
//              at login and whenever a display is attached
//   uninstall  unload and remove the LaunchAgent and the installed binary
//   agent      (run by the LaunchAgent) wait for displays to settle, then `apply`

import CoreGraphics
import Foundation
import IOKit
import XPC

// MARK: - Private API (resolved at runtime)

private func sym<T>(_ lib: String, _ name: String, _: T.Type) -> T {
    guard let handle = dlopen(lib, RTLD_LAZY), let p = dlsym(handle, name) else {
        fatalError("\(name) not found in \(lib)")
    }
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
private let IOAVVideoInterfaceGetLinkData = sym(ioKit, "IOAVVideoInterfaceGetLinkData",
    (@convention(c) (CFTypeRef, UnsafeMutableRawPointer) -> IOReturn).self)

/// WindowServer's description of a display link ("output mode").
struct LinkDescription: Equatable {
    var bitDepth: UInt32
    var range: UInt32     // 1 = full, 0 = limited
    var eotf: UInt32      // 0 = SDR
    var encoding: UInt32  // 0 = RGB, 1 = YCbCr 4:4:4, 2 = YCbCr 4:2:2

    static let zero = LinkDescription(bitDepth: 0, range: 0, eotf: 0, encoding: 0)
    static let rgb8Full = LinkDescription(bitDepth: 8, range: 1, eotf: 0, encoding: 0)
}

// MARK: - IORegistry

struct Framebuffer {
    let service: io_service_t
    let node: String       // display pipe, e.g. "disp0", "dispext0"
    let name: String?      // monitor name; nil when nothing is connected
    let productID: Int?
    let serial: Int?
}

/// External display pipes. Matches IOMobileFramebufferAP like Stillcolor (parent class of AppleCLCD2 and IOMobileFramebufferShim).
func externalFramebuffers() -> [Framebuffer] {
    var result: [Framebuffer] = []
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iter) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iter) }
    while case let service = IOIteratorNext(iter), service != 0 {
        guard property(service, "external") as? Bool == true else { IOObjectRelease(service); continue }
        var parent: io_registry_entry_t = 0
        var name = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            IORegistryEntryGetName(parent, &name)
            IOObjectRelease(parent)
        }
        let product = (property(service, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any]
        result.append(Framebuffer(service: service, node: String(cString: name),
                                  name: product?["ProductName"] as? String,
                                  productID: product?["ProductID"] as? Int,
                                  serial: product?["SerialNumber"] as? Int))
    }
    return result
}

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

/// Current link as reported by the display coprocessor (DCP) driving this pipe:
/// disp0 is driven by dcp, dispextN by dcpextN.
func currentLink(_ fb: Framebuffer) -> (depth: UInt32, encoding: UInt32, limited: Bool)? {
    let dcp = fb.node.hasPrefix("dispext") ? "dcpext" + fb.node.dropFirst("dispext".count) : "dcp"
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVVideoInterfaceProxy"), &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    while case let service = IOIteratorNext(iter), service != 0 {
        defer { IOObjectRelease(service) }
        var path = [CChar](repeating: 0, count: 1024)
        guard IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS,
              String(cString: path).contains("/\(dcp)@"),
              let iface = IOAVVideoInterfaceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue()
        else { continue }
        // The active color element sits at offset 8: depth, pixel encoding, dynamic range (0 = full), ...
        var data = [UInt32](repeating: 0, count: 64)
        guard IOAVVideoInterfaceGetLinkData(iface, &data) == kIOReturnSuccess, data[2] != 0 else { return nil }
        return (data[2], data[3], data[4] != 0)
    }
    return nil
}

// MARK: - Commands

func externalDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
}

func displayName(_ id: CGDirectDisplayID, _ fbs: [Framebuffer]) -> String {
    let fb = fbs.first { $0.productID == Int(CGDisplayModelNumber(id)) && $0.serial == Int(CGDisplaySerialNumber(id)) }
    return fb?.name ?? "display \(id)"
}

func setLinkModes() {
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    var config: CGDisplayConfigRef?
    for id in externalDisplays() {
        let name = displayName(id, fbs)
        var mode: Int32 = 0
        var descs = [LinkDescription](repeating: .zero, count: 32)
        var count = Int32(descs.count), current: Int32 = -1
        guard SLSGetCurrentDisplayMode(id, &mode) == .success,
              SLSGetDisplayOutputModeLinkDescriptions(id, mode, &descs, &count, &current) == .success else {
            print("\(name): could not read link modes")
            continue
        }
        descs = Array(descs.prefix(Int(count)))
        if descs.indices.contains(Int(current)), descs[Int(current)] == .rgb8Full {
            print("\(name): link already 8-bit RGB")
            continue
        }
        guard descs.contains(.rgb8Full) else {
            print("\(name): 8-bit RGB full range is not offered for the current mode")
            continue
        }
        if config == nil { CGBeginDisplayConfiguration(&config) }
        let t = LinkDescription.rgb8Full
        let err = SLSConfigureDisplayOutputMode(config!, id, UInt64(t.bitDepth) | UInt64(t.range) << 32,
                                                UInt64(t.eotf) | UInt64(t.encoding) << 32)
        print("\(name): set link to 8-bit RGB -> \(err == .success ? "ok" : "error \(err.rawValue)")")
    }
    if let config {
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success { print("display configuration failed: error \(err.rawValue)") }
    }
}

func disableDither() {
    for fb in externalFramebuffers() {
        defer { IOObjectRelease(fb.service) }
        let kr = IORegistryEntrySetCFProperty(fb.service, "enableDither" as CFString, kCFBooleanFalse)
        print("\(fb.name ?? "(no display)") [\(fb.node)]: enableDither = No -> \(String(cString: mach_error_string(kr)))")
    }
}

func apply() {
    setLinkModes()
    disableDither()
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
    let start = Date()
    while Date().timeIntervalSince(start) < 30 {
        let fbs = externalFramebuffers()
        let connected = fbs.filter { $0.name != nil }.count
        fbs.forEach { IOObjectRelease($0.service) }
        let online = externalDisplays().count
        if connected > 0, online >= connected, lock.withLock({ Date().timeIntervalSince(lastEvent) }) >= 2 { break }
        usleep(250_000)
    }
    status()
    apply()
}

func status() {
    let encodings: [UInt32: String] = [0: "RGB", 2: "YCbCr 4:2:2", 3: "YCbCr 4:4:4"]
    let fbs = externalFramebuffers()
    defer { fbs.forEach { IOObjectRelease($0.service) } }
    for fb in fbs where fb.name != nil {
        let dither = (property(fb.service, "enableDither") as? Bool).map { $0 ? "Yes" : "No" } ?? "?"
        let link = currentLink(fb).map {
            "\($0.depth)-bit \(encodings[$0.encoding] ?? "encoding \($0.encoding)"), \($0.limited ? "limited" : "full") range"
        } ?? "unknown"
        print("\(fb.name!) [\(fb.node)]")
        print("  enableDither  \(dither)")
        print("  link          \(link)")
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
        "ProgramArguments": [installedBinary.path, "agent"],
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
    print(rc == 0 ? "installed \(installedBinary.path)\nloaded \(agentPlist.path) (log: \(log))"
                  : "launchctl bootstrap failed (\(rc))")
}

func uninstall() {
    launchctl("bootout", "gui/\(getuid())/\(label)")
    try? FileManager.default.removeItem(at: agentPlist)
    try? FileManager.default.removeItem(at: installedBinary)
    print("removed \(agentPlist.path) and \(installedBinary.path)")
}

switch CommandLine.arguments.dropFirst().first {
case "apply": apply()
case "agent": agent()
case "status": status()
case "install": do { try install() } catch { print("install failed: \(error)"); exit(1) }
case "uninstall": uninstall()
default:
    print("usage: nodither apply | status | install | uninstall")
    exit(2)
}
