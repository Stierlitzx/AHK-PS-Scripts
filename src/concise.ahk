#Requires AutoHotkey v2.0

; Global paths
global tempRecallPath := A_Temp "\backend_recall.txt"

; Ctrl + Numpad2: Single Choice
^Numpad2:: RunBackendAudit("single")

; Ctrl + Numpad3: Multiple Choice
^Numpad3:: RunBackendAudit("multiple")

; Ctrl + Numpad9: Recall last answer
^Numpad9:: {
    if FileExist(tempRecallPath) {
        savedAnswer := FileRead(tempRecallPath)
        ShowResult(savedAnswer, "RECALL")
    } else {
        ToolTip("No previous answer found.")
        SetTimer () => ToolTip(), -2000
    }
}

RunBackendAudit(mode) {
    tempTextPath := A_Temp "\gemini_input.txt"
    outputPath := A_Temp "\gemini_output.txt"
    
    if FileExist(outputPath)
        FileDelete(outputPath)

    ; Capture clipboard (the question)
    if A_Clipboard != "" {
        if FileExist(tempTextPath)
            FileDelete(tempTextPath)
        FileAppend(A_Clipboard, tempTextPath)
    }

    ; Execute the specific Backend logic script
    psScriptPath := A_ScriptDir "\fetch_backend_answer.ps1"
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . psScriptPath . '" -mode ' . mode, , "Hide")

    if FileExist(outputPath) {
        result := Trim(FileRead(outputPath))
        if (result != "") {
            ; Save for Ctrl+Numpad9
            if FileExist(tempRecallPath)
                FileDelete(tempRecallPath)
            FileAppend(result, tempRecallPath)
            
            ShowResult(result, mode)
            SoundBeep(1500, 120)
            return
        }
    }
    SoundBeep(400, 300)
}

ShowResult(text, mode) {
    ToolTip("Audit Result [" . mode . "]: " . text)
    ; Hide ToolTip after 7 seconds
    SetTimer () => ToolTip(), -7000
}