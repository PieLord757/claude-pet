# Claude Pet

A floating pixel pet for macOS that keeps an eye on your [Claude Code](https://claude.com/claude-code) sessions, so you don't have to keep switching back to check on them.

It stays on top of every app and every desktop, and shows at a glance:

- **Needs you**: a session is blocked on a permission prompt or a question (the pet hops and shows a `!`)
- **Working**: Claude is busy in that session (the pet puts on goggles and sparks fly)
- **Done**: a session just finished its turn (the pet cheers, then the row stays until you click it)
- **Idle**: open sessions that aren't doing anything (hidden by default, shown under `+N idle`)

It works with sessions in the Claude desktop app's Code tab and with `claude` in a terminal.

> Unofficial fan project. Not affiliated with or endorsed by Anthropic.

## Install

### Option 1: download the release

1. Download `ClaudePet.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `ClaudePet.app` to `/Applications` (or anywhere you like).
3. The app is not notarized, so macOS blocks the first launch. Either right-click the app → **Open** → **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/ClaudePet.app
   ```

### Option 2: build it yourself (recommended if you want to tinker)

Requirements:

- macOS 14 (Sonoma) or newer
- Xcode **or** just the Command Line Tools (`xcode-select --install`)

```bash
git clone https://github.com/PieLord757/claude-pet.git
cd claude-pet
./build.sh
open ClaudePet.app
```

`build.sh` compiles the single Swift file in `Sources/main.swift` with `swiftc` and wraps it in an app bundle. There is no Xcode project and there are no dependencies. If your default SDK is newer than your compiler (common after a Command Line Tools update), the script automatically falls back to an older installed SDK that works.

## Opening and closing the pet

- **Open:** press `⌘ Space` and type **ClaudePet** (Spotlight), or open it from Launchpad or Finder → Applications.
- **Close:** right-click the pet → **Close Pet**.
- **Start at login:** System Settings → General → Login Items → **+** → pick `ClaudePet.app`.

### `/pet` inside Claude Code (optional)

Add a slash command so you can open or close the pet from any Claude Code chat, in the desktop app or the terminal:

```bash
mkdir -p ~/.claude/commands && cp extras/pet.md ~/.claude/commands/pet.md
```

Then type `/pet` to open it or `/pet close` to close it. (The Claude desktop app's own menus can't be extended by outside apps, so a slash command is the closest thing to a built-in button.)

## Using it

| Action | What happens |
| --- | --- |
| Click the pet | Show or hide the session list |
| Drag the pet | Move it anywhere; the position is remembered |
| Click a group header (`WORKING 3`) | Collapse or expand that group |
| `⌃` in the card footer | Collapse the list to a small summary pill |
| Click a **Needs you** row | Opens Claude's "Sessions Waiting for You" view |
| Click a **Working** row | Brings the Claude app to the front |
| Click a **Done** row | Clears it and brings Claude to the front |
| **New** | Starts a new Claude Code session in the desktop app |
| `+N idle` | Show or hide idle sessions |
| Right-click the pet or card | Show/hide sessions, clear finished, reset position, **Close Pet** |

Clicking a row can't jump straight to that specific chat yet, because the desktop app doesn't expose a link for it. PRs welcome if you find one.

## How it works

Every running Claude Code session writes a small status file to `~/.claude/sessions/<pid>.json` with its name and a `status` of `busy`, `waiting` or `idle` (plus a `waitingFor` reason when blocked). Claude Pet polls that folder once a second:

- Only `*.json` files are read. Nothing else in `~/.claude` is touched.
- A session counts only while its process is alive (`kill(pid, 0)`).
- A busy → idle change shows as **Done** after a 3 second debounce, and expires after 30 minutes.
- The app makes no network requests and writes nothing outside its own preferences (`defaults read local.claudepet`).

⚠️ That status file is an internal Claude Code detail, not a documented API. A future Claude Code update could change it and break the pet. If that happens, the parsing lives in `SessionStore.poll()`.

## Hacking on it

Everything is in [`Sources/main.swift`](Sources/main.swift), roughly in this order:

- **`SessionStore`** reads the session files and tracks done/waiting/working.
- **`PixelPet`** holds the sprite. Each row is a 16-character string and each character is a palette color (`K` outline, `O` body, `W` hair, `G` goggles, `.` transparent). Change the strings or the palette to make your own pet. Moods: `sleepy`, `idle`, `working`, `waiting`, `cheering`.
- **`PetCanvas`** draws the sprite and its animations (bobbing, blinking, sparks, `z`s).
- **`PetView` / `SessionCard` / `SessionGroup` / `SummaryPill`** are the SwiftUI UI.
- **`AppDelegate`** creates the always-on-top, all-spaces, non-activating floating panel.

### Testing without real sessions

Point the pet at a fake folder with `CLAUDE_PET_SESSIONS_DIR` and write status files by hand. The `pid` must be a live process, so a `sleep` works:

```bash
mkdir -p /tmp/fake-sessions
sleep 600 &
echo "{\"pid\":$!,\"sessionId\":\"demo\",\"name\":\"Demo session\",\"status\":\"busy\"}" > /tmp/fake-sessions/$!.json
open --env CLAUDE_PET_SESSIONS_DIR=/tmp/fake-sessions ClaudePet.app
```

Then change `"busy"` to `"waiting"` (add `"waitingFor":"approve Bash"`) or `"idle"` to see the other states. Quit the real pet first (right-click → Quit) so the two don't overlap.

## Ideas for forks

- Different pets, or a picker (cat, crab, ghost...)
- Sound or a macOS notification when something needs you
- Per-session deep links once the desktop app supports them
- A menu bar mode

## License

[MIT](LICENSE)
