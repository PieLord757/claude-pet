// ClaudePet: a floating pixel pet that watches your Claude Code sessions.
// Reads ~/.claude/sessions/<pid>.json (written by every running Claude Code
// session, including the desktop app's Code tab) and shows which ones are
// working, waiting on you, or just finished.

import AppKit
import SwiftUI

// MARK: - Session model

enum SessionState: String {
    case busy, waiting, idle
}

struct SessionInfo: Identifiable, Equatable {
    let id: String          // sessionId
    let pid: Int32
    let name: String
    let state: SessionState
    let waitingFor: String?
    let statusUpdatedAt: Date
    let hostSessionId: String?
}

struct RawSession: Decodable {
    let pid: Int32
    let sessionId: String?
    let cwd: String?
    let name: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Double?
    let updatedAt: Double?
    let hostSessionId: String?
    let kind: String?
}

final class SessionStore: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    /// sessionId -> when it finished (busy -> idle). Cleared on click or after a while.
    @Published var finished: [String: Date] = [:]

    // CLAUDE_PET_SESSIONS_DIR points the pet at another folder (used for testing).
    private let dir = ProcessInfo.processInfo.environment["CLAUDE_PET_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    private var lastGood: [String: RawSession] = [:]       // file name -> last decodable contents
    private var previousState: [String: SessionState] = [:]
    private var idleSince: [String: Date] = [:]           // debounce busy -> idle flicker
    private var timer: Timer?

    static let doneDebounce: TimeInterval = 3
    static let doneExpiry: TimeInterval = 30 * 60

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
    }

    func dismissFinished(_ id: String) { finished[id] = nil }
    func dismissAllFinished() { finished.removeAll() }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func poll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var seenFiles = Set<String>()
        var result: [SessionInfo] = []
        let now = Date()

        for url in files where url.pathExtension == "json" {
            let key = url.lastPathComponent
            seenFiles.insert(key)
            // A file caught mid-write fails to decode: keep its last good value.
            if let data = try? Data(contentsOf: url),
               let raw = try? JSONDecoder().decode(RawSession.self, from: data) {
                lastGood[key] = raw
            }
            guard let raw = lastGood[key],
                  let sid = raw.sessionId,
                  let statusStr = raw.status,
                  let state = SessionState(rawValue: statusStr),
                  isAlive(raw.pid) else { continue }

            let name = (raw.name?.isEmpty == false ? raw.name! : nil)
                ?? raw.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Session \(raw.pid)"
            let ts = (raw.statusUpdatedAt ?? raw.updatedAt ?? 0) / 1000
            result.append(SessionInfo(id: sid, pid: raw.pid, name: name, state: state,
                                      waitingFor: raw.waitingFor,
                                      statusUpdatedAt: Date(timeIntervalSince1970: ts),
                                      hostSessionId: raw.hostSessionId))
        }
        lastGood = lastGood.filter { seenFiles.contains($0.key) }

        // Track busy -> idle transitions as "finished", after a short debounce.
        var newFinished = finished
        for s in result {
            let prev = previousState[s.id]
            if s.state == .idle {
                if prev == .busy || prev == .waiting { idleSince[s.id] = now }
                if let since = idleSince[s.id], now.timeIntervalSince(since) >= Self.doneDebounce {
                    newFinished[s.id] = since
                    idleSince[s.id] = nil
                }
            } else {
                idleSince[s.id] = nil
                newFinished[s.id] = nil      // started working again
            }
            // Only move previousState forward once a pending idle has settled.
            if !(s.state == .idle && idleSince[s.id] != nil) { previousState[s.id] = s.state }
            else { previousState[s.id] = .idle }
        }
        let liveIds = Set(result.map(\.id))
        newFinished = newFinished.filter { liveIds.contains($0.key) && now.timeIntervalSince($0.value) < Self.doneExpiry }

        result.sort { a, b in
            func rank(_ s: SessionInfo) -> Int {
                switch s.state { case .waiting: return 0; case .busy: return 1; case .idle: return 2 }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.statusUpdatedAt > b.statusUpdatedAt
        }
        if result != sessions { sessions = result }
        if newFinished != finished { finished = newFinished }
    }

    var waiting: [SessionInfo] { sessions.filter { $0.state == .waiting } }
    var busy: [SessionInfo] { sessions.filter { $0.state == .busy } }
    var done: [SessionInfo] {
        sessions.filter { $0.state == .idle && finished[$0.id] != nil }
            .sorted { (finished[$0.id] ?? .distantPast) > (finished[$1.id] ?? .distantPast) }
    }
    var idleCount: Int { sessions.filter { $0.state == .idle && finished[$0.id] == nil }.count }
}

