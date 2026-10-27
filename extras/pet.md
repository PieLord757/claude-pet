---
description: Open or close Claude Pet, or open its settings (/pet, /pet close, /pet settings)
argument-hint: "[close|settings]"
allowed-tools: Bash(open -a ClaudePet), Bash(pkill -x ClaudePet), Bash(/Applications/ClaudePet.app/Contents/MacOS/ClaudePet --settings)
---

The user ran `/pet $ARGUMENTS`.

- If the argument is `close`, run `pkill -x ClaudePet` and reply only: "Claude Pet closed."
- If the argument is `settings`, run `/Applications/ClaudePet.app/Contents/MacOS/ClaudePet --settings` and reply only: "Opened Claude Pet settings."
- Otherwise run `open -a ClaudePet` and reply only: "Claude Pet is open." If that fails because the app isn't installed, say to install it with `brew install --cask pielord757/tap/claude-pet`.
