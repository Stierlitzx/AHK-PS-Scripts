#Requires AutoHotkey v2

^Numpad2:: {
    tempTextPath := A_Temp "\gemini_input.txt"
    tempImagePath := A_Temp "\gemini_image.png"
    outputPath := A_Temp "\gemini_output.txt"
    
    if FileExist(tempImagePath)
        FileDelete(tempImagePath)
    if FileExist(outputPath)
        FileDelete(outputPath)
    
    if A_Clipboard != "" {
        if FileExist(tempTextPath)
            FileDelete(tempTextPath)
        FileAppend(A_Clipboard, tempTextPath)
    }
    
    Run('powershell -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Clipboard]::GetImage().Save(\"' . tempImagePath . '\", [System.Drawing.Imaging.ImageFormat]::Png)"', , "Hide")
    Sleep(500)
    psScriptPath := A_ScriptDir "\gemini.ps1"
    
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' . psScriptPath . '"', , "Hide")
    
    result := ""
    if FileExist(outputPath) {
        result := FileRead(outputPath)
    }
    
    if StrLen(Trim(result)) > 0 {
        A_Clipboard := Trim(result)
        SoundBeep(1500, 120)
    } else {
        SoundBeep(400, 300)
    }
}