// MARK: - Pixel pet

enum PetMood { case sleepy, idle, working, waiting, cheering }

/// An original 16x16 critter: an orange blob with wild white scientist hair.
struct PixelPet {
    static let palette: [Character: Color] = [
        "K": Color(red: 0.16, green: 0.13, blue: 0.12),   // outline
        "O": Color(red: 0.85, green: 0.47, blue: 0.34),   // body
        "o": Color(red: 0.70, green: 0.35, blue: 0.24),   // body shade
        "W": Color(red: 0.80, green: 0.91, blue: 0.97),   // hair
        "w": Color(red: 0.56, green: 0.76, blue: 0.87),   // hair shade
        "E": .white,                                      // eye
        "P": Color(red: 0.10, green: 0.10, blue: 0.12),   // pupil
        "G": Color(red: 0.43, green: 0.76, blue: 0.89),   // goggle lens
        "g": Color(red: 0.25, green: 0.50, blue: 0.62),   // goggle rim
        "R": Color(red: 0.95, green: 0.62, blue: 0.54),   // cheek
        "M": Color(red: 0.35, green: 0.16, blue: 0.12),   // mouth
        "Y": Color(red: 1.00, green: 0.84, blue: 0.30),   // spark
    ]

    static let hair = [
        "..K...K...K.....",
        ".KWK.KWK.KWK.K..",
        "KWWWKWWWKWWWKWK.",
        ".KWwWWWwWWWwWWK.",
    ]
    static let top =    "..KKKKKKKKKKKK.."
    static let blank =  ".KOOOOOOOOOOOOK."
    static let bottom = [
        ".KoOOOOOOOOOOoK.",
        "..KooooooooooK..",
        "...KoK....KoK...",
        "...KKK....KKK...",
    ]

    static func eyes(_ mood: PetMood, blink: Bool, look: Int) -> [String] {
        if blink || mood == .sleepy {
            return [blank, ".KOOOOOOOOOOOOK.", ".KOKKKOOOOKKKOK.", blank]
        }
        switch mood {
        case .working:
            return [".KgggggOOgggggK.", ".KgGGGgOOgGGGgK.", ".KgGWGgOOgGWGgK.", ".KgggggOOgggggK."]
        case .cheering:
            return [blank, ".KOOKOOOOOOKOOK.", ".KOKOKOOOOKOKOK.", blank]
        default:
            let p = look == 0 ? ".KOEPEOOOOEPEOK." : (look < 0 ? ".KOPEEOOOOPEEOK." : ".KOEEPOOOOEEPOK.")
            return [blank, ".KOEEEOOOOEEEOK.", p, ".KOEEEOOOOEEEOK."]
        }
    }

    static func mouth(_ mood: PetMood, frame: Int) -> [String] {
        switch mood {
        case .cheering: return [".KORROMMMMORROK.", ".KOOOOOMMOOOOOK."]
        case .waiting:  return [".KORROOMMOORROK.", ".KOOOOOMMOOOOOK."]
        case .working:  return [frame % 2 == 0 ? ".KORROOMOOORROK." : ".KORROOOMOORROK.", blank]
        case .sleepy:   return [".KORROOMMOORROK.", blank]
        case .idle:     return [".KORROOMMOORROK.", blank]
        }
    }

    static func grid(_ mood: PetMood, frame: Int, blink: Bool, look: Int) -> [String] {
        var rows = hair + [top] + eyes(mood, blink: blink, look: look) + mouth(mood, frame: frame) + [blank] + bottom
        if mood == .cheering && frame % 2 == 0 {
            // arms up
            rows[8] = "K" + rows[8].dropFirst().dropLast() + "K"
            rows[9] = "O" + rows[9].dropFirst().dropLast() + "O"
        }
        return rows
    }
}

