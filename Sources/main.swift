// ClaudePet: a floating pixel pet that watches your Claude Code sessions.
// Reads ~/.claude/sessions/<pid>.json (written by every running Claude Code
// session, including the desktop app's Code tab) and shows which ones are
// working, waiting on you, or just finished.

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session model

enum SessionState: String {
    case busy, waiting, idle
}

struct SessionInfo: Identifiable, Equatable {
    let id: String          // sessionId (or the desktop chat id for a chat with no process)
    let pid: Int32          // 0 for a desktop chat whose process has stopped
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

/// What the pet needs from one of the desktop app's per-chat files.
struct DesktopChat: Equatable {
    let hostId: String
    let title: String?
    let lastTurnEdgeAt: Double?     // ms
    let lastActivityAt: Double?     // ms
    let lastFocusedAt: Double?      // ms
    let isArchived: Bool
}

/// Reads the desktop app's per-chat files (<account>/<org>/local_<id>.json),
/// re-parsing a file only when it changes.
final class DesktopChats {
    let dir: URL
    private var cache: [String: (modified: Date, chat: DesktopChat?)] = [:]
    init(dir: URL) { self.dir = dir }

    func load() -> [String: DesktopChat] {
        let fm = FileManager.default
        var out: [String: DesktopChat] = [:]
        var seen = Set<String>()
        for a in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            for b in (try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: b, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                where f.pathExtension == "json" && f.lastPathComponent.hasPrefix("local_") {
                    let hostId = f.deletingPathExtension().lastPathComponent
                    seen.insert(f.path)
                    guard let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    else { continue }
                    if let c = cache[f.path], c.modified == modified {
                        if let chat = c.chat { out[hostId] = chat }
                        continue
                    }
                    let json = (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    // A file caught mid-write doesn't parse: keep the last good copy and retry next time.
                    guard let json else {
                        if let chat = cache[f.path]?.chat { out[hostId] = chat }
                        continue
                    }
                    let chat = DesktopChat(hostId: hostId,
                                           title: json["title"] as? String,
                                           lastTurnEdgeAt: (json["lastTurnEdgeAt"] as? NSNumber)?.doubleValue,
                                           lastActivityAt: (json["lastActivityAt"] as? NSNumber)?.doubleValue,
                                           lastFocusedAt: (json["lastFocusedAt"] as? NSNumber)?.doubleValue,
                                           isArchived: (json["isArchived"] as? Bool) ?? false)
                    cache[f.path] = (modified, chat)
                    out[hostId] = chat
                }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return out
    }
}

/// Reads the newest write of one key from a LevelDB write-ahead log (`*.log`).
/// The desktop app's local storage is LevelDB; recent writes sit in the log uncompressed.
enum LevelDBLog {
    static let blockSize = 32768

    /// The last value put under a key ending in `keySuffix`, or nil if the log never wrote it.
    /// `.some(nil)` means the key's latest entry is a delete.
    static func lastValue(in bytes: [UInt8], keySuffix: [UInt8]) -> [UInt8]?? {
        var result: [UInt8]?? = nil
        for record in records(bytes) {
            guard let entries = batchEntries(record) else { continue }
            for (key, value) in entries where key.count >= keySuffix.count && Array(key.suffix(keySuffix.count)) == keySuffix {
                result = .some(value)
            }
        }
        return result
    }

    /// Reassembles the log's physical fragments (FULL/FIRST/MIDDLE/LAST) into records.
    static func records(_ b: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var pending: [UInt8] = []
        var blockStart = 0
        while blockStart < b.count {
            let blockEnd = min(blockStart + blockSize, b.count)
            var p = blockStart
            while p + 7 <= blockEnd {
                let len = Int(b[p + 4]) | Int(b[p + 5]) << 8
                let type = b[p + 6]
                if type == 0 && len == 0 { break }               // zero padding at the end of a block
                let start = p + 7, end = start + len
                guard end <= blockEnd else { break }
                switch type {
                case 1: out.append(Array(b[start..<end])); pending = []
                case 2: pending = Array(b[start..<end])
                case 3: pending += b[start..<end]
                case 4: pending += b[start..<end]; out.append(pending); pending = []
                default: break
                }
                p = end
            }
            blockStart += blockSize
        }
        return out
    }

    /// A write batch: 8-byte sequence, 4-byte count, then (tag, key, [value]) entries.
    /// Returns (key, value) pairs; a delete has a nil value.
    static func batchEntries(_ r: [UInt8]) -> [([UInt8], [UInt8]?)]? {
        guard r.count >= 12 else { return nil }
        let count = Int(r[8]) | Int(r[9]) << 8 | Int(r[10]) << 16 | Int(r[11]) << 24
        var i = 12
        var out: [([UInt8], [UInt8]?)] = []
        func varint() -> Int? {
            var v = 0, shift = 0
            while i < r.count, shift < 35 {
                let byte = r[i]; i += 1
                v |= Int(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        func slice() -> [UInt8]? {
            guard let n = varint(), n >= 0, i + n <= r.count else { return nil }
            defer { i += n }
            return Array(r[i..<i + n])
        }
        for _ in 0..<count {
            guard i < r.count else { return nil }
            let tag = r[i]; i += 1
            guard let key = slice() else { return nil }
            if tag == 1 {
                guard let value = slice() else { return nil }
                out.append((key, value))
            } else if tag == 0 {
                out.append((key, nil))
            } else {
                return nil
            }
        }
        return out
    }

    /// Chromium local storage values start with 0 (UTF-16LE) or 1 (Latin-1).
    static func decodeLocalStorageValue(_ v: [UInt8]) -> String? {
        guard let first = v.first else { return nil }
        let rest = Data(v.dropFirst())
        switch first {
        case 0: return String(data: rest, encoding: .utf16LittleEndian)
        case 1: return String(data: rest, encoding: .isoLatin1)
        default: return String(data: Data(v), encoding: .utf8)
        }
    }
}

/// The desktop app's own list of unread Code chats (the sidebar's blue dots),
/// from the `epitaxy-unread-v1` local storage key.
final class DesktopUnread {
    let leveldbDir: URL
    let defaults: UserDefaults
    private var lastRead: (path: String, size: Int, modified: Date)?
    /// The latest list seen. Survives log compaction, which moves the key out of the log
    /// until the app next writes it.
    private(set) var ids: Set<String>?

    init(leveldbDir: URL, defaults: UserDefaults) {
        self.leveldbDir = leveldbDir
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: "lastUnreadIds") { ids = Set(saved) }
    }

    static func parse(_ json: String) -> Set<String>? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = obj["state"] as? [String: Any] else { return nil }
        let unread = state["unreadIds"] as? [String] ?? []
        let explicit = state["explicitUnreadIds"] as? [String] ?? []
        return Set(unread + explicit)
    }

    func refresh() {
        let fm = FileManager.default
        let logs = ((try? fm.contentsOfDirectory(at: leveldbDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "log" }
        guard let newest = logs.max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let rv = try? newest.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = rv.fileSize, let modified = rv.contentModificationDate else { return }
        if let l = lastRead, l.path == newest.path, l.size == size, l.modified == modified { return }
        lastRead = (newest.path, size, modified)
        guard let data = try? Data(contentsOf: newest) else { return }
        switch LevelDBLog.lastValue(in: [UInt8](data), keySuffix: Array("epitaxy-unread-v1".utf8)) {
        case .some(.some(let v)):
            if let s = LevelDBLog.decodeLocalStorageValue(v), let parsed = Self.parse(s) {
                ids = parsed
                defaults.set(Array(parsed).sorted(), forKey: "lastUnreadIds")
            }
        case .some(.none):
            ids = []
        case .none:
            break      // not in this log (compacted away): keep the last list we saw
        }
    }
}

final class SessionStore: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    /// id -> when it finished, for every session shown as done.
    @Published var finished: [String: Date] = [:]

    let sessionsDir: URL
    let desktop: DesktopChats
    let unread: DesktopUnread
    var now: () -> Date = Date.init                   // replaceable in tests

    private var lastGood: [String: RawSession] = [:]       // file name -> last decodable contents
    private var previousState: [String: SessionState] = [:]
    private var idleSince: [String: Date] = [:]           // debounce busy -> idle flicker
    private var terminalFinished: [String: Date] = [:]    // sessions with no desktop chat
    private var dismissedDesktop: [String: Double] = [:]  // hostId -> lastTurnEdgeAt when dismissed
    private var timer: Timer?

    static let doneDebounce: TimeInterval = 3
    static let doneExpiry: TimeInterval = 30 * 60

    init(sessionsDir: URL? = nil, desktopDir: URL? = nil, leveldbDir: URL? = nil, defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude = home.appendingPathComponent("Library/Application Support/Claude")
        self.sessionsDir = sessionsDir ?? env["CLAUDE_PET_SESSIONS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/sessions")
        desktop = DesktopChats(dir: desktopDir ?? env["CLAUDE_PET_DESKTOP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? claude.appendingPathComponent("claude-code-sessions"))
        unread = DesktopUnread(leveldbDir: leveldbDir ?? env["CLAUDE_PET_LEVELDB_DIR"].map { URL(fileURLWithPath: $0) }
            ?? claude.appendingPathComponent("Local Storage/leveldb"), defaults: defaults)
    }

    func start() {
        poll()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)     // keep polling while a menu is open
        timer = t
    }

    func dismissFinished(_ id: String) {
        if let s = sessions.first(where: { $0.id == id }), let h = s.hostSessionId {
            dismissedDesktop[h] = desktopChats[h]?.lastTurnEdgeAt ?? 0
        }
        terminalFinished[id] = nil
        finished[id] = nil
    }

    func dismissAllFinished() {
        for id in finished.keys { dismissFinished(id) }
    }

    private var desktopChats: [String: DesktopChat] = [:]

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    func poll() {
        let now = now()
        desktopChats = desktop.load()
        unread.refresh()

        // Live sessions from ~/.claude/sessions.
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var seenFiles = Set<String>()
        var result: [SessionInfo] = []
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

            // A desktop chat goes by its sidebar title.
            let name = raw.hostSessionId.flatMap { desktopChats[$0]?.title }
                ?? (raw.name?.isEmpty == false ? raw.name! : nil)
                ?? raw.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Session \(raw.pid)"
            let ts = (raw.statusUpdatedAt ?? raw.updatedAt ?? 0) / 1000
            result.append(SessionInfo(id: sid, pid: raw.pid, name: name, state: state,
                                      waitingFor: raw.waitingFor,
                                      statusUpdatedAt: Date(timeIntervalSince1970: ts),
                                      hostSessionId: raw.hostSessionId))
        }
        lastGood = lastGood.filter { seenFiles.contains($0.key) }

        // One entry per desktop chat: a chat can have more than one process; keep the most urgent.
        func rank(_ s: SessionInfo) -> Int {
            switch s.state { case .waiting: return 0; case .busy: return 1; case .idle: return 2 }
        }
        var byHost: [String: SessionInfo] = [:]
        for s in result {
            guard let h = s.hostSessionId else { continue }
            if let other = byHost[h],
               (rank(other), -other.statusUpdatedAt.timeIntervalSince1970) <= (rank(s), -s.statusUpdatedAt.timeIntervalSince1970) {
                continue
            }
            byHost[h] = s
        }
        result = result.filter { s in s.hostSessionId.map { byHost[$0]?.id == s.id } ?? true }

        // Terminal sessions: "done" is a busy -> idle change seen while the pet runs, after a debounce.
        for s in result {
            let prev = previousState[s.id]
            if s.state == .idle {
                if prev == .busy || prev == .waiting { idleSince[s.id] = now }
                if let since = idleSince[s.id], now.timeIntervalSince(since) >= Self.doneDebounce {
                    terminalFinished[s.id] = since
                    idleSince[s.id] = nil
                }
                previousState[s.id] = .idle
            } else {
                idleSince[s.id] = nil
                terminalFinished[s.id] = nil
                previousState[s.id] = s.state
            }
        }
        let liveIds = Set(result.map(\.id))
        terminalFinished = terminalFinished.filter { liveIds.contains($0.key) && now.timeIntervalSince($0.value) < Self.doneExpiry }
        idleSince = idleSince.filter { liveIds.contains($0.key) }
        previousState = previousState.filter { liveIds.contains($0.key) }

        // Desktop chats: "done" is whatever the desktop app shows as unread.
        let liveHostIds = Set(result.compactMap(\.hostSessionId))
        var newFinished: [String: Date] = [:]
        func isUnread(_ chat: DesktopChat) -> Bool {
            if chat.isArchived { return false }
            if let ids = unread.ids { return ids.contains(chat.hostId) }
            // No list from the app yet: a turn that ended after the chat was last opened.
            guard let edge = chat.lastTurnEdgeAt ?? chat.lastActivityAt else { return false }
            return edge > (chat.lastFocusedAt ?? 0)
        }
        func edgeDate(_ chat: DesktopChat?) -> Date? {
            (chat?.lastTurnEdgeAt ?? chat?.lastActivityAt).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        for s in result where s.state == .idle {
            if let h = s.hostSessionId, let chat = desktopChats[h] {
                if isUnread(chat), (dismissedDesktop[h].map { (chat.lastTurnEdgeAt ?? 0) > $0 } ?? true) {
                    newFinished[s.id] = edgeDate(chat) ?? s.statusUpdatedAt
                }
            } else if let t = terminalFinished[s.id] {
                newFinished[s.id] = t
            }
        }
        // Unread desktop chats whose process has stopped still belong on the list.
        for chat in desktopChats.values where !liveHostIds.contains(chat.hostId) && isUnread(chat) {
            if let d = dismissedDesktop[chat.hostId], (chat.lastTurnEdgeAt ?? 0) <= d { continue }
            let at = edgeDate(chat) ?? .distantPast
            result.append(SessionInfo(id: chat.hostId, pid: 0, name: chat.title ?? "Untitled chat", state: .idle,
                                      waitingFor: nil, statusUpdatedAt: at, hostSessionId: chat.hostId))
            newFinished[chat.hostId] = at
        }
        // A dismissal lasts until that chat is read in the app (then it's forgotten).
        dismissedDesktop = dismissedDesktop.filter { h, _ in desktopChats[h].map(isUnread) ?? false }

        result.sort { a, b in
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
    var idleCount: Int { sessions.filter { $0.state == .idle && finished[$0.id] == nil && $0.pid != 0 }.count }
}

// MARK: - Built-in pixel pets

enum PetMood { case sleepy, idle, working, waiting, cheering }

/// A built-in pet: the shared 16x16 body with its own top rows (hair, ears, antenna) and colors.
struct BuiltinPet {
    let id: String
    let name: String
    let top: [String]                 // the 4 rows above the head
    let colors: [Character: Color]    // overrides of PixelPet.palette

    static let sprout = BuiltinPet(id: "builtin:sprout", name: "Sprout", top: [
        "..K...K...K.....",
        ".KWK.KWK.KWK.K..",
        "KWWWKWWWKWWWKWK.",
        ".KWwWWWwWWWwWWK.",
    ], colors: [:])

    static let mochi = BuiltinPet(id: "builtin:mochi", name: "Mochi", top: [
        "................",
        "..K..........K..",
        "..KK........KK..",
        "..KRK......KRK..",
    ], colors: [
        "O": Color(red: 0.97, green: 0.89, blue: 0.82),
        "o": Color(red: 0.86, green: 0.73, blue: 0.66),
        "R": Color(red: 0.96, green: 0.62, blue: 0.70),
        "M": Color(red: 0.55, green: 0.25, blue: 0.30),
    ])

    static let bolt = BuiltinPet(id: "builtin:bolt", name: "Bolt", top: [
        ".......YY.......",
        ".......KK.......",
        ".......KK.......",
        "....KKKKKKKK....",
    ], colors: [
        "O": Color(red: 0.42, green: 0.74, blue: 0.72),
        "o": Color(red: 0.27, green: 0.53, blue: 0.53),
        "R": Color(red: 1.00, green: 0.84, blue: 0.30),
        "M": Color(red: 0.13, green: 0.25, blue: 0.27),
    ])

    static let all = [sprout, mochi, bolt]

    func color(_ ch: Character) -> Color? { colors[ch] ?? PixelPet.palette[ch] }
}

/// The shared 16x16 body. Each row is 16 characters; each character is a palette color.
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

    static let head =   "..KKKKKKKKKKKK.."
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

    static func grid(_ mood: PetMood, frame: Int, blink: Bool, look: Int, pet: BuiltinPet = .sprout) -> [String] {
        var rows = pet.top + [head] + eyes(mood, blink: blink, look: look) + mouth(mood, frame: frame) + [blank] + bottom
        if mood == .cheering && frame % 2 == 0 {
            // arms up
            rows[8] = "K" + rows[8].dropFirst().dropLast() + "K"
            rows[9] = "O" + rows[9].dropFirst().dropLast() + "O"
        }
        return rows
    }
}

struct PetCanvas: View {
    let pet: BuiltinPet
    let mood: PetMood
    let frame: Int
    let pixel: CGFloat

    var body: some View {
        let blink = mood != .working && frame % 17 == 0
        let look = mood == .idle ? [0, 0, 0, -1, 0, 0, 1, 0][(frame / 6) % 8] : 0
        let rows = PixelPet.grid(mood, frame: frame, blink: blink, look: look, pet: pet)
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
                    guard let c = pet.color(ch) else { continue }
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
        .overlay(alignment: .topTrailing) { if mood == .sleepy { Zzz(frame: frame) } }
    }
}

struct Zzz: View {
    let frame: Int
    var body: some View {
        Text(frame % 6 < 3 ? "z" : "Z")
            .font(.system(size: 13, weight: .heavy, design: .monospaced))
            .foregroundStyle(.secondary)
            .offset(x: 6, y: CGFloat(-(frame % 6)))
    }
}

// MARK: - Sprite-sheet pets (Codex format)

/// A Codex-compatible pet: an 8-column atlas of 192x208 cells, one animation per row
/// (idle, run right, run left, wave, jump, failed, waiting, running, review).
final class SpriteSheet {
    let frames: [[CGImage]]       // the non-empty cells of each row
    let cellSize: CGSize

    static let columns = 8
    enum Row: Int { case idle = 0, runRight, runLeft, wave, jump, failed, waiting, running, review }

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cw = img.width / Self.columns
        guard cw > 0 else { return nil }
        let ch = Int((Double(cw) * 208 / 192).rounded())
        let rows = img.height / ch
        guard rows >= 1 else { return nil }
        var all: [[CGImage]] = []
        for r in 0..<rows {
            var row: [CGImage] = []
            for c in 0..<Self.columns {
                if let cell = img.cropping(to: CGRect(x: c * cw, y: r * ch, width: cw, height: ch)),
                   !Self.isEmpty(cell) {
                    row.append(cell)
                }
            }
            all.append(row)
        }
        guard let first = all.first, !first.isEmpty else { return nil }
        frames = all
        cellSize = CGSize(width: cw, height: ch)
    }

    /// The frames of an animation row, falling back to idle when the sheet leaves it empty.
    func frames(for row: Row) -> [CGImage] {
        let r = row.rawValue
        return r < frames.count && !frames[r].isEmpty ? frames[r] : frames[0]
    }

    private static func isEmpty(_ img: CGImage) -> Bool {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return drawn && !stride(from: 3, to: px.count, by: 4).contains { px[$0] > 8 }
    }
}

// MARK: - Pet library

struct PetManifest: Decodable {
    let id: String?
    let displayName: String?
    let spritesheetPath: String?
}

struct PetEntry: Identifiable {
    enum Kind { case builtin(BuiltinPet), sprite(SpriteSheet) }
    let id: String
    let name: String
    let kind: Kind
}

struct ImportError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Built-in pets, pets imported into Claude Pet, and any Codex pets on this Mac.
final class PetLibrary: ObservableObject {
    @Published private(set) var pets: [PetEntry] = []
    @Published var selectedId: String {
        didSet { UserDefaults.standard.set(selectedId, forKey: "pet") }
    }

    static let importDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePet/pets")
    static var codexDir: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("pets")
    }

    init() {
        selectedId = UserDefaults.standard.string(forKey: "pet") ?? BuiltinPet.sprout.id
        reload()
    }

    var selected: PetEntry { pets.first { $0.id == selectedId } ?? pets[0] }

    func reload() {
        var list = BuiltinPet.all.map { PetEntry(id: $0.id, name: $0.name, kind: .builtin($0)) }
        list += Self.scan(Self.importDir, prefix: "local", suffix: "")
        list += Self.scan(Self.codexDir, prefix: "codex", suffix: " (Codex)")
        pets = list
    }

    private static func scan(_ dir: URL, prefix: String, suffix: String) -> [PetEntry] {
        let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("pet.json")),
                  let m = try? JSONDecoder().decode(PetManifest.self, from: data),
                  let sheet = SpriteSheet(url: folder.appendingPathComponent(m.spritesheetPath ?? "spritesheet.webp"))
            else { return nil }
            let name = m.displayName ?? m.id ?? folder.lastPathComponent
            return PetEntry(id: "\(prefix):\(folder.lastPathComponent)", name: name + suffix, kind: .sprite(sheet))
        }
    }

    /// Asks for a pet folder (pet.json + sprite sheet) or a bare sprite sheet image,
    /// copies it into Claude Pet's pets folder, and selects it.
    func importPet() {
        let panel = NSOpenPanel()
        panel.title = "Import a Pet"
        panel.message = "Choose a Codex pet folder (pet.json + spritesheet) or a sprite sheet image: 8 columns of 192×208 frames."
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .png, .webP]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let fm = FileManager.default
        var dest: URL?
        do {
            try fm.createDirectory(at: Self.importDir, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            var target = Self.importDir.appendingPathComponent(base)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = Self.importDir.appendingPathComponent("\(base)-\(n)"); n += 1
            }
            dest = target
            if url.hasDirectoryPath {
                guard fm.fileExists(atPath: url.appendingPathComponent("pet.json").path) else {
                    throw ImportError("That folder has no pet.json. Choose a Codex pet folder or a sprite sheet image.")
                }
                try fm.copyItem(at: url, to: target)
            } else {
                guard SpriteSheet(url: url) != nil else {
                    throw ImportError("That image isn't a sprite sheet Claude Pet can read.")
                }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let sheetName = "spritesheet." + url.pathExtension.lowercased()
                try fm.copyItem(at: url, to: target.appendingPathComponent(sheetName))
                let manifest = ["id": target.lastPathComponent, "displayName": base,
                                "description": "Imported into Claude Pet.", "spritesheetPath": sheetName]
                try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                    .write(to: target.appendingPathComponent("pet.json"))
            }
            reload()
            let newId = "local:\(target.lastPathComponent)"
            guard pets.contains(where: { $0.id == newId }) else {
                throw ImportError("Claude Pet couldn't read the sprite sheet in that pet.")
            }
            selectedId = newId
        } catch {
            if let dest { try? fm.removeItem(at: dest) }
            let alert = NSAlert()
            alert.messageText = "Couldn't import that pet"
            alert.informativeText = (error as? ImportError)?.message ?? error.localizedDescription
            alert.runModal()
        }
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: Self.importDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.importDir)
    }
}

/// Draws whichever pet is selected in the given mood.
struct PetFigure: View {
    let pet: PetEntry
    let mood: PetMood
    let frame: Int        // ticks at 8 per second
    let dragDir: Int      // -1 dragging left, 1 right, 0 not dragging
    let scale: CGFloat

