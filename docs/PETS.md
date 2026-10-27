# Making a pet

Claude Pet plays any pet drawn in the **Codex pet format**, so a pet made for Codex works here too, and the other way around.

To try yours: right-click the pet → **Import Pet…** and pick the folder or the sprite sheet image.

## The quick way: draw it as text

You don't need a drawing app. Every built-in and gallery pet shares one 16×16 body; you design the four rows on top (hair, ears, horns...) and pick colors. Copy [`pets/pip/design.json`](../pets/pip/design.json):

```json
{
  "id": "pip",
  "displayName": "Pip",
  "description": "A sunny little chick with a stubborn tuft.",
  "author": "you",
  "top": [
    ".......KK.......",
    "......KWWK......",
    ".....KWWWWK.....",
    "....KKWWWWKK...."
  ],
  "colors": { "O": "#F6C445", "o": "#D9A322", "W": "#FFE68A", "R": "#FF9E80", "M": "#E8762C" }
}
```

Each `top` row is exactly 16 characters; `.` is transparent. Color letters: `K` outline, `O` body, `o` body shade, `W`/`w` hair, `R` cheeks, `M` mouth, `Y` sparks, `G`/`g` goggles. Then:

```bash
ClaudePet.app/Contents/MacOS/ClaudePet --make-pet my-pet/design.json my-pet/
```

That writes `pet.json`, `spritesheet.png` (every animation, already drawn) and `preview.png`. Import it to try it.

## Adding your pet to the gallery

1. Put your pet folder in [`pets/`](../pets) (keep `design.json` if you used one).
2. Add an entry to [`pets/index.json`](../pets/index.json).
3. Open a pull request with a screenshot. Once it's merged, everyone can install it from **Browse Pets**.

Not comfortable with pull requests? [Share it in an issue](../../../issues/new?template=new-pet.yml) instead.

## Sprite sheet format

- A PNG or WebP atlas, **8 columns × 9 rows** of **192×208** cells (1536×1872 total), transparent background.
- Each row is one animation. Empty cells at the end of a row are skipped:

| Row | Animation | Claude Pet plays it when |
| --- | --- | --- |
| 0 | idle | nothing needs attention (slowed down when everything is quiet) |
| 1 | running right | you drag the pet to the right |
| 2 | running left | you drag the pet to the left |
| 3 | waving | (not used yet) |
| 4 | jumping | a session just finished |
| 5 | failed | (not used yet) |
| 6 | waiting | a session needs you |
| 7 | running | Claude is working |
| 8 | review | (not used yet) |

Any row that's empty falls back to idle, so a sheet with just an idle row still works.

A pet folder looks like this:

```text
my-pet/
├── pet.json
└── spritesheet.webp
```

```json
{
  "id": "my-pet",
  "displayName": "My Pet",
  "description": "One short sentence.",
  "spritesheetPath": "spritesheet.webp"
}
```


## Tips

- Keep the pet inside each 192×208 cell with a little margin; frames are shown at about half size.
- Pixel art reads best when every frame is drawn on the same grid.
- Start with the idle row. Add waiting (row 6) and running (row 7) next, since those show up most.

## Built-in pets

The three built-in pets are drawn in code from 16×16 character grids. See `BuiltinPet` in [`Sources/main.swift`](../Sources/main.swift): each one is four rows on top of the head (hair, ears, an antenna...) plus a few colors. Adding one is a good first pull request.
