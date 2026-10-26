# Contributing to Claude Pet

Thanks for helping! Claude Pet is deliberately small: one Swift file, one build script, no dependencies.

## Build and test

```bash
./build.sh            # compiles, runs the self-tests, builds ClaudePet.app
open ClaudePet.app
```

`build.sh` fails if any self-test fails. To see what the pet sees on your machine:

```bash
ClaudePet.app/Contents/MacOS/ClaudePet --dump
```

To try states without real sessions, see "Testing without real sessions" in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Where things live

Everything is in [`Sources/main.swift`](Sources/main.swift). [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md) has a code tour.

## Good first contributions

- **A new built-in pet.** Add a `BuiltinPet` (four rows of pixels on top of the head, plus colors) and list it in `BuiltinPet.all`.
- **A sprite-sheet pet** for the gallery: see [docs/PETS.md](docs/PETS.md) and share it with the "Share a pet" issue form.
- Anything labelled [good first issue](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).

## Pull requests

- Keep changes focused, and match the style of the code around them.
- If you change how sessions are read, add a check to `SelfTest`.
- Include a screenshot or GIF for anything visual.
- Never commit real session data, chat titles, or anything from your own `~/.claude` or `~/Library` folders.