    var body: some View {
        switch pet.kind {
        case .builtin(let b):
            PetCanvas(pet: b, mood: mood, frame: frame / 2, pixel: (5 * scale).rounded())
        case .sprite(let sheet):
            let row: SpriteSheet.Row = dragDir > 0 ? .runRight : dragDir < 0 ? .runLeft : {
                switch mood {
                case .working: return .running
                case .waiting: return .waiting
                case .cheering: return .jump
                case .idle, .sleepy: return .idle
                }
            }()
            let frames = sheet.frames(for: row)
            let slow = row == .idle ? (mood == .sleepy ? 4 : 2) : 1
            let h = 104 * scale
            Image(decorative: frames[(frame / slow) % frames.count], scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: h * sheet.cellSize.width / sheet.cellSize.height, height: h)
                .overlay(alignment: .topTrailing) { if mood == .sleepy { Zzz(frame: frame / 2) } }
        }
    }
}

// MARK: - Views

enum Theme {
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)          // the pet's orange
    static let card = Color(nsColor: .windowBackgroundColor)
    static let waiting = Color(red: 0.95, green: 0.55, blue: 0.15)
    static let working = Color(red: 0.30, green: 0.55, blue: 0.95)
    static let done = Color(red: 0.25, green: 0.70, blue: 0.40)
}