struct PetCanvas: View {
    let mood: PetMood
    let frame: Int
    let pixel: CGFloat = 6

    var body: some View {
        let blink = mood != .working && frame % 17 == 0
        let look = mood == .idle ? [0, 0, 0, -1, 0, 0, 1, 0][(frame / 6) % 8] : 0
        let rows = PixelPet.grid(mood, frame: frame, blink: blink, look: look)
        let bob: CGFloat = {
            switch mood {
            case .working: return frame % 2 == 0 ? 0 : -pixel
            case .cheering: return frame % 2 == 0 ? -pixel * 2 : 0
            case .waiting: return frame % 4 < 2 ? 0 : -pixel
            case .idle: return (frame / 3) % 2 == 0 ? 0 : -pixel / 2
            case .sleepy: return 0
            }
        }()
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let c = PixelPet.palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel + pixel * 3 + bob,
                                         width: pixel, height: pixel)), with: .color(c))
                }
            }
            // Sparks while working
            if mood == .working {
                let spots = [(14, 1), (1, 3), (15, 6), (0, 9)]
                for (i, s) in spots.enumerated() where (frame + i) % 3 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(s.0) * pixel, y: CGFloat(s.1) * pixel,
                                         width: pixel, height: pixel)),
                             with: .color(PixelPet.palette["Y"]!))
                }
            }
        }
        .frame(width: 16 * pixel, height: 20 * pixel)
        .overlay(alignment: .topTrailing) {
            if mood == .sleepy {
                Text(frame % 6 < 3 ? "z" : "Z")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(x: 6, y: CGFloat(-(frame % 6)))
            } else if mood == .waiting {
                Text("!")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(Color.orange)
                    .offset(x: 6, y: frame % 2 == 0 ? -2 : 0)
            }
        }
    }
}

// MARK: - Views

struct PetView: View {
    @ObservedObject var store: SessionStore
    @AppStorage("expanded") private var expanded = true
    @State private var frame = 0
    @State private var cheerUntil: Date = .distantPast
    @State private var lastDoneCount = 0
    let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var mood: PetMood {
        if !store.waiting.isEmpty { return .waiting }
        if Date() < cheerUntil { return .cheering }
        if !store.busy.isEmpty { return .working }
        if !store.done.isEmpty { return .idle }
        return .sleepy
    }

    var badge: (Int, Color)? {
        if !store.waiting.isEmpty { return (store.waiting.count, .orange) }
        if !store.done.isEmpty { return (store.done.count, .green) }
        if !store.busy.isEmpty { return (store.busy.count, .blue) }
        return nil
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            PetCanvas(mood: mood, frame: frame)
                .overlay(alignment: .topLeading) {
                    if let (n, c) = badge {
                        Text("\(n)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(c))
                            .offset(x: -6, y: 8)
                    }
                }
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .help(expanded ? "Click to hide sessions · drag to move" : "Click to show sessions · drag to move")

            if expanded {
                SessionCard(store: store) { withAnimation(.snappy) { expanded = false } }
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            } else {
                SummaryPill(store: store) { withAnimation(.snappy) { expanded = true } }
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 280, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .contextMenu {
            Button(expanded ? "Hide Sessions" : "Show Sessions") { withAnimation(.snappy) { expanded.toggle() } }
            Button("Clear Finished") { store.dismissAllFinished() }
            Button("Reset Position") { (NSApp.delegate as? AppDelegate)?.resetPosition() }
            Divider()
            Button("Close Pet") { NSApp.terminate(nil) }
        }
        .onReceive(tick) { _ in
            frame &+= 1
            let n = store.done.count
            if n > lastDoneCount { cheerUntil = Date().addingTimeInterval(3) }
            lastDoneCount = n
        }
    }
}

struct WindowDragGesture: Gesture {
    var body: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in
                guard let w = NSApp.windows.first(where: { $0 is PetPanel }),
                      let event = NSApp.currentEvent else { return }
                w.setFrameOrigin(NSPoint(x: w.frame.origin.x + event.deltaX,
                                         y: w.frame.origin.y - event.deltaY))
            }
            .onEnded { _ in
                if let w = NSApp.windows.first(where: { $0 is PetPanel }) {
                    UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "origin")
                }
            }
    }
}

