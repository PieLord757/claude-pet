---
description: Open or close the Claude Pet floating window (/pet, /pet close)
argument-hint: "[close]"
allowed-tools: Bash(open -a ClaudePet), Bash(pkill -x ClaudePet)
---

The user ran `/pet $ARGUMENTS`.

- If the argument is `close`, run `pkill -x ClaudePet` and reply only: "Claude Pet closed."
- Otherwise run `open -a ClaudePet` and reply only: "Claude Pet is open." If that fails because the app isn't installed, say to install it from https://github.com/PieLord757/claude-pet.
