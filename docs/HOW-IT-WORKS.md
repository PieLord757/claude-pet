# How it works

Every running Claude Code session writes a small status file to `~/.claude/sessions/<pid>.json` with its name and a `status` of `busy`, `waiting` or `idle` (plus a `waitingFor` reason when blocked). Claude Pet polls that folder once a second:

- Only `*.json` files are read there. Nothing else in `~/.claude` is touched.
- A session counts only while its process is alive (`kill(pid, 0)`).
- A busy → idle change shows as **Done** after a 3 second debounce, and expires after 30 minutes.
- For chats in the Claude desktop app, **Done** mirrors the app's own unread list (the sidebar's blue dots), so a card clears as soon as you read that chat in Claude, and unread chats show up even if their process has stopped or the pet was just started. The pet reads that list from the app's local storage log (`~/Library/Application Support/Claude/Local Storage/leveldb/*.log`, key `epitaxy-unread-v1`) and chat titles and times from `~/Library/Application Support/Claude/claude-code-sessions/`. If the list isn't available it falls back to comparing each chat's last turn with when you last opened it. Terminal sessions have no desktop chat, so they're done when the pet sees them finish, and clear after 30 minutes or with right-click → Clear Finished.
- The app makes no network requests. It writes only its own preferences (`defaults read local.claudepet`) and the pets you import.

⚠️ These files are internal details of Claude Code and the desktop app, not documented APIs. A future update could change them and break the pet. If that happens, the parsing lives in `SessionStore`, `DesktopChats` and `DesktopUnread`.


## Code tour

Everything is in [`Sources/main.swift`](Sources/main.swift):

- **`SessionStore`** reads the session files and decides waiting/working/done. **`DesktopChats`** and **`DesktopUnread`** read the desktop app's chat files and unread list; **`LevelDBLog`** is a small reader for LevelDB write-ahead logs.
- **`BuiltinPet` / `PixelPet` / `PetCanvas`** are the built-in pixel pets. Each row is a 16-character string and each character is a palette color (`K` outline, `O` body, `W` hair, `.` transparent). Add a `BuiltinPet` with its own top rows and colors, then list it in `BuiltinPet.all`.
- **`SpriteSheet` / `PetLibrary` / `PetFigure`** load, import and animate Codex-format pets.
- **`PetView` / `ControlPill` / `SessionStack` / `SessionToast`** are the SwiftUI interface.
- **`AppDelegate`** creates the always-on-top, all-desktops panel and sizes it to its content.
- **`IconRenderer`** draws the app icon from the Sprout sprite (`ClaudePet --render-icon <dir>`).

### Tests and debugging

- `./build.sh` runs the self-tests after compiling (`ClaudePet --self-test`). They check the unread logic, the LevelDB log reader, terminal-session timing, and sprite sheets against temporary folders, and the build fails if any check fails.
- `ClaudePet.app/Contents/MacOS/ClaudePet --dump` prints what the pet sees right now (needs you / working / done), which is handy when the pet disagrees with the sidebar.

### Testing without real sessions

Point the pet at a fake folder with `CLAUDE_PET_SESSIONS_DIR`. The `pid` must be a live process, so a `sleep` works:

```bash
mkdir -p /tmp/fake-sessions
sleep 600 &
echo "{\"pid\":$!,\"sessionId\":\"demo\",\"name\":\"Demo session\",\"status\":\"busy\"}" > /tmp/fake-sessions/$!.json
open --env CLAUDE_PET_SESSIONS_DIR=/tmp/fake-sessions ClaudePet.app
```

Change `"busy"` to `"waiting"` (add `"waitingFor":"approve Bash"`) or to `"idle"` to see the other states. Only one Claude Pet runs at a time, so close the real one first.

