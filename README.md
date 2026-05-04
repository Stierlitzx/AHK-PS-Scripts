# web_back

A lightweight AI assistant hotkey utility for Windows. Captures clipboard text and/or screenshot, sends it to the Groq API, and returns the answer instantly via tooltip and clipboard.

## Files

```
src/
  assistant.ahk           -- Hotkey definitions and IPC orchestration (AHK v2)
  auto_sender.ahk         -- Auxiliary automation script
  gemini.ps1              -- Groq API backend (PowerShell)
  groq_api_key.local.txt  -- Your personal API key (git-ignored)
  groq_api_key.txt        -- Placeholder template (committed, not used if placeholder)
```

## Hotkeys

| Hotkey | Mode | Input | Output |
|---|---|---|---|
| `Ctrl+2` | Casual | clipboard text and/or image | 3-5 sentence natural answer (clipboard only, no tooltip) |
| `Ctrl+3` | Single-choice | clipboard text and/or image | One letter: `B` (clipboard + tooltip) |
| `Ctrl+4` | Multiple-choice | clipboard text and/or image | Letter list: `A, C` (clipboard + tooltip) |
| `Ctrl+5` | Wiki | clipboard text and/or image | Full encyclopedia answer (clipboard only, no tooltip) |
| `Ctrl+9` | Re-read | -- | Shows + copies last saved answer, no API call (clipboard + tooltip) |

All modes copy the result to the clipboard. Modes 3, 4, and 9 also display it as a tooltip for 5 seconds.

## Setup

### 1. Install AutoHotkey v2

Download from https://www.autohotkey.com — install the v2 branch.

### 2. Add your Groq API key

Create `src/groq_api_key.local.txt` and paste your key (no quotes, no spaces):

```
gsk_yourkeyhere
```

Get a free key at https://console.groq.com

### 3. Fix encoding on non-English Windows (required for Russian/Kazakh locale) (optional if you use English locale)

PowerShell defaults to the regional code page (e.g. Windows-1251) when reading
.ps1 files without a BOM. Run this once after placing gemini.ps1 in the src folder:

```powershell
$p = "C:\path\to\src\gemini.ps1"
[IO.File]::WriteAllText($p, (Get-Content $p -Raw), [Text.UTF8Encoding]::new($true))
```

### 4. Run

Double-click `src/assistant.ahk`. The AHK tray icon confirms it is active.

## How it works

```
Ctrl+Number   ->  AHK reads existing clipboard text  ->  %TEMP%\gemini_input.txt
              ->  AHK captures clipboard image (RunWait, synchronous)
                       ->  %TEMP%\gemini_image.jpg
              ->  AHK launches gemini.ps1 (RunWait, blocks until exit)
                       ->  PS writes gemini.lock   (acquired)
                       ->  PS calls Groq API
                       ->  PS writes gemini_output.txt
                       ->  PS deletes gemini.lock  (released)
              ->  AHK reads output
              ->  result copied to clipboard + shown in tooltip for 5 s
```

The lock file is a write-complete sentinel. AHK reads the output only after
`RunWait` returns, by which point all PS file handles are closed. No sleep-based
polling anywhere in the flow.

## Models

| Input | Model | Notes |
|---|---|---|
| Text only | `llama-3.3-70b-versatile` | Best free text model on Groq as of 2026 |
| Image (with or without text) | `meta-llama/llama-4-scout-17b-16e-instruct` | Only production vision model on Groq |

## API key lookup order

1. `GROQ_API_KEY` environment variable
2. `src/groq_api_key.local.txt` (recommended, git-ignored)
3. `src/groq_api_key.txt` (skipped if it still contains the placeholder text)
