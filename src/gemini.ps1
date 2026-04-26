$apiKey = $env:GROQ_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    "Error: Set GROQ_API_KEY environment variable." | Out-File "$env:TEMP\gemini_output.txt" -Encoding UTF8
    exit 1
}
$text = if (Test-Path "$env:TEMP\gemini_input.txt") { 
    Get-Content "$env:TEMP\gemini_input.txt" -Raw
} else { 
    "" 
}
if ($text.Length -gt 1000) { 
    $text = $text.Substring(0,1000) + "…" 
}
$imagePath = "$env:TEMP\gemini_image.png"
$hasImage = Test-Path $imagePath
if ($hasImage) {
    $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    $base64Image = [Convert]::ToBase64String($bytes)
    
    $imagePrompt = if ($text -ne "") {
        "Read the question and answer it like you're a student texting a quick response. Keep it casual and simple - use everyday words. Maybe add 'I think' or 'basically' naturally if it fits, but don't force it. Write 2-3 sentences in one flow, no breaks. Sound human, not like Wikipedia. Context: $text"
    } else {
        "Read the question and answer like you're texting someone. Simple, casual language. 2-3 sentences, no breaks between them. Be a real person."
    }
    
    $content = @(
        @{ 
            type = "text"
            text = $imagePrompt
        },
        @{ 
            type = "image_url"
            image_url = @{ 
                url = "data:image/png;base64,$base64Image" 
            } 
        }
    )
    
    $body = @{
        model = "meta-llama/llama-4-scout-17b-16e-instruct"
        messages = @(@{
            role = "user"
            content = $content
        })
        temperature = 0.9
    } | ConvertTo-Json -Depth 10
} else {
    $prompt = @"
You're a student casually answering a quiz question. Write like you're texting - keep it simple and natural. Don't overthink it. Use everyday language, maybe throw in words like 'basically', 'I think', 'pretty much', but don't overdo it. Write 2-3 sentences in ONE paragraph, no line breaks. Sound like a real person, not a textbook.
$text
"@
    
    $body = @{
        model = "llama-3.3-70b-versatile"
        messages = @(@{ role = "user"; content = $prompt })
        temperature = 0.9
    } | ConvertTo-Json -Depth 10 -Compress
}
try {
    $response = Invoke-RestMethod -Method POST -Uri "https://api.groq.com/openai/v1/chat/completions" -Headers @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    } -Body $body -ErrorAction Stop
    
    if ($response.choices) {
        $output = $response.choices[0].message.content.Trim()
        $output | Out-File "$env:TEMP\gemini_output.txt" -Encoding UTF8
    }
} catch {
    "Error: $_" | Out-File "$env:TEMP\gemini_output.txt" -Encoding UTF8
    exit 1
}