#Requires AutoHotkey v2
#SingleInstance Force

; ── Path constants ────────────────────────────────────────────────────────────
global g_TempText      := A_Temp "\gemini_input.txt"
global g_TempImage     := A_Temp "\gemini_image.jpg"
global g_Output        := A_Temp "\gemini_output.txt"
global g_Lock          := A_Temp "\gemini.lock"
global g_ErrorLog      := A_Temp "\gemini_error.log"
global g_PsScript      := A_ScriptDir "\gemini.ps1"
global g_ToolTipTimer  := 0
global g_MouseWatcher  := 0
global g_MouseOriginX  := 0
global g_MouseOriginY  := 0

; ── Hotkeys ───────────────────────────────────────────────────────────────────
;   Ctrl+2  →  casual   3-5 sentence natural answer  → clipboard only (no tooltip)
;   Ctrl+3  →  single   one letter e.g. "B"          → clipboard + tooltip
;   Ctrl+4  →  multi    letters e.g. "A, C"          → clipboard + tooltip
;   Ctrl+5  →  wiki     full encyclopedia answer     → clipboard + tooltip
;   Ctrl+9  →  re-read  last result, no API call     → clipboard + tooltip

^2:: RunQuery("casual")
^3:: RunQuery("single")
^4:: RunQuery("multi")
^5:: RunQuery("wiki")

^9:: {
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

    ; 2. Snapshot whatever is already in the clipboard before we do anything
    existingClip := A_Clipboard

    ; 3. Try to grab selected text by sending Ctrl+C
    A_Clipboard := ""
    Send("^c")
    gotSelection := ClipWait(0.5)

    if gotSelection && A_Clipboard != "" {
        clipText := A_Clipboard
    } else {
        A_Clipboard := existingClip
        clipText := existingClip
    }

    ; 4. Write text to input file (may be empty if clipboard had an image)
    if FileExist(g_TempText)
        FileDelete(g_TempText)
    if clipText != ""
        FileAppend(clipText, g_TempText)

    ; 5. Capture clipboard image synchronously
    ;    -STA flag is REQUIRED: Clipboard COM calls need Single-Threaded Apartment.
    ;    Without -STA, GetImage() always returns null even when an image is present.
    imageCapCmd := 'powershell -STA -NoProfile -WindowStyle Hidden -Command "'
        . 'Add-Type -AssemblyName System.Windows.Forms; '
        . 'Add-Type -AssemblyName System.Drawing; '
        . '$img = [System.Windows.Forms.Clipboard]::GetImage(); '
        . 'if ($img -ne $null) { '
        .     '$bmp = New-Object System.Drawing.Bitmap($img); '
        .     '$bmp.Save(\"' . g_TempImage . '\", [System.Drawing.Imaging.ImageFormat]::Jpeg); '
        .     '$bmp.Dispose(); $img.Dispose() '
        . '}"'
    RunWait(imageCapCmd, , "Hide")

    ; 6. Run PS backend — blocks until exit
    psCmd := 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden'
        . ' -File "' . g_PsScript . '" -Mode ' . mode
    exitCode := RunWait(psCmd, , "Hide")

    ; 7. Orphaned lock cleanup
    if FileExist(g_Lock)
        FileDelete(g_Lock)

    ; 8. Read result
    result := ""
    if FileExist(g_Output)
        result := Trim(FileRead(g_Output))

    ; 9. Error handling
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

    ; 10. Success
    A_Clipboard := result
    SoundBeep(1500, 120)

    if (mode = "casual" || mode = "wiki") {
        ; Casual/wiki: clipboard only, no tooltip — answer is long, just Ctrl+V it
        return
    }

    ShowToolTip(result, 5000)
}

; ── ToolTip with auto-clear + mouse-move dismiss ──────────────────────────────
ShowToolTip(text, durationMs := 5000) {
    global g_ToolTipTimer, g_MouseWatcher, g_MouseOriginX, g_MouseOriginY

    display := StrLen(text) > 800 ? SubStr(text, 1, 797) . "..." : text
    ToolTip(display)

    if g_ToolTipTimer {
        SetTimer(g_ToolTipTimer, 0)
        g_ToolTipTimer := 0
    }
    if g_MouseWatcher {
        SetTimer(g_MouseWatcher, 0)
        g_MouseWatcher := 0
    }

    MouseGetPos(&g_MouseOriginX, &g_MouseOriginY)

    g_ToolTipTimer := ClearToolTip
    SetTimer(g_ToolTipTimer, -durationMs)

    g_MouseWatcher := WatchMouse
    SetTimer(g_MouseWatcher, 100)
}

WatchMouse() {
    global g_MouseWatcher, g_MouseOriginX, g_MouseOriginY
    MouseGetPos(&cx, &cy)
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
