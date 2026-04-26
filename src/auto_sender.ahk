; Alternative version - Types clipboard text directly
^':: {
    try {
        ; Get clipboard text
        clipText := A_Clipboard
        
        ; Check if clipboard contains text
        if (clipText != "") {
            ; Send the text directly (like typing it)
            SendText(clipText)
        } else {
            ; If clipboard is empty, send Ctrl+V anyway
            Send("^v")
        }
    }
    catch as err {
        MsgBox("Error: " err.Message, "AutoHotkey Error", 0x10)
    }
}