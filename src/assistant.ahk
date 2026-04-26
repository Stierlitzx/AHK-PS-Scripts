#Requires AutoHotkey v2
#SingleInstance Force

; ── Path constants ────────────────────────────────────────────────────────────
global g_TempText      := A_Temp "\gemini_input.txt"
global g_TempImage     := A_Temp "\gemini_image.png"
global g_Output        := A_Temp "\gemini_output.txt"
global g_Lock          := A_Temp "\gemini.lock"
global g_ErrorLog      := A_Temp "\gemini_error.log"
global g_PsScript      := A_ScriptDir "\gemini.ps1"
global g_ToolTipTimer  := 0
global g_MouseWatcher  := 0
global g_MouseOriginX  := 0
global g_MouseOriginY  := 0

; ── Hotkeys ───────────────────────────────────────────────────────────────────
;   Ctrl+Numpad2  →  casual       short natural answer    → clipboard + tooltip
;   Ctrl+Numpad3  →  single       one letter (e.g. "B")  → clipboard + tooltip
;   Ctrl+Numpad4  →  multi        letters (e.g. "A, C")  → clipboard + tooltip
;   Ctrl+Numpad9  →  re-read      last result, no API call

^Numpad2:: RunQuery("casual")
^Numpad3:: RunQuery("single")
^Numpad4:: RunQuery("multi")

^Numpad9:: {
    global g_Output
    if !FileExist(g_Output) {
        ShowToolTip("No previous result found.", 3000)
        return
    }
    result := Trim(FileRead(g_Output))
    if StrLen(result) = 0 {
        ShowToolTip("Last output file is empty.", 3000)
        return
    }
    A_Clipboard := result
    ShowToolTip(result, 5000)
    SoundBeep(1000, 80)
}

; ── Core dispatcher ───────────────────────────────────────────────────────────
RunQuery(mode) {
    global g_TempText, g_TempImage, g_Output, g_Lock, g_ErrorLog, g_PsScript

    ; 1. Clean stale files
    for path in [g_TempImage, g_Output, g_Lock] {
        if FileExist(path)
            FileDelete(path)
    }

    ; 2. Write clipboard text to input file
    clipText := A_Clipboard
    if FileExist(g_TempText)
        FileDelete(g_TempText)
    if clipText != ""
        FileAppend(clipText, g_TempText)

    ; 3. Capture clipboard image synchronously — RunWait closes all handles before PS reads
    imageCapCmd := 'powershell -NoProfile -WindowStyle Hidden -Command "'
        . 'Add-Type -AssemblyName System.Windows.Forms; '
        . 'Add-Type -AssemblyName System.Drawing; '
        . '$img = [System.Windows.Forms.Clipboard]::GetImage(); '
        . 'if ($img -ne $null) { '
        .     '$img.Save(\"' . g_TempImage . '\", [System.Drawing.Imaging.ImageFormat]::Png); '
        .     '$img.Dispose() '
        . '}"'
    RunWait(imageCapCmd, , "Hide")

    ; 4. Run PS backend — blocks until exit
    psCmd := 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden'
        . ' -File "' . g_PsScript . '" -Mode ' . mode
    exitCode := RunWait(psCmd, , "Hide")

    ; 5. Orphaned lock cleanup
    if FileExist(g_Lock)
        FileDelete(g_Lock)

    ; 6. Read result
    result := ""
    if FileExist(g_Output)
        result := Trim(FileRead(g_Output))

    ; 7. Error — show tooltip, do not touch clipboard
    if StrLen(result) = 0 {
        errDetail := ""
        if FileExist(g_ErrorLog)
            errDetail := "`n" . Trim(FileRead(g_ErrorLog))
        ShowToolTip("Error: empty response (exit " . exitCode . ")" . errDetail, 8000)
        SoundBeep(400, 300)
        return
    }

    if result ~= "^Error:" {
        ShowToolTip(result, 8000)
        SoundBeep(400, 300)
        return
    }

    ; 8. Success — copy + show for ALL modes
    A_Clipboard := result
    ShowToolTip(result, 5000)
    SoundBeep(1500, 120)
}

; ── ToolTip with auto-clear + mouse-move dismiss ──────────────────────────────
ShowToolTip(text, durationMs := 5000) {
    global g_ToolTipTimer, g_MouseWatcher, g_MouseOriginX, g_MouseOriginY

    display := StrLen(text) > 800 ? SubStr(text, 1, 797) . "..." : text
    ToolTip(display)

    ; Cancel existing auto-clear timer
    if g_ToolTipTimer {
        SetTimer(g_ToolTipTimer, 0)
        g_ToolTipTimer := 0
    }

    ; Cancel existing mouse watcher
    if g_MouseWatcher {
        SetTimer(g_MouseWatcher, 0)
        g_MouseWatcher := 0
    }

    ; Record mouse position at moment tooltip appears
    MouseGetPos(&g_MouseOriginX, &g_MouseOriginY)

    ; Schedule auto-clear after durationMs
    g_ToolTipTimer := ClearToolTip
    SetTimer(g_ToolTipTimer, -durationMs)

    ; Poll mouse every 100ms — clear tooltip the instant it moves
    g_MouseWatcher := WatchMouse
    SetTimer(g_MouseWatcher, 100)
}

; Fires every 100ms while a tooltip is visible
WatchMouse() {
    global g_MouseWatcher, g_MouseOriginX, g_MouseOriginY
    MouseGetPos(&cx, &cy)
    ; Dismiss if moved more than 10px in any direction (ignores tiny jitter)
    if (Abs(cx - g_MouseOriginX) > 10 || Abs(cy - g_MouseOriginY) > 10)
        ClearToolTip()
}

ClearToolTip() {
    global g_ToolTipTimer, g_MouseWatcher
    ToolTip()
    if g_ToolTipTimer {
        SetTimer(g_ToolTipTimer, 0)
        g_ToolTipTimer := 0
    }
    if g_MouseWatcher {
        SetTimer(g_MouseWatcher, 0)
        g_MouseWatcher := 0
    }
}
