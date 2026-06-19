---
name: mac-ocr-cli
description: 'macOS OCR via the local `mac_ocr_cli` tool: read text from images, screenshots, window captures, or the system clipboard. Use when the user wants to extract text from a PNG/JPG/HEIC, OCR a screenshot, recognize text on the screen, or query content visible in a window. Backed by Apple Vision, supports Chinese/English/Japanese by default.'
---

# mac_ocr_cli Skill

`mac_ocr_cli` is a local OCR tool that wraps Apple Vision. It runs entirely on the user's machine — no network, no API key. Use it whenever the user wants to read text out of an image, screenshot, window, or the clipboard.

## When to use this skill

| User says (paraphrased) | What to do |
|---|---|
| "OCR this image" / "extract text from <file>" | `mac_ocr_cli <file> --json` |
| "What does the screenshot say?" (file attached) | `mac_ocr_cli <file>` |
| "Capture my screen and read the text" | `mac_ocr_cli --screen` |
| "Read the text in <window name>" | `mac_ocr_cli --window "Safari"` |
| "OCR this region" (with x,y,w,h) | `mac_ocr_cli --region X Y W H` |
| "Read text from my clipboard" / "I just took a screenshot" | `mac_ocr_cli --from-clipboard` |
| "Copy my screen to the clipboard" | `mac_ocr_cli --clipboard` |
| "Find <keyword> in these images" | `mac_ocr_cli <files...> -k "keyword"` |
| "OCR all images in a directory" | `mac_ocr_cli --dir <path>` |
| "Pipe these paths in" | `find ... \| mac_ocr_cli -` |

If the user has not provided an image and has not asked to capture something, **ask first** which input source they want. Don't guess.

## Output conventions

- **Default (`--text`)**: human-readable. Use for showing the user a quick summary.
- **`--json`**: structured `{ imagePath, lines: [{index, text, confidence, boundingBox}] }`. Use for piping to `jq` or further processing.
- **`--output <path>`**: write to file, force JSON. The stdout still prints — combine with `--quiet` to silence stdout.

## Common flags

| Flag | Effect |
|---|---|
| `-l, --lang <list>` | BCP-47 codes, comma-separated. Default: `zh-Hans,zh-Hant,en-US` |
| `--cjk` | Shorthand for `zh-Hans,zh-Hant,zh-HK,en-US` |
| `--level fast` | Faster but less accurate |
| `--no-correction` | Disable Vision's auto language correction |
| `--json` / `--text` | Output format (default text) |
| `-o, --output <path>` | Write JSON to file |
| `-q, --quiet` | Suppress stdout/stderr chatter (errors still go to stderr) |
| `-k, --keyword <kw>` | Filter and rank lines by keyword (single-image only) |

## Capturing from the screen

Screen/window/region capture needs **Screen Recording permission** (System Settings → Privacy & Security → Screen Recording). The first run will prompt; if the user has not granted it, suggest the privacy setting. Clipboard read/write does **not** need any extra permission.

## Decision rules

- **One image mentioned** → single-file mode, no batching needed.
- **Directory of images** → `--dir <path>` (recursive, filters by extension, sorted).
- **Mixed / large list** → pipe via stdin: `find . -name "*.png" | mac_ocr_cli -`.
- **User wants structured data** → `--json`. **User just wants to read it** → default text.
- **User wants to grep or find a specific string** → `-k "string"`. Note: `-k` is single-image only; for batch, post-process `--json` output with `jq`.
- **User just took a screenshot with `Cmd+Shift+Ctrl+4`** → `--from-clipboard` (it's the fastest path).

## Examples

```bash
# Single image, default text output
mac_ocr_cli photo.png

# JSON for downstream tooling
mac_ocr_cli shot.png --json

# Batch: directory
mac_ocr_cli --dir ~/Desktop --json -o all.json

# Batch with progress to stderr
mac_ocr_cli --dir ~/shots
# stderr: [1/5] a.png  ok (3 lines) ...
#        完成: 5/5 ok, 0 failed, 用时 1.2s

# Quiet mode for scripts
mac_ocr_cli --quiet --json --dir ./shots -o out.json

# Search inside a single image
mac_ocr_cli page.png -k "订单号"

# Screen capture
mac_ocr_cli --screen
mac_ocr_cli --window "Safari" --save-screenshot ~/Desktop/shot.png
mac_ocr_cli --region 0 0 800 600

# Clipboard
mac_ocr_cli --clipboard                    # capture → pasteboard
mac_ocr_cli --from-clipboard               # pasteboard → OCR
```

## Bounding-box coordinate system

`boundingBox: {x, y, width, height}` from `--json` is **normalized `[0,1]` with origin at the image's bottom-left** (Vision's default). To convert to screen pixels for a click:

1. Multiply by image width / height.
2. Flip Y: `screenY = imageHeight - (ocrY + ocrHeight)`.
3. Multiply by `NSScreen.main?.backingScaleFactor` if hitting a Retina display.

## Failure modes

- **Empty result** — the image has no recognizable text, or `recognitionLevel = .fast` missed it. Try `--level accurate` (default) or crop to a tighter region.
- **Garbled text** — the language hint is wrong. Pass `-l <lang>` matching the script (e.g., `ja-JP` for Japanese, `ko-KR` for Korean).
- **Capture returns nothing** — Screen Recording permission not granted. Direct the user to System Settings → Privacy & Security → Screen Recording.
- **"图片解码失败"** — file is not a supported image or is corrupted.
- **Batch exit code 2** — at least one image failed. Other images still completed; the JSON output includes per-item `status: "ok" | "failed"`.

## Reference

- Repo: https://github.com/whiter001/mac_ocr_cli
- Binary location after install: `~/.local/bin/mac_ocr_cli` (or wherever `--prefix` pointed)
- Skill location: `~/.claude/skills/mac-ocr-cli/SKILL.md`