/// Solid (not vibrant) surface: a non-activating panel is never key, and
/// materials render washed out in that state.
struct CardBackground: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
    }
}

extension View {
    func card(radius: CGFloat = 16) -> some View { modifier(CardBackground(radius: radius)) }
}

func ago(_ d: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(d)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 48 * 3600 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}

struct PetView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var library: PetLibrary
    @AppStorage("expanded") private var expanded = true
    @AppStorage("showIdle") private var showIdle = false
    @AppStorage("petScale") private var petScale = 1.0
    @State private var frame = 0
    @State private var cheerUntil: Date = .distantPast
    @State private var lastDoneCount = 0
    @State private var dragDir = 0
    let tick = Timer.publish(every: 0.125, on: .main, in: .common).autoconnect()

    var mood: PetMood {
        if !store.waiting.isEmpty { return .waiting }
        if Date() < cheerUntil { return .cheering }
        if !store.busy.isEmpty { return .working }
        if !store.done.isEmpty { return .idle }
        return .sleepy
    }

    var body: some View {
        VStack(spacing: 6) {
            PetFigure(pet: library.selected, mood: mood, frame: frame, dragDir: dragDir, scale: petScale)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture(direction: $dragDir))
                .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                .help("Click to show or hide sessions · drag to move · right-click for options")

            ControlPill(store: store, expanded: $expanded)

            if expanded {
                SessionStack(store: store, showIdle: showIdle, second: frame / 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .frame(width: 304)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { (NSApp.delegate as? AppDelegate)?.fit(g.size) }
                .onChange(of: g.size) { _, size in (NSApp.delegate as? AppDelegate)?.fit(size) }
        })
        .contextMenu {
            Picker("Pet", selection: $library.selectedId) {
                ForEach(library.pets) { Text($0.name).tag($0.id) }
            }
            Button("Import Pet…") { library.importPet() }
            Button("Open Pets Folder") { library.openFolder() }
            Button("Reload Pets") { library.reload() }
            Divider()
            Picker("Size", selection: $petScale) {
                Text("Small").tag(0.8)
                Text("Medium").tag(1.0)
                Text("Large").tag(1.25)
            }
            Toggle("Show Idle Sessions", isOn: $showIdle)
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
    @Binding var direction: Int

    var body: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { _ in
                guard let w = NSApp.windows.first(where: { $0 is PetPanel }),
                      let event = NSApp.currentEvent else { return }
                w.setFrameOrigin(NSPoint(x: w.frame.origin.x + event.deltaX,
                                         y: w.frame.origin.y - event.deltaY))
                if event.deltaX > 0.5 { direction = 1 } else if event.deltaX < -0.5 { direction = -1 }
            }
            .onEnded { _ in
                direction = 0
                (NSApp.delegate as? AppDelegate)?.savePosition()
            }
    }
}

