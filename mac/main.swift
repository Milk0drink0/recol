// Recol — native macOS shell.
// A real NSWindow (real traffic lights) hosting the Recol UI in a WKWebView.
// Clips are stored in ~/Library/Application Support/Recol and served to the page at recol://app/files/…
// Dragging clips past the window edge hands them to a real macOS drag session (Finder, Safari, Mail, Notes…).
// ⌃⌘C anywhere saves the current selection / clipboard into Recol without opening the window.

import Cocoa
import WebKit
import UniformTypeIdentifiers
import Carbon.HIToolbox
import ServiceManagement
import ApplicationServices
import QuickLookThumbnailing
import QuickLookUI

let paper = NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x1B / 255, green: 0x19 / 255, blue: 0x18 / 255, alpha: 1)
        : NSColor(srgbRed: 0xF5 / 255, green: 0xF3 / 255, blue: 0xEF / 255, alpha: 1)
}
let toolbarHeight: CGFloat = 52

let fm = FileManager.default
let supportDir: URL = {
    let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Recol", isDirectory: true)
    try? fm.createDirectory(at: u.appendingPathComponent("files", isDirectory: true), withIntermediateDirectories: true)
    return u
}()
let filesDir = supportDir.appendingPathComponent("files", isDirectory: true)
let stateFile = supportDir.appendingPathComponent("clipboards.json")
let webDir = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
// Anything (an AI, a script, Shortcuts) can drop a small JSON file here and Recol adds it as a clip.
let inboxDir = supportDir.appendingPathComponent("inbox", isDirectory: true)
// Each plugin is a folder here with plugin.json + main.js (see PLUGINS.md).
let pluginsDir = supportDir.appendingPathComponent("plugins", isDirectory: true)
let mcpScript = supportDir.appendingPathComponent("recol-mcp.py")
// Copy history: the last few things copied in any app (text, images, files). Stays on this Mac.
let historyDir: URL = {
    let u = supportDir.appendingPathComponent("history", isDirectory: true)
    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let historyFile = supportDir.appendingPathComponent("history.json")
struct HistItem: Codable {
    var id: String, kind: String, at: Double
    var text: String?, files: [String]?, image: String?, app: String?
}

func isInside(_ url: URL, _ root: URL) -> Bool {
    url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
}
func validKey(_ k: String) -> Bool { k.range(of: "^[a-z0-9]{4,40}$", options: .regularExpression) != nil }
func safeName(_ n: String) -> String {
    let s = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    let t = s.hasPrefix(".") ? String(s.drop(while: { $0 == "." })) : s
    return t.isEmpty ? "clip" : String(t.prefix(120))
}
func newKey() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)) }

