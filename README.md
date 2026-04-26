# web_back

AutoHotkey + PowerShell helper for FastAPI backend study that sends clipboard text/image to Groq LLM models and copies the response back to your clipboard.

## What it does

- `Ctrl + Numpad2` (`src/casual.ahk`): returns a short, casual FastAPI backend explanation.
- `Ctrl + Numpad3` (`src/concise.ahk`): returns a concise, direct FastAPI backend explanation.
- `Ctrl + '` (`src/auto_sender.ahk`): types clipboard text directly into the active window.
- Supports:
  - text from clipboard
  - image from clipboard (if present)
- Writes the response to `%TEMP%\\gemini_output.txt`, then copies it to clipboard.

## Files

- `src/casual.ahk` -> hotkey `Ctrl+Numpad2`, calls `src/gemini.ps1`
- `src/concise.ahk` -> hotkey `Ctrl+Numpad3`, calls `src/gemini2.ps1`
- `src/auto_sender.ahk` -> hotkey `Ctrl+'`, sends clipboard text directly
- `src/gemini.ps1` -> casual backend-study response style
- `src/gemini2.ps1` -> concise backend-study response style

## Requirements

- Windows
- AutoHotkey v2
- PowerShell (Windows PowerShell 5.1+ or PowerShell 7+)
- Internet access
- Groq API key

## Setup

1. Install AutoHotkey v2.
2. Put these files in one folder.
3. Open `src/gemini.ps1` and `src/gemini2.ps1` and set your Groq API key.
4. No path edits needed: `src/casual.ahk` and `src/concise.ahk` now auto-resolve PowerShell scripts from their own folder (`A_ScriptDir`).
5. Run the `.ahk` script(s) (double-click or run through AutoHotkey).

## How to use

1. Copy question text to clipboard.
2. Optional: copy an image to clipboard.
3. Press one of the hotkeys:
   - `Ctrl + Numpad2` for casual backend-study explanation
   - `Ctrl + Numpad3` for concise backend-study explanation
   - `Ctrl + '` to type clipboard text directly
4. Wait for beep:
   - high short beep = success
   - low longer beep = failed/empty output
5. Paste clipboard anywhere to get the model answer.

## Temp files used

The scripts read/write these files in `%TEMP%`:

- `gemini_input.txt`
- `gemini_image.png`
- `gemini_output.txt`

## Troubleshooting

- No output: verify API key, internet connection, and script paths.
- Image not detected: make sure an actual image is in clipboard.
- PowerShell blocked: keep `-ExecutionPolicy Bypass` in `RunWait` call.
- Still failing: check `%TEMP%\\gemini_output.txt` for error text.