/// The small pill under the pet: new session, live counts, and the list toggle.
struct ControlPill: View {
    @ObservedObject var store: SessionStore
    @Binding var expanded: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { openURL("claude://code/new?source=claude_pet") } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 40, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Claude Code session")

            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 16)

            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 9) {
                    counts
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide sessions" : "Show sessions")
        }
        .card(radius: 16)
    }

    @ViewBuilder var counts: some View {
        if store.waiting.isEmpty && store.busy.isEmpty && store.done.isEmpty {
            Text("Idle").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                if !store.waiting.isEmpty { count(store.waiting.count, Theme.waiting) }
                if !store.busy.isEmpty { count(store.busy.count, Theme.working) }
                if !store.done.isEmpty { count(store.done.count, Theme.done) }
            }
        }
    }

    func count(_ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(n)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

/// The sessions as a stack of small cards, most urgent first.
struct SessionStack: View {
    @ObservedObject var store: SessionStore
    let showIdle: Bool
    let second: Int          // changes every second so the times on the cards tick
    static let maxCards = 5

    struct Item: Identifiable {
        let session: SessionInfo
        let kind: SessionToast.Kind
        let detail: String
        let time: String
        var id: String { session.id }
    }

    var items: [Item] {
        var out: [Item] = []
        out += store.waiting.map { Item(session: $0, kind: .waiting,
                                        detail: $0.waitingFor.map { "Needs you · \($0)" } ?? "Needs you",
                                        time: ago($0.statusUpdatedAt)) }
        out += store.busy.map { Item(session: $0, kind: .busy, detail: "Working", time: ago($0.statusUpdatedAt)) }
        out += store.done.map { Item(session: $0, kind: .done, detail: "Finished",
                                     time: ago(store.finished[$0.id] ?? $0.statusUpdatedAt)) }
        if showIdle {
            out += store.sessions.filter { $0.state == .idle && store.finished[$0.id] == nil }
                .map { Item(session: $0, kind: .idle, detail: "Idle", time: ago($0.statusUpdatedAt)) }
        }
        return out
    }

    var body: some View {
        let all = items
        VStack(spacing: 6) {
            if all.isEmpty {
                Text("Nothing running right now")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .card(radius: 14)
            }
            ForEach(all.prefix(Self.maxCards)) { item in
                SessionToast(session: item.session, kind: item.kind, detail: item.detail, time: item.time) {
                    openSession(item.session)
                }
            }
            if all.count > Self.maxCards {
                Button { activateClaude() } label: {
                    Text("+\(all.count - Self.maxCards) more")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One session, styled like a notification card.
struct SessionToast: View {
    enum Kind { case waiting, busy, done, idle }

    let session: SessionInfo
    let kind: Kind
    let detail: String
    let time: String
    let action: () -> Void
    @State private var hover = false

    var tint: Color {
        switch kind {
        case .waiting: return Theme.waiting
        case .busy: return Theme.working
        case .done: return Theme.done
        case .idle: return .secondary
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.14))
                    switch kind {
                    case .busy:
                        PulseDot(color: tint)
                    case .waiting:
                        Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(tint)
                    case .done:
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(tint)
                    case .idle:
                        Image(systemName: "moon.fill").font(.system(size: 8)).foregroundStyle(tint)
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(kind == .waiting ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                Group {
                    if hover {
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    } else {
                        Text(time).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 30, alignment: .trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(hover ? tint.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A small dot that breathes while a session works. Driven by a timeline, not an
/// implicit animation, so it never animates its position when the list changes.
struct PulseDot: View {
    let color: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { ctx in
            let phase = (sin(ctx.date.timeIntervalSinceReferenceDate * 3.5) + 1) / 2
            Circle().fill(color)
                .frame(width: 8, height: 8)
                .scaleEffect(0.6 + 0.4 * phase)
                .opacity(0.45 + 0.55 * phase)
        }
    }
}

/// Opens the chat behind a card: the desktop chat itself, or the app running a terminal session.
func openSession(_ s: SessionInfo) {
    if let h = s.hostSessionId,
       let id = h.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
        openURL("claude://code/continue?session=\(id)&source=claude_pet")
    } else if s.pid > 0, let app = owningApp(of: s.pid) {
        app.activate()
    } else {
        activateClaude()
    }
}

/// The nearest ancestor of a process that is a regular app (the terminal running `claude`).
func owningApp(of pid: Int32) -> NSRunningApplication? {
    var p = pid
    for _ in 0..<12 where p > 1 {
        if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, p]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        p = info.kp_eproc.e_ppid
    }
    return nil
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
    let library = PetLibrary()

    func applicationDidFinishLaunching(_ note: Notification) {
        // One pet at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0 != NSRunningApplication.current && !$0.isTerminated }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)   // no Dock icon
        store.start()

        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: 304, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        let host = NSHostingView(rootView: PetView(store: store, library: library))
        host.sizingOptions = []                 // the panel follows the content via fit(_:)
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host

        if let s = UserDefaults.standard.string(forKey: "topLeft") {
            place(topLeft: NSPointFromString(s))
        } else {
            resetPosition()
        }
        panel.orderFrontRegardless()

        // Keep the pet on screen: displays come and go, and nothing should leave it hidden.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.keepOnScreen() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.panel.orderFrontRegardless()
        }
        let watchdog = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.isVisible { panel.orderFrontRegardless() }
            self.keepOnScreen()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        // Polling and animation shouldn't be throttled by App Nap while the pet is up.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                          reason: "Watching Claude Code sessions")
    }

    private var activity: NSObjectProtocol?

    /// Moves the panel back if no screen shows its top edge anymore.
    func keepOnScreen() {
        guard let panel else { return }
        let top = NSPoint(x: panel.frame.minX + 40, y: panel.frame.maxY - 20)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(top) }) {
            place(topLeft: NSPoint(x: panel.frame.minX, y: panel.frame.maxY))
            if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: panel.frame.minX + 40, y: panel.frame.maxY - 20)) }) {
                resetPosition()
            }
            savePosition()
        }
    }

    /// Resizes the panel to the content, keeping its top-left corner where it is.
    func fit(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0,
              abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    /// Moves the panel so its top-left is at `p`, kept on screen.
    func place(topLeft p: NSPoint) {
        var p = p
        if let v = (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.visibleFrame {
            p.x = min(max(p.x, v.minX), v.maxX - panel.frame.width)
            p.y = min(max(p.y, v.minY + 120), v.maxY)
        }
        panel.setFrameTopLeftPoint(p)
    }

    func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: panel.frame.minX, y: panel.frame.maxY)), forKey: "topLeft")
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: "topLeft")
        if let v = NSScreen.main?.visibleFrame {
            place(topLeft: NSPoint(x: v.maxX - panel.frame.width - 16, y: v.maxY - 12))
        }
    }
}