/// Shown under the pet while the list is collapsed: counts at a glance.
struct SummaryPill: View {
    @ObservedObject var store: SessionStore
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 8) {
                if !store.waiting.isEmpty { count(store.waiting.count, "need you", .orange) }
                if !store.busy.isEmpty { count(store.busy.count, "working", .blue) }
                if !store.done.isEmpty { count(store.done.count, "done", .green) }
                if store.waiting.isEmpty && store.busy.isEmpty && store.done.isEmpty {
                    Text("all quiet").foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .help("Show sessions")
    }

    func count(_ n: Int, _ label: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(n) \(label)")
        }
    }
}

/// A titled, collapsible group of rows. Collapsed state is remembered per group.
struct SessionGroup<Content: View>: View {
    let title: String
    let count: Int
    let color: Color
    @AppStorage private var collapsed: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, count: Int, color: Color, key: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.count = count; self.color = color; self.content = content
        _collapsed = AppStorage(wrappedValue: false, "collapsed." + key)
    }

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5)
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed { content() }
            }
        }
    }
}

struct SessionCard: View {
    @ObservedObject var store: SessionStore
    let collapse: () -> Void
    @AppStorage("showIdle") private var showIdle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.waiting.isEmpty && store.busy.isEmpty && store.done.isEmpty {
                Text("All quiet. Nothing running.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            SessionGroup("Needs you", count: store.waiting.count, color: .orange, key: "waiting") {
                ForEach(store.waiting) { s in
                    SessionRow(session: s, dot: .orange, detail: "needs you" + (s.waitingFor.map { " · \($0)" } ?? "")) {
                        openURL("claude://code/needs-input?source=claude_pet")
                    }
                }
            }
            SessionGroup("Working", count: store.busy.count, color: .blue, key: "busy") {
                ForEach(store.busy) { s in
                    SessionRow(session: s, dot: .blue, detail: "working · \(ago(s.statusUpdatedAt))", pulsing: true) {
                        activateClaude()
                    }
                }
            }
            SessionGroup("Done", count: store.done.count, color: .green, key: "done") {
                ForEach(store.done) { s in
                    SessionRow(session: s, dot: .green, detail: "done · \(ago(store.finished[s.id] ?? s.statusUpdatedAt)) ago") {
                        store.dismissFinished(s.id)
                        activateClaude()
                    }
                }
            }
            if showIdle {
                SessionGroup("Idle", count: store.idleCount, color: .gray, key: "idle") {
                    ForEach(store.sessions.filter { $0.state == .idle && store.finished[$0.id] == nil }) { s in
                        SessionRow(session: s, dot: .gray.opacity(0.5), detail: "idle") { activateClaude() }
                    }
                }
            }

            Divider().padding(.vertical, 3)

            HStack(spacing: 6) {
                Button { openURL("claude://code/new?source=claude_pet") } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                Button { activateClaude() } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                Spacer()
                Button { showIdle.toggle() } label: {
                    Text(showIdle ? "hide idle" : "+\(store.idleCount) idle")
                }
                .help("Show or hide sessions that are open but not doing anything")
                Button(action: collapse) { Image(systemName: "chevron.up") }
                    .help("Collapse")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.bottom, 2)
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    func ago(_ d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let dot: Color
    let detail: String
    var pulsing = false
    let action: () -> Void
    @State private var hover = false
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8)
                    .opacity(pulsing && pulse ? 0.35 : 1)
                    .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear { pulse = true }
    }
}

func openURL(_ s: String) {
    if let u = URL(string: s) { NSWorkspace.shared.open(u) }
}

func activateClaude() {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
        app.activate()
    } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

// MARK: - Window

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: PetPanel!
    let store = SessionStore()

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        store.start()

        let size = NSSize(width: 290, height: 520)
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let host = NSHostingView(rootView: PetView(store: store))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        if let s = UserDefaults.standard.string(forKey: "origin") {
            panel.setFrameOrigin(NSPointFromString(s))
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - size.width - 20, y: v.maxY - size.height - 10))
        }


        panel.orderFrontRegardless()
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "origin")
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 20, y: v.maxY - panel.frame.height - 10))
        }
    }
}

@main
enum ClaudePetMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
