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
        "Answer this question clearly and concisely based on the image. Focus on key points only. Context: $text"
    } else {
        "Analyze the image and provide a brief, direct answer."
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
        temperature = 0.7
    } | ConvertTo-Json -Depth 10
} else {
    $prompt = @"
Provide a clear, concise answer. Be direct and focus on the key points without unnecessary elaboration.

Question: $text
"@
    
    $body = @{
        model = "llama-3.3-70b-versatile"
        messages = @(@{ role = "user"; content = $prompt })
        temperature = 0.7
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