// MARK: - App icon

/// Draws the app icon from the same sprite the pet uses. build.sh calls
/// `ClaudePet --render-icon <dir>` to produce the .iconset.
enum IconRenderer {
    static func render(size: Int) -> Data? {
        // Below 64px the sprite can't fit at whole pixels; draw at 128 and scale down.
        if size < 64 {
            guard let big = render(size: 128), let src = NSBitmapImageRep(data: big)?.cgImage,
                  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))
            guard let img = ctx.makeImage() else { return nil }
            return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
        }
        let s = CGFloat(size)
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        func cg(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.sRGB)!.cgColor }
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

        // macOS icon grid: an 824/1024 rounded square, centered, with a soft drop shadow.
        let inset = s * 100 / 1024
        let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(tilePath); ctx.setFillColor(rgb(0.10, 0.09, 0.20)); ctx.fillPath()
        ctx.restoreGState()

        // Night-lab gradient, faint pixel grid, and a few stars.
        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [rgb(0.29, 0.22, 0.52), rgb(0.12, 0.10, 0.27)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        let cell = tile.width / 20
        if size >= 128 {
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.045)); ctx.setLineWidth(max(1, s / 512))
            var x = tile.minX
            while x <= tile.maxX { ctx.move(to: CGPoint(x: x, y: tile.minY)); ctx.addLine(to: CGPoint(x: x, y: tile.maxY)); x += cell }
            var y = tile.minY
            while y <= tile.maxY { ctx.move(to: CGPoint(x: tile.minX, y: y)); ctx.addLine(to: CGPoint(x: tile.maxX, y: y)); y += cell }
            ctx.strokePath()
        }
        // A glow behind the pet
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.45),
                                       CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s / 2, y: s * 0.52), startRadius: 0,
                               endCenter: CGPoint(x: s / 2, y: s * 0.52), endRadius: tile.width * 0.48, options: [])
        let spark = cg(PixelPet.palette["Y"]!)
        for (cx, cy, k) in [(3, 15, 1.0), (16, 16, 1.0), (15, 4, 0.7), (2, 6, 0.7)] as [(Int, Int, CGFloat)] {
            ctx.setFillColor(spark.copy(alpha: k)!)
            ctx.fill(CGRect(x: tile.minX + CGFloat(cx) * cell, y: tile.minY + CGFloat(cy) * cell, width: cell, height: cell))
        }
        ctx.restoreGState()

        // The pet, snapped to whole pixels so small sizes stay crisp.
        let rows = PixelPet.grid(.idle, frame: 0, blink: false, look: 0)
        let px = max(1, floor(tile.width * 0.68 / 16))
        let w = px * 16, h = px * CGFloat(rows.count)
        let ox = floor((s - w) / 2), oy = floor((s - h) / 2 - s * 0.01)
        // floor shadow
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        ctx.fillEllipse(in: CGRect(x: ox + px * 2, y: oy - px * 0.9, width: w - px * 4, height: px * 1.6))
        for (r, row) in rows.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let color = PixelPet.palette[ch] else { continue }
                ctx.setFillColor(cg(color))
                ctx.fill(CGRect(x: ox + CGFloat(c) * px, y: oy + h - CGFloat(r + 1) * px, width: px, height: px))
            }
        }

        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                if let data = render(size: base * scale) {
                    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                }
            }
        }
    }
}