/// "key/File name.pdf" -> ~/Library/Application Support/Recol/files/key/File name.pdf
func clipFile(_ path: String) -> URL? {
    let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, validKey(parts[0]) else { return nil }
    let name = (parts[1] as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { return nil }
    let u = filesDir.appendingPathComponent(parts[0]).appendingPathComponent(name)
    return isInside(u, filesDir) ? u : nil
}

// Large files are *linked*, not copied: we keep a bookmark to the original, which survives moves and renames.
let refsFile = supportDir.appendingPathComponent("links.json")
let thumbsDir: URL = {
    let u = supportDir.appendingPathComponent("thumbs", isDirectory: true)
    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
var refs: [String: String] = {   // key -> base64 bookmark data
    guard let d = try? Data(contentsOf: refsFile), let r = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
    return r
}()
func saveRefs() { if let d = try? JSONEncoder().encode(refs) { try? d.write(to: refsFile, options: .atomic) } }

func resolveRef(_ key: String) -> URL? {
    guard let b64 = refs[key], let data = Data(base64Encoded: b64) else { return nil }
    var stale = false
    guard let u = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
    if stale, let fresh = try? u.bookmarkData() { refs[key] = fresh.base64EncodedString(); saveRefs() }
    return fm.fileExists(atPath: u.path) ? u : nil
}

/// The real file behind a clip: its copy inside Recol, or the linked original.
func resolveFile(_ path: String) -> URL? {
    guard let key = path.split(separator: "/", maxSplits: 1).first.map(String.init), validKey(key) else { return nil }
    if refs[key] != nil { return resolveRef(key) }
    return clipFile(path)
}
func fileForKey(_ key: String) -> URL? {
    guard validKey(key) else { return nil }
    if refs[key] != nil { return resolveRef(key) }
    let dir = filesDir.appendingPathComponent(key)
    guard let name = (try? fm.contentsOfDirectory(atPath: dir.path))?.first(where: { !$0.hasPrefix(".") }) else { return nil }
    return dir.appendingPathComponent(name)
}
func pngData(_ img: NSImage, size: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    guard let rep else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - recol:// scheme (app bundle + stored clip files, with byte ranges for video)

@MainActor
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    var stopped = Set<ObjectIdentifier>()

    func respond(_ task: WKURLSchemeTask, _ url: URL, _ data: Data?, mime: String = "image/png") {
        if stopped.remove(ObjectIdentifier(task)) != nil { return }
        guard let data else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish(); return
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!)
        task.didReceive(data); task.didFinish()
    }

    // Quick Look thumbnail for any file type macOS (or an installed app) knows how to preview. 404 if none.
    func thumbnail(_ key: String, _ task: WKURLSchemeTask, _ url: URL) {
        let cache = thumbsDir.appendingPathComponent(key + ".png")
        if let d = try? Data(contentsOf: cache) { respond(task, url, d); return }
        guard validKey(key), let file = fileForKey(key) else { respond(task, url, nil); return }
        let req = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 360, height: 360), scale: 2,
                                               representationTypes: [.lowQualityThumbnail, .thumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            let data = rep.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let data { try? data.write(to: cache) }
                    self.respond(task, url, data)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        if path.hasPrefix("/thumb/") { thumbnail(String(path.dropFirst(7)), task, url); return }
        if path.hasPrefix("/icon/") {
            let f = fileForKey(String(path.dropFirst(6)))
            respond(task, url, f.flatMap { pngData(NSWorkspace.shared.icon(forFile: $0.path), size: 256) }); return
        }
        var target: URL?
        if path.hasPrefix("/files/") { target = resolveFile(String(path.dropFirst(7))) }
        else if path.hasPrefix("/history/") { let u = historyDir.appendingPathComponent(String(path.dropFirst(9))); target = isInside(u, historyDir) ? u : nil }
        else if path.hasPrefix("/plugins/") { let u = pluginsDir.appendingPathComponent(String(path.dropFirst(9))); target = isInside(u, pluginsDir) ? u : nil }
        else { let u = webDir.appendingPathComponent(String(path.dropFirst())); target = isInside(u, webDir) ? u : nil }

        guard let file = target, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish(); return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var body = data, status = 200
        var headers = ["Content-Type": mime, "Accept-Ranges": "bytes", "Cache-Control": "no-cache"]
        if let h = task.request.value(forHTTPHeaderField: "Range"), let r = byteRange(h, data.count) {
            body = data.subdata(in: r); status = 206
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
        }
        headers["Content-Length"] = String(body.count)
        task.didReceive(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(body)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    private func byteRange(_ h: String, _ n: Int) -> Range<Int>? {
        guard h.hasPrefix("bytes="), n > 0, let spec = h.dropFirst(6).split(separator: ",").first else { return nil }
        let ab = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard ab.count == 2 else { return nil }
        var a: Int, b: Int
        if ab[0].isEmpty { guard let s = Int(ab[1]) else { return nil }; a = max(0, n - s); b = n - 1 }
        else { guard let s = Int(ab[0]) else { return nil }; a = s; b = Int(ab[1]) ?? n - 1 }
        b = min(b, n - 1)
        return a <= b ? a ..< (b + 1) : nil
    }
}

// MARK: - web view that takes Finder file drops itself

final class RecolWebView: WKWebView {
    weak var app: App?
    private var handledNatively = false

    // Clicks reach Recol even when it's behind other windows, and a press doesn't bring it forward yet:
    // if it turns into a drag, the windows on top stay on top so you can drop into them. A plain click
    // (press + release without leaving Recol) brings Recol to the front as usual.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { !NSApp.isActive }
    override func mouseDown(with e: NSEvent) {
        if !NSApp.isActive { NSApp.preventWindowOrdering(); app?.pendingActivate = true }
        super.mouseDown(with: e)
    }
    override func mouseUp(with e: NSEvent) {
        super.mouseUp(with: e)
        guard let app, app.pendingActivate else { return }
        app.pendingActivate = false
        if !app.nativeDragging { NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        handledNatively = false
        let pb = sender.draggingPasteboard
        if let app, let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, !urls.contains(where: { $0.pathExtension.lowercased() == "recol" }) {
            var p = convert(sender.draggingLocation, from: nil)
            if !isFlipped { p.y = bounds.height - p.y }
            super.draggingExited(sender)          // lets the page clear its drop highlight
            handledNatively = true
            MainActor.assumeIsolated { app.ingestFiles(urls, at: p) }
            return true
        }
        return super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if handledNatively { handledNatively = false; return }
        super.concludeDragOperation(sender)
    }
}

// MARK: - global hotkey (Carbon; needs no permission)

private var hotKeyRef: EventHotKeyRef?
private var hotKeyHandlerInstalled = false

// "^@c" → ⌃⌘C. ^ control, ~ option, $ shift, @ command, then a letter or digit.
let keyCodes: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
    "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N,
    "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V,
    "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
    "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9]
struct Shortcut: Equatable {
    var key: Character = "c", ctrl = true, opt = false, shift = false, cmd = true
    init() {}
    init?(_ s: String) {
        guard let k = s.last, keyCodes[k] != nil else { return nil }
        let m = s.dropLast()
        guard m.allSatisfy({ "^~$@".contains($0) }), m.contains("@") else { return nil }
        key = k; ctrl = m.contains("^"); opt = m.contains("~"); shift = m.contains("$"); cmd = true
    }
    var services: String { "@" + (opt ? "~" : "") + (ctrl ? "^" : "") + (shift ? "$" : "") + String(key) }
    var carbonMods: UInt32 { UInt32(cmdKey) | (ctrl ? UInt32(controlKey) : 0) | (opt ? UInt32(optionKey) : 0) | (shift ? UInt32(shiftKey) : 0) }
    var menuMods: NSEvent.ModifierFlags { var f: NSEvent.ModifierFlags = .command; if ctrl { f.insert(.control) }; if opt { f.insert(.option) }; if shift { f.insert(.shift) }; return f }
}
var hotKeyShortcut = Shortcut()

func setGlobalHotKey(_ on: Bool, _ sc: Shortcut = hotKeyShortcut) {
    if let ref = hotKeyRef, sc != hotKeyShortcut || !on { UnregisterEventHotKey(ref); hotKeyRef = nil }
    hotKeyShortcut = sc
    if !hotKeyHandlerInstalled {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { (NSApp.delegate as? App)?.quickSave(fromHotKey: true) } }
            return noErr
        }, 1, &spec, nil, nil)
        hotKeyHandlerInstalled = true
    }
    if on, hotKeyRef == nil {
        let id = EventHotKeyID(signature: OSType(0x5243_4F4C), id: 1) // 'RCOL'
        RegisterEventHotKey(UInt32(keyCodes[sc.key] ?? kVK_ANSI_C), sc.carbonMods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - Services shortcut (⌃⌘C bound to Services › Save to Recol — needs no permission)

let serviceKey = "app.recol.Recol - Save to Recol - saveToRecol"

func setServiceShortcut(_ on: Bool, _ sc: Shortcut = Shortcut()) {
    let domain = "pbs" as CFString
    var all = (CFPreferencesCopyAppValue("NSServicesStatus" as CFString, domain) as? [String: Any]) ?? [:]
    var entry = (all[serviceKey] as? [String: Any]) ?? [:]
    let want = on ? sc.services : ""
    if (entry["key_equivalent"] as? String ?? "") == want, entry["enabled_services_menu"] as? Bool == true { return }
    entry["key_equivalent"] = want
    entry["enabled_services_menu"] = true
    entry["enabled_context_menu"] = true
    all[serviceKey] = entry
    CFPreferencesSetAppValue("NSServicesStatus" as CFString, all as CFDictionary, domain)
    CFPreferencesAppSynchronize(domain)
    NSUpdateDynamicServices()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
    p.arguments = ["-update"]
    try? p.run()
}

func serviceShortcutActive(_ sc: Shortcut) -> Bool {
    let all = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, "pbs" as CFString) as? [String: Any]
    return ((all?[serviceKey] as? [String: Any])?["key_equivalent"] as? String) == sc.services
}

// WebKit caps page animation at 60 fps unless told otherwise; on a 120 Hz display that makes dragging look choppy.
// This flips WebKit's own (internal) feature switch when it exists, and does nothing when it doesn't.
func allowHighFrameRate(_ prefs: WKPreferences) {
    let cls: AnyObject = WKPreferences.self
    let getter = NSSelectorFromString("_features"), setter = NSSelectorFromString("_setEnabled:forFeature:")
    guard cls.responds(to: getter), prefs.responds(to: setter),
          let list = cls.perform(getter)?.takeUnretainedValue() as? [NSObject] else { return }
    typealias SetFn = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
    let set = unsafeBitCast(prefs.method(for: setter), to: SetFn.self)
    for f in list where (f.value(forKey: "key") as? String) == "PreferPageRenderingUpdatesNear60FPSEnabled" { set(prefs, setter, false, f) }
}

// MARK: - App

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandlerWithReply,
                 WKUIDelegate, WKNavigationDelegate, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var win: NSWindow!
    var web: RecolWebView!
    let scheme = SchemeHandler()
    var linkLarge = 10   // MB; 0 = always link, -1 = never

    var lastMouseDown: NSEvent?
    var armed: [[String: Any]]?        // the clip(s) currently held by the pointer in the page
    var armedImage: NSImage?           // snapshot of the grabbed clip, used as the drag image
    var nativeDragging = false
    var pendingActivate = false
    var armedImmediate = false   // locked boards: any drag goes straight out as a real macOS drag
    var exportWin: NSWindow?
    var exportWeb: WKWebView?
    var exportName = "Recol"

    var statusItem: NSStatusItem?
    var hudPanel: NSPanel?
    var copyFirst = true
    var askedForAccessibility = false
    var pageReady = false
    var history: [HistItem] = []
    var historyOn = true
    var lastChange = NSPasteboard.general.changeCount
    var ownChange = -1
    var historyTimer: Timer?

    // MARK: copy history — watch the system clipboard (no permission needed), keep the last 10 copies
    func startHistory() {
        if let d = try? Data(contentsOf: historyFile), let h = try? JSONDecoder().decode([HistItem].self, from: d) { history = h }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? App)?.checkPasteboard() }
        }
    }
    func saveHistory() { if let d = try? JSONEncoder().encode(history) { try? d.write(to: historyFile, options: .atomic) } }
    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard historyOn, pb.changeCount != ownChange else { return }
        // Password managers mark secrets; never keep those (nspasteboard.org conventions).
        let skip: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
                                 "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping", "Pasteboard generator type"]
        let types = (pb.types ?? []).map(\.rawValue)
        if types.contains(where: skip.contains) { return }
        let front = NSWorkspace.shared.frontmostApplication
        var item = HistItem(id: newKey(), kind: "text", at: Date().timeIntervalSince1970 * 1000, app: front?.localizedName)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            item.kind = "files"; item.files = urls.map(\.path)
        } else if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
                  png.count < 25_000_000 {
            item.kind = "image"; item.image = item.id + ".png"
            try? png.write(to: historyDir.appendingPathComponent(item.image!))
        } else if let t = pb.string(forType: .string), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item.text = String(t.prefix(20000))
        } else { return }
        if let top = history.first, top.kind == item.kind, top.text == item.text, top.files == item.files, item.kind != "image" { return }
        history.insert(item, at: 0)
        while history.count > 10 { let old = history.removeLast(); if let i = old.image { try? fm.removeItem(at: historyDir.appendingPathComponent(i)) } }
        saveHistory()
        js("recolNative.historyChanged && recolNative.historyChanged()")
    }
    func historyList() -> [[String: Any]] {
        history.compactMap { h in (try? JSONEncoder().encode(h)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
    func historyItems(_ id: String) -> [[String: Any]] {
        guard let h = history.first(where: { $0.id == id }) else { return [] }
        switch h.kind {
        case "files": return (h.files ?? []).compactMap { store(URL(fileURLWithPath: $0)).map { ["file": $0] } }
        case "image":
            guard let i = h.image, let d = try? Data(contentsOf: historyDir.appendingPathComponent(i)) else { return [] }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            return storeData(d, name: "Copied image \(f.string(from: Date(timeIntervalSince1970: h.at / 1000))).png").map { [["file": $0]] } ?? []
        default: return h.text.map { [["text": $0]] } ?? []
        }
    }
    func clearHistory() {
        for h in history { if let i = h.image { try? fm.removeItem(at: historyDir.appendingPathComponent(i)) } }
        history = []; saveHistory()
    }
    var inboxSource: DispatchSourceFileSystemObject?
    var quickSaveItems: [NSMenuItem] = []

    // MARK: support files: MCP server for AI apps, example plugins
    func installSupportFiles() {
        let res = Bundle.main.resourceURL!
        let bundled = res.appendingPathComponent("recol-mcp.py")
        if fm.fileExists(atPath: bundled.path) {
            try? fm.removeItem(at: mcpScript)
            try? fm.copyItem(at: bundled, to: mcpScript)
        }
        if !fm.fileExists(atPath: pluginsDir.path) {
            try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            let examples = res.appendingPathComponent("web/plugins")
            for name in (try? fm.contentsOfDirectory(atPath: examples.path)) ?? [] where !name.hasPrefix(".") && name != "index.json" {
                try? fm.copyItem(at: examples.appendingPathComponent(name), to: pluginsDir.appendingPathComponent(name))
            }
        }
    }
    func listPlugins() -> [[String: Any]] {
        let names = ((try? fm.contentsOfDirectory(atPath: pluginsDir.path)) ?? []).sorted()
        return names.compactMap { id in
            guard id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil, !id.hasPrefix(".") else { return nil }
            let mf = pluginsDir.appendingPathComponent(id).appendingPathComponent("plugin.json")
            guard let d = try? Data(contentsOf: mf), let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return ["id": id, "manifest": m]
        }
    }

    // MARK: PDF export
    func exportPDF(board: String, name: String) {
        exportWin?.orderOut(nil)
        exportName = name
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "recol")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "recol")
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        let ew = NSWindow(contentRect: NSRect(x: -32000, y: -32000, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        ew.isReleasedWhenClosed = false
        ew.appearance = win.effectiveAppearance
        ew.contentView = w
        ew.orderBack(nil)
        var comps = URLComponents(string: "recol://app/index.html")!
        comps.queryItems = [URLQueryItem(name: "export", value: board)]
        w.load(URLRequest(url: comps.url!))
        exportWin = ew; exportWeb = w
    }
    func exportReady(w: CGFloat, h: CGFloat) {
        guard let ew = exportWin, let web = exportWeb else { return }
        let size = NSSize(width: max(w, 100), height: max(h, 100))
        ew.setContentSize(size)
        web.frame = NSRect(origin: .zero, size: size)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let pc = WKPDFConfiguration()
                pc.rect = CGRect(origin: .zero, size: size)
                web.createPDF(configuration: pc) { [weak self] result in
                    Task { @MainActor in self?.finishExport(result) }
                }
            }
        }
    }
    func finishExport(_ result: Result<Data, Error>) {
        exportWeb?.configuration.userContentController.removeAllScriptMessageHandlers()
        exportWin?.orderOut(nil); exportWin = nil; exportWeb = nil
        guard case .success(let data) = result else { js("recolNative.toast('Couldn’t make the PDF')"); return }
        if let out = ProcessInfo.processInfo.environment["RECOL_PDF_OUT"] { try? data.write(to: URL(fileURLWithPath: out)); return }   // for automated tests
        if !win.isVisible { showWindow() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = safeName(exportName) + ".pdf"
        panel.beginSheetModal(for: win) { [weak self] r in
            guard r == .OK, let u = panel.url else { return }
            do { try data.write(to: u); self?.js("recolNative.toast('Exported PDF')"); NSWorkspace.shared.activateFileViewerSelecting([u]) }
            catch { self?.js("recolNative.toast('Couldn’t save the PDF')") }
        }
    }

    // MARK: inbox — the simplest API there is: write a JSON file, get a clip
    func watchInbox() {
        try? fm.createDirectory(at: inboxDir, withIntermediateDirectories: true)
        let fd = open(inboxDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { (NSApp.delegate as? App)?.processInbox() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        inboxSource = src
    }
    func processInbox() {
        guard pageReady else { return }
        let files = ((try? fm.contentsOfDirectory(at: inboxDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        var groups: [(board: String?, from: String?, items: [[String: Any]])] = []
        var updates: [[String: Any]] = [], updateFrom: String?
        for f in files {
            defer { try? fm.removeItem(at: f) }
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) else { continue }
            for e in (o as? [[String: Any]]) ?? [(o as? [String: Any]) ?? [:]] {
                if (e["action"] as? String) == "update", let id = e["id"] as? String {
                    var op: [String: Any] = ["id": id]
                    for k in ["label", "comment", "color"] { if let v = e[k] { op[k] = v } }
                    updates.append(op); updateFrom = (e["from"] as? String) ?? updateFrom
                    continue
                }
                var item: [String: Any]?
                if let p = e["path"] as? String {
                    let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                    item = store(u).map { ["file": $0] }
                } else if let n = e["note"] as? String, !n.isEmpty { item = ["note": n] }
                else if let t = (e["url"] as? String) ?? (e["text"] as? String), !t.isEmpty { item = ["text": t] }
                guard let item else { continue }
                let b = e["clipboard"] as? String, from = e["from"] as? String
                if let i = groups.firstIndex(where: { $0.board == b && $0.from == from }) { groups[i].items.append(item) }
                else { groups.append((b, from, [item])) }
            }
        }
        if !updates.isEmpty, let json = jsonString(updates) {
            js("recolNative.apply(\(json), \(jsonString([updateFrom ?? "An app"]).map { String($0.dropFirst().dropLast()) } ?? "null"))")
        }
        for g in groups {
            guard let json = jsonString(g.items) else { continue }
            var opts: [String: Any] = ["from": g.from ?? "An app"]
            if let b = g.board { opts["board"] = b }
            js("recolNative.ingest(\(json), \(jsonString(opts) ?? "{}"))")
            if !win.isKeyWindow { hud("Added to Recol", detail: "\(g.items.count) clip\(g.items.count == 1 ? "" : "s") from \(g.from ?? "an app")") }
        }
    }
    var previewItems: [URL] = []

    // MARK: Quick Look (in-app viewer)
    func showPreview(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        previewItems = urls
        if !win.isVisible { showWindow() }
        win.makeKey()
        if panel.isVisible { panel.reloadData(); panel.currentPreviewItemIndex = 0 } else { panel.makeKeyAndOrderFront(nil) }
    }
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self; panel.delegate = self }
    }
    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil; panel.delegate = nil; js("recolNative.previewClosed()") }
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { previewItems.count } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewItems[index] as NSURL }
    }

    // MARK: Services › Save to Recol — works in any app, needs no permission
    @objc func saveToRecol(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let items = readPasteboard(pboard)
        guard !items.isEmpty else { hud("Nothing to save", detail: "Select something first"); return }
        let what = items.count == 1 ? (items[0]["text"] != nil ? "selection" : "1 clip") : "\(items.count) clips"
        ingest(items, title: "Saved \(what)")
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()

        let cfg = WKWebViewConfiguration()
        allowHighFrameRate(cfg.preferences)
        cfg.setURLSchemeHandler(scheme, forURLScheme: "recol")
        cfg.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "recol")
        web = RecolWebView(frame: .zero, configuration: cfg)
        web.app = self
        web.uiDelegate = self
        web.navigationDelegate = self
        web.allowsMagnification = false
        web.underPageBackgroundColor = paper
        if #available(macOS 13.3, *) { web.isInspectable = true }

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
        win.title = "Recol"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.backgroundColor = paper
        win.minSize = NSSize(width: 560, height: 420)
        win.contentView = web
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("RecolMain")

        web.load(URLRequest(url: URL(string: "recol://app/index.html")!))
        win.makeKeyAndOrderFront(nil)
        layoutTrafficLights()

        // Until the page sends its settings, assume the defaults so ⌃⌘C works right away.
        setServiceShortcut(true)
        installSupportFiles()
        watchInbox()
        startHistory()
        setMenuBar(true)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.watch(e); return e
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Closing the window keeps Recol running (menu bar + ⌃⌘C). ⌘Q quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { showWindow(); return true }
    func windowShouldClose(_ w: NSWindow) -> Bool { w.orderOut(nil); return false }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        guard web != nil else { return .terminateNow }
        web.evaluateJavaScript("window.recolNative ? recolNative.flush() : null") { r, _ in
            if let json = r as? String { try? json.write(to: stateFile, atomically: true, encoding: .utf8) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc func showWindow() {
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        layoutTrafficLights()
    }
    @objc func openSettings() { showWindow(); js("recolNative.command('settings')") }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func quickSaveFromMenu() { quickSave(fromHotKey: false) }

    // MARK: traffic lights, centred in the 52pt toolbar
    func layoutTrafficLights() {
        guard !win.styleMask.contains(.fullScreen),
              let close = win.standardWindowButton(.closeButton),
              let mini = win.standardWindowButton(.miniaturizeButton),
              let zoom = win.standardWindowButton(.zoomButton),
              let titlebar = close.superview, let container = titlebar.superview else { return }
        var f = container.frame
        f.size.height = toolbarHeight
        f.origin.y = win.frame.height - toolbarHeight
        container.frame = f
        titlebar.frame = container.bounds
        for (i, b) in [close, mini, zoom].enumerated() {
            b.setFrameOrigin(NSPoint(x: 20 + CGFloat(i) * 20, y: (toolbarHeight - b.frame.height) / 2))
        }
    }
    func windowDidResize(_ n: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ n: Notification) { layoutTrafficLights() }
    func windowWillEnterFullScreen(_ n: Notification) { js("recolNative.fullscreen(true)") }
    func windowDidExitFullScreen(_ n: Notification) { layoutTrafficLights(); js("recolNative.fullscreen(false)") }

    // MARK: drag-out — when held clips cross the window edge, start a real macOS drag
    func watch(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            lastMouseDown = e
            if !nativeDragging { armed = nil; armedImage = nil }
        case .leftMouseDragged:
            guard let a = armed, !a.isEmpty, !nativeDragging, e.window === win, let cv = win.contentView else { return }
            let p = cv.convert(e.locationInWindow, from: nil)
            let covered = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != win.windowNumber
            var moved = false
            if armedImmediate, let d = lastMouseDown, d.window === win {
                let dp = d.locationInWindow, ep = e.locationInWindow
                moved = hypot(ep.x - dp.x, ep.y - dp.y) > 4
            }
            if moved || !cv.bounds.insetBy(dx: 2, dy: 2).contains(p) || covered { beginNativeDrag(e, a) }
        case .leftMouseUp:
            if !nativeDragging { armed = nil; armedImage = nil }
        default: break
        }
    }

    // A note becomes a real Markdown file when dropped in Finder; text fields still get its text.
    func noteFile(_ a: [String: Any]) -> URL? {
        let dir = fm.temporaryDirectory.appendingPathComponent("Recol Notes/\(newKey())", isDirectory: true)
        let base = safeName((a["name"] as? String ?? "Note").trimmingCharacters(in: .whitespacesAndNewlines))
        let u = dir.appendingPathComponent(String(base.prefix(60)) + ".md")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try (a["text"] as? String ?? "").write(to: u, atomically: true, encoding: .utf8)
        } catch { return nil }
        return u
    }
    func writer(for a: [String: Any]) -> (NSPasteboardWriting, NSImage)? {
        switch a["kind"] as? String {
        case "note":
            let item = NSPasteboardItem()
            item.setString(a["text"] as? String ?? "", forType: .string)
            if let u = noteFile(a) { item.setString(u.absoluteString, forType: .fileURL) }
            return (item, NSWorkspace.shared.icon(for: UTType(filenameExtension: "md") ?? .plainText))
        case "file":
            guard let p = a["path"] as? String, let u = resolveFile(p), fm.fileExists(atPath: u.path) else { return nil }
            return (u as NSURL, NSWorkspace.shared.icon(forFile: u.path))
        case "url":
            guard let s = a["url"] as? String, let u = URL(string: s) else { return nil }
            let item = NSPasteboardItem()
            item.setString(u.absoluteString, forType: .URL)
            item.setString(u.absoluteString, forType: .string)
            return (item, NSWorkspace.shared.icon(for: .url))
        default:
            return ((a["text"] as? String ?? "") as NSString, NSWorkspace.shared.icon(for: .plainText))
        }
    }

    func beginNativeDrag(_ e: NSEvent, _ payloads: [[String: Any]]) {
        let writers = payloads.compactMap(writer(for:))
        guard !writers.isEmpty else { return }
        nativeDragging = true
        let p = web.convert(e.locationInWindow, from: nil)
        var items: [NSDraggingItem] = []
        for (i, (w, icon)) in writers.enumerated() {
            let img = (i == 0 ? armedImage : nil) ?? icon
            let scale = min(1, (i == 0 ? 220 : 96) / max(img.size.width, img.size.height, 1))
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            let off = CGFloat(i) * 10
            let item = NSDraggingItem(pasteboardWriter: w)
            item.setDraggingFrame(NSRect(x: p.x - size.width / 2 + off, y: p.y - size.height / 2 + off, width: size.width, height: size.height), contents: img)
            items.append(item)
        }
        let session = web.beginDraggingSession(with: items, event: e, source: self)
        session.draggingFormation = .pile
        js("recolNative.dragOut()")
    }

    nonisolated func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        c == .outsideApplication ? [.copy, .generic] : []
    }
    nonisolated func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        let ok = !operation.isEmpty
        Task { @MainActor in
            self.nativeDragging = false; self.armed = nil; self.armedImage = nil; self.pendingActivate = false
            self.js("recolNative.dragEnded(\(ok))")
        }
    }

    func snapshotClip(_ r: [String: Any]?) {
        guard let r, let x = (r["x"] as? NSNumber)?.doubleValue, let y = (r["y"] as? NSNumber)?.doubleValue,
              let w = (r["w"] as? NSNumber)?.doubleValue, let h = (r["h"] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: x, y: y, width: w, height: h)
        web.takeSnapshot(with: cfg) { [weak self] img, _ in
            guard let self, self.armed != nil, let img else { return }
            self.armedImage = NSImage(size: img.size, flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).addClip()
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
                return true
            }
        }
    }

    // MARK: ⌃⌘C quick save
    func quickSave(fromHotKey: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        let isUs = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard fromHotKey, copyFirst, !isUs else { ingestPasteboard(); return }
        guard AXIsProcessTrusted() else {
            if !askedForAccessibility {
                askedForAccessibility = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            ingestPasteboard(note: "Saved your clipboard — allow Accessibility in Recol’s Settings to grab selections")
            return
        }
        // The hotkey fires while ⌃ and ⌘ are still held. A ⌘C sent now would reach the app as ⌃⌘C and do nothing,
        // so wait (briefly) for the keys to come up first.
        whenKeysReleased(tries: 40) { [weak self] in
            guard let self else { return }
            let before = NSPasteboard.general.changeCount
            self.postCommandC()
            self.waitForPasteboard(after: before, tries: 16)
        }
    }

    func whenKeysReleased(tries: Int, _ then: @escaping @MainActor () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.control, .command, .option, .shift])
        if held.isEmpty || tries <= 0 { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            MainActor.assumeIsolated { self?.whenKeysReleased(tries: tries - 1, then) }
        }
    }

    func postCommandC() {
        let src = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            ev?.flags = .maskCommand
            ev?.post(tap: .cghidEventTap)
        }
    }

    func waitForPasteboard(after count: Int, tries: Int) {
        if NSPasteboard.general.changeCount != count { ingestPasteboard(copied: true); return }
        if tries <= 0 {
            // ⌘C didn't change anything — try reading the selected text straight from the app.
            if let text = axSelectedText() { ingest([["text": text]], title: "Saved selection") }
            else { ingestPasteboard(note: "Nothing was selected — saved your clipboard instead") }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.waitForPasteboard(after: count, tries: tries - 1) }
        }
    }

    func axSelectedText() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &val) == .success,
              let str = val as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return str
    }

    func storeMeta(_ dst: URL, key: String, name: String) -> [String: Any] {
        let size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.intValue ?? 0
        let mime = UTType(filenameExtension: dst.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return ["key": key, "fileName": name, "name": name, "mime": mime, "size": size]
    }
    func storeCopy(of src: URL) -> [String: Any]? {
        let key = newKey(), name = safeName(src.lastPathComponent)
        let dst = filesDir.appendingPathComponent(key).appendingPathComponent(name)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
        } catch { return nil }
        return storeMeta(dst, key: key, name: name)
    }
    func storeLink(to src: URL, isDir: Bool) -> [String: Any]? {
        guard let bm = try? src.bookmarkData() else { return nil }
        let key = newKey(), name = safeName(src.lastPathComponent)
        refs[key] = bm.base64EncodedString(); saveRefs()
        var m = storeMeta(src, key: key, name: name)
        m["ref"] = true
        m["path"] = src.path
        if isDir { m["mime"] = "inode/directory"; m["size"] = 0 }
        return m
    }
    /// Copies the file into Recol, or links it if it's big (per Settings) or a folder.
    func store(_ u: URL) -> [String: Any]? {
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &dir) else { return nil }
        if dir.boolValue { return storeLink(to: u, isDir: true) }
        let size = (try? fm.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue ?? 0
        let link = linkLarge == 0 || (linkLarge > 0 && size > linkLarge * 1_000_000)
        return link ? storeLink(to: u, isDir: false) : storeCopy(of: u)
    }
    func ingestFiles(_ urls: [URL], at p: NSPoint?) {
        let items = urls.compactMap(store).map { ["file": $0] as [String: Any] }
        guard !items.isEmpty, let json = jsonString(items) else { return }
        let at = p.map { ", at: {x: \($0.x), y: \($0.y)}" } ?? ""
        js("recolNative.ingest(\(json), {current: true\(at)})")
    }
    func jsonString(_ o: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: o)).flatMap { String(data: $0, encoding: .utf8) }
    }
    func storeData(_ data: Data, name: String) -> [String: Any]? {
        let key = newKey(), name = safeName(name)
        let dst = filesDir.appendingPathComponent(key).appendingPathComponent(name)
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dst)
        } catch { return nil }
        return storeMeta(dst, key: key, name: name)
    }

    func readPasteboard(_ pb: NSPasteboard = .general) -> [[String: Any]] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.compactMap { u -> [String: Any]? in store(u).map { ["file": $0] } }
            if !files.isEmpty { return files }
        }
        let stamp = { () -> String in let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"; return f.string(from: Date()) }()
        if let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
           let m = storeData(png, name: "Clipping \(stamp).png") {
            return [["file": m]]
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [["text": s]]
        }
        return []
    }

    func ingestPasteboard(copied: Bool = false, note: String? = nil) {
        let items = readPasteboard()
        guard !items.isEmpty else { hud("Nothing to save", detail: note ?? "Copy or select something first"); return }
        let what = items.count == 1 ? (items[0]["text"] != nil ? "text" : "1 clip") : "\(items.count) clips"
        ingest(items, title: copied ? "Copied & saved \(what)" : "Saved \(what)", note: note)
    }
    func ingest(_ items: [[String: Any]], title: String, note: String? = nil) {
        guard let json = jsonString(items) else { return }
        web.evaluateJavaScript("recolNative.ingest(\(json))") { [weak self] r, _ in
            self?.hud(title, detail: note ?? "to \(r as? String ?? "Recol")")
        }
    }

    // Small HUD near the top of the screen — feedback without opening the window.
    func hud(_ title: String, detail: String) {
        hudPanel?.orderOut(nil)
        let w: CGFloat = detail.count > 40 ? 420 : 300, h: CGFloat = 64
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 16; fx.layer?.masksToBounds = true
        let icon = NSImageView(frame: NSRect(x: 14, y: 12, width: 40, height: 40))
        icon.image = NSApp.applicationIconImage
        let t = NSTextField(labelWithString: title); t.font = .systemFont(ofSize: 15, weight: .semibold)
        t.frame = NSRect(x: 64, y: 32, width: w - 76, height: 20)
        let d = NSTextField(labelWithString: detail); d.font = .systemFont(ofSize: 13); d.textColor = .secondaryLabelColor
        d.frame = NSRect(x: 64, y: 13, width: w - 76, height: 18); d.lineBreakMode = .byTruncatingTail
        [icon, t, d].forEach { fx.addSubview($0) }
        panel.contentView = fx

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: vf.midX - w / 2, y: vf.maxY - h - 18))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hudPanel = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak panel] in
            MainActor.assumeIsolated {
                guard let panel else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
            }
        }
    }

    // MARK: settings from the page
    func applySettings(_ s: [String: Any]) -> [String: Any] {
        if let l = s["linkLarge"] as? NSNumber { linkLarge = l.intValue }
        switch s["appearance"] as? String ?? s["theme"] as? String {
        case "light": win.appearance = NSAppearance(named: .aqua)
        case "dark": win.appearance = NSAppearance(named: .darkAqua)
        default: win.appearance = nil
        }
        let hotkey = s["hotkey"] as? Bool ?? true
        let viaServices = (s["quickMode"] as? String ?? "services") == "services"
        let sc = Shortcut(s["shortcut"] as? String ?? "") ?? Shortcut()
        // Services mode: macOS delivers the selection itself. Press mode: Recol's own hotkey sends ⌘C (needs Accessibility).
        setServiceShortcut(hotkey && viaServices, sc)
        setGlobalHotKey(hotkey && !viaServices, sc)
        for i in quickSaveItems { i.keyEquivalent = hotkey ? String(sc.key) : ""; i.keyEquivalentModifierMask = sc.menuMods }
        copyFirst = !viaServices
        historyOn = s["copyHistory"] as? Bool ?? true
        if !historyOn && !history.isEmpty { clearHistory() }
        setMenuBar(s["menuBar"] as? Bool ?? true)
        let login = setOpenAtLogin(s["openAtLogin"] as? Bool ?? false)
        return ["accessibility": AXIsProcessTrusted(), "loginItem": login, "serviceShortcut": serviceShortcutActive(sc), "mcpPath": mcpScript.path]
    }

    func setOpenAtLogin(_ on: Bool) -> String {
        guard #available(macOS 13.0, *) else { return "unsupported" }
        let svc = SMAppService.mainApp
        do {
            if on && svc.status != .enabled { try svc.register() }
            if !on && svc.status == .enabled { try svc.unregister() }
        } catch { return "error" }
        switch svc.status {
        case .enabled: return "on"
        case .requiresApproval: return "needs approval"
        default: return "off"
        }
    }

    func setMenuBar(_ on: Bool) {
        if on, statusItem == nil {
            let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            s.button?.image = menuBarIcon()
            s.button?.toolTip = "Recol"
            let m = NSMenu()
            func add(_ t: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) {
                let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = self; m.addItem(i)
            }
            add("Open Recol", #selector(showWindow))
            add("Save Clipboard to Recol", #selector(quickSaveFromMenu), "c", [.control, .command]); quickSaveItems.append(m.items.last!)
            m.addItem(.separator())
            add("Settings…", #selector(openSettings), ",")
            m.addItem(.separator())
            add("Quit Recol", #selector(quitApp), "q")
            s.menu = m
            statusItem = s
        } else if !on, let s = statusItem {
            NSStatusBar.system.removeStatusItem(s); statusItem = nil
        }
    }

    // The R mark as a template image for the menu bar.
    func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            let k: CGFloat = 0.18
            func shape(_ r: NSRect, _ rad: CGFloat, rot: CGFloat = 0, about c: NSPoint = .zero) {
                let p = NSBezierPath(roundedRect: NSRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k),
                                     xRadius: rad * k, yRadius: rad * k)
                if rot != 0 {
                    var m = AffineTransform(translationByX: c.x * k, byY: c.y * k)
                    m.rotate(byDegrees: rot); m.translate(x: -c.x * k, y: -c.y * k)
                    p.transform(using: m)
                }
                p.lineWidth = 1.4; p.lineJoinStyle = .round
                ctx.compositingOperation = .clear; p.fill()
                ctx.compositingOperation = .sourceOver; NSColor.black.setStroke(); p.stroke()
            }
            shape(NSRect(x: 44, y: 38, width: 17, height: 54), 8.5, rot: -30, about: NSPoint(x: 52.5, y: 45))
            shape(NSRect(x: 8, y: 28, width: 24, height: 64), 12)
            shape(NSRect(x: 8, y: 8, width: 84, height: 34), 14)
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: messages from the page
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage,
                               replyHandler reply: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let b = m.body as? [String: Any], let op = b["op"] as? String else { reply(nil, "bad message"); return }
        let payload = b["payload"] as? [String: Any] ?? [:]
        let payloads = b["payloads"] as? [[String: Any]] ?? (payload.isEmpty ? [] : [payload])
        switch op {
        case "load":
            reply(try? String(contentsOf: stateFile, encoding: .utf8), nil)
        case "save":
            if let d = b["data"] as? String { try? d.write(to: stateFile, atomically: true, encoding: .utf8) }
            reply(true, nil)
        case "putFile":
            guard let key = b["key"] as? String, let name = b["name"] as? String, let d = b["data"] as? String,
                  let data = Data(base64Encoded: d), let u = clipFile("\(key)/\(name)") else { reply(false, nil); return }
            do {
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u); reply(true, nil)
            } catch { reply(false, nil) }
        case "deleteFile":
            // Linked clips only forget their bookmark — the original file is never touched.
            if let key = b["key"] as? String, validKey(key) {
                if refs.removeValue(forKey: key) != nil { saveRefs() }
                else { try? fm.removeItem(at: filesDir.appendingPathComponent(key)) }
                try? fm.removeItem(at: thumbsDir.appendingPathComponent(key + ".png"))
            }
            reply(true, nil)
        case "pasteFiles":
            let pb = NSPasteboard.general
            let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            reply(urls.compactMap(store).map { ["file": $0] }, nil)
        case "storage":
            var bytes = 0
            if let e = fm.enumerator(at: filesDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let u as URL in e { bytes += (try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0 }
            }
            reply(["bytes": bytes, "linked": refs.count], nil)
        case "gc":
            // remove stored files no clip refers to any more (e.g. left over from a quit during the Undo window)
            let keep = Set(b["keys"] as? [String] ?? [])
            for k in (try? fm.contentsOfDirectory(atPath: filesDir.path)) ?? [] where validKey(k) && !keep.contains(k) {
                try? fm.removeItem(at: filesDir.appendingPathComponent(k))
            }
            let staleLinks = refs.keys.filter { !keep.contains($0) }
            if !staleLinks.isEmpty { staleLinks.forEach { refs.removeValue(forKey: $0) }; saveRefs() }
            for f in (try? fm.contentsOfDirectory(atPath: thumbsDir.path)) ?? [] where !keep.contains((f as NSString).deletingPathExtension) {
                try? fm.removeItem(at: thumbsDir.appendingPathComponent(f))
            }
            reply(true, nil)
        case "arm":
            armed = payloads; armedImage = nil
            armedImmediate = b["immediate"] as? Bool ?? false
            snapshotClip(b["rect"] as? [String: Any])
            reply(true, nil)
        case "disarm":
            if !nativeDragging { armed = nil; armedImage = nil }
            reply(true, nil)
        case "copy":
            copyToPasteboard(payloads); reply(true, nil)
        case "open":
            if let u = target(payload) { NSWorkspace.shared.open(u) }
            reply(true, nil)
        case "reveal":
            if let u = target(payload), u.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            reply(true, nil)
        case "saveFile":
            guard let src = target(payload), src.isFileURL else { reply(false, nil); return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = payload["name"] as? String ?? src.lastPathComponent
            panel.beginSheetModal(for: win) { r in
                guard r == .OK, let dst = panel.url else { reply(false, nil); return }
                try? fm.removeItem(at: dst)
                reply((try? fm.copyItem(at: src, to: dst)) != nil, nil)
            }
        case "saveData":
            let panel = NSSavePanel(); panel.nameFieldStringValue = b["name"] as? String ?? "Clipboard.recol"
            let text = b["text"] as? String ?? ""
            panel.beginSheetModal(for: win) { r in
                guard r == .OK, let dst = panel.url else { reply(false, nil); return }
                reply((try? text.write(to: dst, atomically: true, encoding: .utf8)) != nil, nil)
            }
        case "preview":
            showPreview(payloads.compactMap(target).filter { $0.isFileURL })
            reply(true, nil)
        case "exportPDF":
            exportPDF(board: b["board"] as? String ?? "", name: b["name"] as? String ?? "Recol"); reply(true, nil)
        case "exportReady":
            reply(true, nil)
            if m.webView === exportWeb {
                exportReady(w: CGFloat((b["w"] as? NSNumber)?.doubleValue ?? 800), h: CGFloat((b["h"] as? NSNumber)?.doubleValue ?? 600))
            }
        case "closePreview":
            if QLPreviewPanel.sharedPreviewPanelExists(), let p = QLPreviewPanel.shared(), p.isVisible { p.orderOut(nil) }
            reply(true, nil)
        case "plugins":
            reply(listPlugins(), nil)
        case "history":
            reply(historyList(), nil)
        case "historyAdd":
            reply(historyItems(b["id"] as? String ?? ""), nil)
        case "historyClear":
            clearHistory(); reply(true, nil)
        case "openPlugins":
            try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(pluginsDir); reply(true, nil)
        case "openDoc":
            let name = (b["name"] as? String ?? "").replacingOccurrences(of: "/", with: "")
            let u = Bundle.main.resourceURL!.appendingPathComponent("docs").appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) }
            reply(true, nil)
        case "log":
            print("[page]", b["message"] ?? ""); fflush(stdout); reply(true, nil)
        case "settings":
            reply(applySettings(b["settings"] as? [String: Any] ?? [:]), nil)
        case "requestAccessibility":
            let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            if !trusted, let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(u)
            }
            reply(trusted, nil)
        case "dragWindow":
            if let e = lastMouseDown { win.performDrag(with: e) }
            reply(true, nil)
        case "zoom":
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { win.miniaturize(nil) } else if action != "None" { win.zoom(nil) }
            reply(true, nil)
        default:
            reply(nil, "unknown op \(op)")
        }
    }

    func target(_ p: [String: Any]) -> URL? {
        switch p["kind"] as? String {
        case "file": return (p["path"] as? String).flatMap(resolveFile)
        case "url": return (p["url"] as? String).flatMap(URL.init(string:))
        default: return nil
        }
    }

    func copyToPasteboard(_ payloads: [[String: Any]]) {
        let items: [NSPasteboardItem] = payloads.compactMap { p in
            let item = NSPasteboardItem()
            switch p["kind"] as? String {
            case "file":
                guard let path = p["path"] as? String, let u = resolveFile(path) else { return nil }
                item.setString(u.absoluteString, forType: .fileURL)
                if payloads.count == 1, (p["mime"] as? String ?? "").hasPrefix("image/"),
                   let img = NSImage(contentsOf: u), let tiff = img.tiffRepresentation {
                    item.setData(tiff, forType: .tiff)
                }
            case "url":
                let s = p["url"] as? String ?? ""
                item.setString(s, forType: .URL); item.setString(s, forType: .string)
            default:
                item.setString(p["text"] as? String ?? "", forType: .string)
            }
            return item
        }
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
        ownChange = pb.changeCount
    }

    // MARK: web view plumbing
    func webView(_ w: WKWebView, runOpenPanelWith params: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = params.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: win) { r in completionHandler(r == .OK ? panel.urls : nil) }
    }
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction,
                 windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { NSWorkspace.shared.open(u) }
        return nil
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, a.targetFrame?.isMainFrame == true else { decisionHandler(.allow); return }
        if ["recol", "about", "blob", "data"].contains(u.scheme ?? "") { decisionHandler(.allow); return }
        NSWorkspace.shared.open(u)
        decisionHandler(.cancel)
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { pageReady = false; w.reload() }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        pageReady = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self.processInbox() } }
    }

    func js(_ s: String) { web?.evaluateJavaScript(s, completionHandler: nil) }
    @objc func jsCommand(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        if !win.isVisible { showWindow() }
        js("recolNative.command('\(n)')")
    }

    // MARK: menus
    func quickSaveMenuItem(_ i: NSMenuItem) -> NSMenuItem { quickSaveItems.append(i); return i }
    func buildMenu() {
        let main = NSMenu()
        @discardableResult
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let mi = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }; mi.submenu = m; main.addItem(mi); return m
        }
        func item(_ t: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; return i
        }
        func mine(_ t: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = item(t, sel, key, mods); i.target = self; return i
        }
        func cmd(_ t: String, _ name: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = mine(t, #selector(jsCommand(_:)), key, mods); i.representedObject = name; return i
        }
        menu("Recol", [
            item("About Recol", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
            cmd("Settings…", "settings", ","), .separator(),
            item("Hide Recol", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))), .separator(),
            item("Quit Recol", #selector(NSApplication.terminate(_:)), "q")
        ])
        menu("File", [
            cmd("New Clipboard", "newBoard", "n"), cmd("New Mood Board", "newMood", "n", [.command, .shift]),
            cmd("New Note", "newNote", "n", [.command, .control]), cmd("Add Files…", "addFiles", "o"),
            quickSaveMenuItem(mine("Save Clipboard to Recol", #selector(quickSaveFromMenu), "c", [.control, .command])), .separator(),
            cmd("Import Clipboard…", "import", "i", [.command, .shift]),
            cmd("Share Clipboard…", "share", "e", [.command, .shift]), cmd("Export as PDF…", "pdf", "p"), .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w")
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"), cmd("Select All Clips", "selectAll", "a"), .separator(),
            cmd("Make Sticky / Not Sticky", "toggleSticky", "j"), .separator(),
            cmd("Copy Clipboard as Markdown", "copyMarkdown", "c", [.command, .option]), .separator(),
            cmd("Group", "group", "g"), cmd("Ungroup", "ungroup", "g", [.command, .shift]), cmd("Rename Clip…", "rename", "r", [.command, .option]), .separator(),
            cmd("Save Snapshot", "snapshot", "s", [.command, .option])
        ])
        menu("View", [
            cmd("Free", "view-free", "1"), cmd("Grid", "view-grid", "2"), cmd("List", "view-list", "3"), .separator(),
            cmd("Organize…", "organize", "k"), cmd("Line Up Clips", "lineup", "l"), .separator(),
            cmd("Home", "home", "h", [.command, .shift]), .separator(),
            cmd("Quick Look", "look", "y"), cmd("Design Mode", "design", "e"), .separator(),
            cmd("Zoom In", "zoomIn", "="), cmd("Zoom Out", "zoomOut", "-"), cmd("Actual Size", "zoomReset", "0"),
            cmd("Zoom to Fit", "zoomFit", "1", [.command, .shift]), .separator(),
            cmd("Show Grid (Dots / Lines / Off)", "grid", "'"), cmd("Snap to Grid", "snap", "'", [.command, .shift]), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        ])
        let w = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))), .separator(),
            mine("Recol", #selector(showWindow))
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = w
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