// MARK: - Self-test

/// `ClaudePet --self-test` checks the session logic against fake folders and exits
/// non-zero on failure. build.sh runs it after compiling.
enum SelfTest {
    static var failures = 0
    static var checks = 0

    static func expect(_ cond: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
        checks += 1
        if !cond() { failures += 1; print("  ✗ \(what) (line \(line))") }
    }

    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudepet-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "local.claudepet.selftest")!
        defaults.removePersistentDomain(forName: "local.claudepet.selftest")

        print("LevelDB log"); testLevelDB()
        print("Desktop unread list"); testUnreadStore(root.appendingPathComponent("a"), defaults)
        print("Fallback without the app's list"); testFallback(root.appendingPathComponent("b"), defaults)
        print("Terminal sessions"); testTerminal(root.appendingPathComponent("c"), defaults)
        print("Sprite sheets"); testSpriteSheet(root.appendingPathComponent("d"))

        defaults.removePersistentDomain(forName: "local.claudepet.selftest")
        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }

    // MARK: Fixtures

    static func varint(_ n: Int) -> [UInt8] {
        var n = n, out: [UInt8] = []
        while n >= 0x80 { out.append(UInt8(n & 0x7f) | 0x80); n >>= 7 }
        out.append(UInt8(n))
        return out
    }

    static func batch(seq: Int, _ entries: [([UInt8], [UInt8]?)]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 8)
        b[0] = UInt8(seq & 0xff)
        let c = entries.count
        b += [UInt8(c & 0xff), UInt8((c >> 8) & 0xff), 0, 0]
        for (k, v) in entries {
            b.append(v == nil ? 0 : 1)
            b += varint(k.count) + k
            if let v { b += varint(v.count) + v }
        }
        return b
    }

    /// Lays records out the way LevelDB does: 32 KB blocks, records split across them.
    static func log(_ records: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = []
        for r in records {
            var rest = r[...]
            var first = true
            repeat {
                let left = LevelDBLog.blockSize - out.count % LevelDBLog.blockSize
                if left < 7 { out += [UInt8](repeating: 0, count: left); continue }
                let n = min(rest.count, left - 7)
                let last = n == rest.count
                let type: UInt8 = first ? (last ? 1 : 2) : (last ? 4 : 3)
                out += [0, 0, 0, 0, UInt8(n & 0xff), UInt8(n >> 8), type]
                out += rest.prefix(n)
                rest = rest.dropFirst(n)
                first = false
            } while !rest.isEmpty
        }
        return out
    }

    static let unreadKey = Array("_https://claude.ai\u{0}\u{1}epitaxy-unread-v1".utf8)

    static func unreadValue(_ ids: [String]) -> [UInt8] {
        let json = "{\"state\":{\"unreadIds\":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))],\"explicitUnreadIds\":[]},\"version\":0}"
        return [1] + Array(json.utf8)
    }

    static func write(_ bytes: [UInt8], to url: URL, bump: TimeInterval = 0) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(bytes).write(to: url)
        // Push the modification time forward so caches keyed on it always notice the change.
        let t = Date().addingTimeInterval(bump)
        try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: url.path)
    }

    static func writeJSON(_ obj: [String: Any], to url: URL, bump: TimeInterval = 0) {
        write([UInt8](try! JSONSerialization.data(withJSONObject: obj)), to: url, bump: bump)
    }

    static let me = Int(getpid())          // a pid that is certainly alive
    static let dead = 999_999              // and one that isn't

    static func session(_ dir: URL, pid: Int, file: String? = nil, id: String, host: String?, name: String, status: String) {
        var o: [String: Any] = ["pid": pid, "sessionId": id, "name": name, "status": status, "statusUpdatedAt": 1_000_000]
        if let host { o["hostSessionId"] = host }
        writeJSON(o, to: dir.appendingPathComponent(file ?? "\(id).json"))
    }

    static func chat(_ dir: URL, _ host: String, title: String, edge: Double, focused: Double, archived: Bool = false, bump: TimeInterval = 0) {
        writeJSON(["title": title, "lastTurnEdgeAt": edge, "lastFocusedAt": focused, "isArchived": archived],
                  to: dir.appendingPathComponent("acct/org/\(host).json"), bump: bump)
    }

    // MARK: Tests

    static func testLevelDB() {
        let filler = [UInt8](repeating: 7, count: LevelDBLog.blockSize - 7 - 40)
        let recs = [
            batch(seq: 1, [(unreadKey, unreadValue(["local_old"]))]),
            batch(seq: 2, [(Array("other".utf8), filler)]),
            batch(seq: 3, [(Array("x".utf8), [1, 2]), (unreadKey, unreadValue(["local_a", "local_b"]))]),   // straddles a block
        ]
        let bytes = log(recs)
        expect(LevelDBLog.records(bytes).count == 3, "reassembles 3 records across blocks")
        if case .some(.some(let v)) = LevelDBLog.lastValue(in: bytes, keySuffix: Array("epitaxy-unread-v1".utf8)),
           let s = LevelDBLog.decodeLocalStorageValue(v) {
            expect(DesktopUnread.parse(s) == ["local_a", "local_b"], "last write wins")
        } else {
            expect(false, "finds the key")
        }
        let deleted = log(recs + [batch(seq: 4, [(unreadKey, nil)])])
        if case .some(.none) = LevelDBLog.lastValue(in: deleted, keySuffix: Array("epitaxy-unread-v1".utf8)) {
            expect(true, "")
        } else {
            expect(false, "a delete is reported as a delete")
        }
        let missing = LevelDBLog.lastValue(in: log([batch(seq: 1, [(Array("k".utf8), [1])])]), keySuffix: Array("nope".utf8))
        expect(missing == nil, "absent key is nil")
        expect(LevelDBLog.lastValue(in: [1, 2, 3], keySuffix: [1]) == nil, "garbage doesn't crash")
        let utf16: [UInt8] = [0] + Array("{\"a\":1}".data(using: .utf16LittleEndian)!)
        expect(LevelDBLog.decodeLocalStorageValue(utf16) == "{\"a\":1}", "decodes UTF-16 values")
    }

    static func testUnreadStore(_ root: URL, _ defaults: UserDefaults) {
        let sessions = root.appendingPathComponent("sessions"), desk = root.appendingPathComponent("desk")
        let ldb = root.appendingPathComponent("ldb")
        session(sessions, pid: me, id: "s-a", host: "local_a", name: "A idle unread", status: "idle")
        session(sessions, pid: me, id: "s-c", host: "local_c", name: "C busy", status: "busy")
        session(sessions, pid: me, id: "s-d", host: "local_d", name: "D idle read", status: "idle")
        chat(desk, "local_a", title: "A", edge: 5000, focused: 1000)
        chat(desk, "local_b", title: "B no process", edge: 6000, focused: 1000)
        chat(desk, "local_c", title: "C", edge: 5000, focused: 1000)
        chat(desk, "local_d", title: "D", edge: 1000, focused: 5000)
        chat(desk, "local_z", title: "Z archived", edge: 9000, focused: 1000, archived: true)
        write(log([batch(seq: 1, [(unreadKey, unreadValue(["local_a", "local_b", "local_c", "local_z"]))])]),
              to: ldb.appendingPathComponent("000003.log"))

        let store = SessionStore(sessionsDir: sessions, desktopDir: desk, leveldbDir: ldb, defaults: defaults)
        store.poll()
        let done = Set(store.done.map(\.id))
        expect(done == ["s-a", "local_b"], "done = unread idle chats, with and without a process (got \(done))")
        expect(store.busy.map(\.id) == ["s-c"], "an unread busy chat shows as working only")
        expect(store.done.first?.id == "local_b", "newest finish first")
        expect(store.sessions.first { $0.id == "local_b" }?.name == "B no process", "a chat with no process keeps its title")
        expect(!done.contains("local_z"), "archived chats are skipped")

        // Two processes on one desktop chat show once, under the chat's title, most urgent first.
        session(sessions, pid: me, id: "s-a2", host: "local_a", name: "a side process", status: "idle")
        store.poll()
        expect(store.sessions.filter { $0.hostSessionId == "local_a" }.count == 1, "one entry per desktop chat")
        expect(store.sessions.first { $0.hostSessionId == "local_a" }?.name == "A", "uses the sidebar title")
        session(sessions, pid: me, id: "s-a2", host: "local_a", name: "a side process", status: "busy")
        store.poll()
        expect(store.busy.map(\.id).contains("s-a2") && store.done.allSatisfy { $0.hostSessionId != "local_a" },
               "a busy process wins over an idle one")
        try? FileManager.default.removeItem(at: sessions.appendingPathComponent("s-a2.json"))
        store.poll()

        // A chat with no turn time uses its last activity for the card's time.
        writeJSON(["title": "Old", "lastActivityAt": 4000.0, "lastFocusedAt": 1000.0],
                  to: desk.appendingPathComponent("acct/org/local_old.json"))
        write(log([batch(seq: 1, [(unreadKey, unreadValue(["local_a", "local_b", "local_old"]))])]),
              to: ldb.appendingPathComponent("000003.log"), bump: 1)
        store.poll()
        expect(store.finished["local_old"] == Date(timeIntervalSince1970: 4), "falls back to last activity time")
        try? FileManager.default.removeItem(at: desk.appendingPathComponent("acct/org/local_old.json"))

        // Read in the app: A leaves the list.
        write(log([batch(seq: 1, [(unreadKey, unreadValue(["local_a", "local_b"]))]),
                   batch(seq: 2, [(unreadKey, unreadValue(["local_b"]))])]),
              to: ldb.appendingPathComponent("000003.log"), bump: 2)
        store.poll()
        expect(Set(store.done.map(\.id)) == ["local_b"], "a chat read in the app clears")

        // Dismissed in the pet: hidden until that chat has a new turn.
        store.dismissFinished("local_b")
        store.poll()
        expect(store.done.isEmpty, "dismissed chat stays hidden")
        chat(desk, "local_b", title: "B no process", edge: 7000, focused: 1000, bump: 3)
        store.poll()
        expect(store.done.map(\.id) == ["local_b"], "a new turn brings a dismissed chat back")

        // Log compacted away (new empty log): the last list is kept.
        try? FileManager.default.removeItem(at: ldb.appendingPathComponent("000003.log"))
        write(log([batch(seq: 9, [(Array("unrelated".utf8), [1, 65])])]), to: ldb.appendingPathComponent("000005.log"), bump: 4)
        store.poll()
        expect(store.done.map(\.id) == ["local_b"], "keeps the last list after compaction")

        // A fresh pet (restart) remembers the list too.
        let again = SessionStore(sessionsDir: sessions, desktopDir: desk, leveldbDir: ldb, defaults: defaults)
        again.poll()
        expect(again.done.map(\.id) == ["local_b"], "restart restores the last list")

        // Half-written session file: keep the last good copy.
        write(Array("{\"pid\": 1, \"sess".utf8), to: sessions.appendingPathComponent("s-c.json"), bump: 5)
        store.poll()
        expect(store.busy.map(\.id) == ["s-c"], "a half-written file keeps its last good state")

        // Process gone: the session drops off.
        session(sessions, pid: dead, id: "s-c", host: "local_c", name: "C busy", status: "busy")
        store.poll()
        expect(store.busy.isEmpty, "dead processes are dropped")
    }

    static func testFallback(_ root: URL, _ defaults: UserDefaults) {
        defaults.removeObject(forKey: "lastUnreadIds")
        let sessions = root.appendingPathComponent("sessions"), desk = root.appendingPathComponent("desk")
        session(sessions, pid: me, id: "s-e", host: "local_e", name: "E", status: "idle")
        chat(desk, "local_e", title: "E", edge: 5000, focused: 1000)
        chat(desk, "local_f", title: "F", edge: 1000, focused: 5000)
        let store = SessionStore(sessionsDir: sessions, desktopDir: desk,
                                 leveldbDir: root.appendingPathComponent("missing"), defaults: defaults)
        store.poll()
        expect(Set(store.done.map(\.id)) == ["s-e"], "without the app's list, a turn after the last open counts as unread")
        chat(desk, "local_e", title: "E", edge: 5000, focused: 6000, bump: 2)
        store.poll()
        expect(store.done.isEmpty, "opening the chat clears it")
    }

    static func testTerminal(_ root: URL, _ defaults: UserDefaults) {
        defaults.removeObject(forKey: "lastUnreadIds")
        let sessions = root.appendingPathComponent("sessions")
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let store = SessionStore(sessionsDir: sessions, desktopDir: root.appendingPathComponent("none"),
                                 leveldbDir: root.appendingPathComponent("none"), defaults: defaults)
        store.now = { clock }
        session(sessions, pid: me, id: "t", host: nil, name: "Terminal", status: "busy")
        store.poll()
        expect(store.busy.count == 1, "busy terminal session")
        session(sessions, pid: me, id: "t", host: nil, name: "Terminal", status: "idle")
        clock += 1; store.poll()
        expect(store.done.isEmpty, "not done during the debounce")
        clock += 1; session(sessions, pid: me, id: "t", host: nil, name: "Terminal", status: "busy"); store.poll()
        clock += 1; session(sessions, pid: me, id: "t", host: nil, name: "Terminal", status: "idle"); store.poll()
        clock += 2; store.poll()
        expect(store.done.isEmpty, "a flicker restarts the debounce")
        clock += 2; store.poll()
        expect(store.done.map(\.id) == ["t"], "done after the debounce")
        clock += SessionStore.doneExpiry + 1; store.poll()
        expect(store.done.isEmpty, "expires after 30 minutes")
        let fresh = SessionStore(sessionsDir: sessions, desktopDir: root.appendingPathComponent("none"),
                                 leveldbDir: root.appendingPathComponent("none"), defaults: defaults)
        fresh.poll()
        expect(fresh.done.isEmpty && fresh.idleCount == 1, "an idle session at startup isn't done")
    }

    static func testSpriteSheet(_ root: URL) {
        let w = 8 * 192, h = 9 * 208
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return expect(false, "context") }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        func fill(row: Int, cols: Int) {
            for c in 0..<cols {   // CGContext's origin is bottom-left; sheet rows count from the top
                ctx.fill(CGRect(x: c * 192 + 40, y: h - (row + 1) * 208 + 40, width: 100, height: 100))
            }
        }
        fill(row: 0, cols: 3)
        fill(row: 7, cols: 2)
        let url = root.appendingPathComponent("sheet.png")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return expect(false, "write png")
        }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        guard let sheet = SpriteSheet(url: url) else { return expect(false, "loads the sheet") }
        expect(sheet.frames(for: .idle).count == 3, "idle row has 3 frames")
        expect(sheet.frames(for: .running).count == 2, "running row has 2 frames")
        expect(sheet.frames(for: .waiting).count == 3, "an empty row falls back to idle")
        expect(SpriteSheet(url: root.appendingPathComponent("nope.png")) == nil, "a missing file fails cleanly")
    }
}

@main
enum ClaudePetMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            IconRenderer.writeIconset(to: args[i + 1])
            return
        }
        if args.contains("--self-test") { exit(SelfTest.run()) }
        if args.contains("--dump") {
            // Prints what the pet sees right now, for debugging.
            let store = SessionStore()
            store.poll()
            print("app unread list:", store.unread.ids.map { "\($0.count) chats" } ?? "not found (using timestamps)")
            for (label, list) in [("needs you", store.waiting), ("working", store.busy), ("done", store.done)] {
                for s in list { print("\(label): \(s.name)\(s.pid == 0 ? " (no process)" : "")") }
            }
            print("idle:", store.idleCount)
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
