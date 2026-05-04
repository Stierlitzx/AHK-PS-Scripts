# gemini.ps1 -- Unified Groq API backend
# Save with UTF-8 BOM on Russian/Kazakh Windows (run once after editing):
#   $p = ".\gemini.ps1"; [IO.File]::WriteAllText($p,(gc $p -Raw),[Text.UTF8Encoding]::new($true))
param(
    [ValidateSet("casual","single","multi","wiki")]
    [string]$Mode = "casual"
)

# -- Paths --------------------------------------------------------------------
$lockPath   = "$env:TEMP\gemini.lock"
$outputPath = "$env:TEMP\gemini_output.txt"
$errorLog   = "$env:TEMP\gemini_error.log"
$inputPath  = "$env:TEMP\gemini_input.txt"
$imagePath  = "$env:TEMP\gemini_image.png"

if (Test-Path $errorLog) { Remove-Item $errorLog -Force }

# -- Lock ---------------------------------------------------------------------
[string]$PID | Out-File $lockPath -Encoding UTF8 -NoNewline

# -- Helpers ------------------------------------------------------------------
function Finish([string]$content, [int]$code = 0) {
    $content | Out-File $outputPath -Encoding UTF8
    if (Test-Path $lockPath) { Remove-Item $lockPath -Force }
    exit $code
}

function FinishError([string]$msg) {
    $msg | Out-File $errorLog -Encoding UTF8
    Finish "Error: $msg" 1
}

# -- API key: env var > .local.txt > .txt -------------------------------------
$apiKey = $env:GROQ_API_KEY
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $p = Join-Path $PSScriptRoot "groq_api_key.local.txt"
    if (Test-Path $p) { $apiKey = (Get-Content $p -Raw).Trim() }
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $p = Join-Path $PSScriptRoot "groq_api_key.txt"
    if (Test-Path $p) {
        $c = (Get-Content $p -Raw).Trim()
        if ($c -notmatch '^(?i)put your (q|g)roq api here$') { $apiKey = $c }
    }
}
if ([string]::IsNullOrWhiteSpace($apiKey)) {
    FinishError "Missing API key. Set GROQ_API_KEY or create groq_api_key.local.txt next to the script."
}

# -- Read inputs --------------------------------------------------------------
$text = ""
if (Test-Path $inputPath) {
    $text = (Get-Content $inputPath -Raw -Encoding UTF8).Trim()
    if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) + "..." }
}

$hasImage = Test-Path $imagePath

if ($text -eq "" -and -not $hasImage) {
    FinishError "No input: clipboard was empty and no image was captured."
}

# -- Models -------------------------------------------------------------------
#   Vision (image present): llama-4-scout  — only free vision model on Groq
#   Text only:              llama-3.3-70b-versatile — best free text model on Groq
$textModel   = "llama-3.3-70b-versatile"
$visionModel = "meta-llama/llama-4-scout-17b-16e-instruct"

# -- Prompts ------------------------------------------------------------------
switch ($Mode) {
    "casual" {
        $systemPrompt = "Answer like a knowledgeable student explaining to a friend. Write 3-5 sentences in a natural, conversational tone. Be clear and complete but keep it easy to read. No bullet points, no headers, just flowing text."
        $temperature  = 0.7
        $max_tokens   = 300
        $prefill      = ""
    }
    "single" {
        $systemPrompt = "You are taking a multiple choice exam. The question has EXACTLY ONE correct answer. Output the single letter of the correct answer and nothing else. No words, no punctuation, no explanation."
        $temperature  = 0.0
        $max_tokens   = 2
        $prefill      = "Answer: "
    }
    "multi" {
        $systemPrompt = "You are taking a multiple choice exam. One or more answers may be correct. Output ONLY the correct letters separated by a comma and space. No words, no explanation. Example outputs: A / A, C / A, B, D"
        $temperature  = 0.0
        $max_tokens   = 15
        $prefill      = "Answer: "
    }
    "wiki" {
        $systemPrompt = "You are a knowledgeable encyclopedia assistant. Give a thorough, well-structured explanation covering the key concepts, context, and details. Write in clear prose paragraphs (no bullet points). Aim for 6-10 sentences that fully explain the topic."
        $temperature  = 0.5
        $max_tokens   = 600
        $prefill      = ""
    }
}

# -- Build messages -----------------------------------------------------------
if ($hasImage) {
    $model = $visionModel

    $userPrompt = switch ($Mode) {
        "casual" { if ($text -ne "") { $text } else { "Explain what this shows in a few clear sentences." } }
        "single" { if ($text -ne "") { "Context: $text`nPick the single correct answer letter." } else { "Pick the single correct answer letter from the question in the image." } }
        "multi"  { if ($text -ne "") { "Context: $text`nPick all correct answer letters." } else { "Pick all correct answer letters from the question in the image." } }
        "wiki"   { if ($text -ne "") { $text } else { "Give a thorough explanation of what this image shows." } }
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    } catch {
        FinishError "Could not read image file: $_"
    }
    $base64Image = [Convert]::ToBase64String($bytes)

    $userContent = @(
        @{ type = "text";      text      = $userPrompt },
        @{ type = "image_url"; image_url = @{ url = "data:image/png;base64,$base64Image" } }
    )

    if ($prefill -ne "") {
        $messages = @(
            @{ role = "system";    content = $systemPrompt },
            @{ role = "user";      content = $userContent },
            @{ role = "assistant"; content = $prefill }
        )
    } else {
        $messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user";   content = $userContent }
        )
    }

} else {
    $model = $textModel

    if ($prefill -ne "") {
        $messages = @(
            @{ role = "system";    content = $systemPrompt },
            @{ role = "user";      content = $text },
            @{ role = "assistant"; content = $prefill }
        )
    } else {
        $messages = @(
            @{ role = "system"; content = $systemPrompt },
            @{ role = "user";   content = $text }
        )
    }
}

# -- Request body -------------------------------------------------------------
$body = @{
    model       = $model
    messages    = $messages
    temperature = $temperature
    max_tokens  = $max_tokens
} | ConvertTo-Json -Depth 10

# -- API call -----------------------------------------------------------------
try {
    $response = Invoke-RestMethod `
        -Method POST `
        -Uri "https://api.groq.com/openai/v1/chat/completions" `
        -Headers @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type"  = "application/json"
        } `
        -Body $body `
        -ErrorAction Stop

    if (-not $response.choices -or $response.choices.Count -eq 0) {
        FinishError "API returned no choices. Mode=$Mode Model=$model Raw: $($response | ConvertTo-Json -Depth 5)"
    }

    $raw = $response.choices[0].message.content.Trim()

    if ($Mode -eq "single") {
        $letter = ([regex]::Match($raw, '[A-Za-z]')).Value.ToUpper()
        if ($letter -eq "") { FinishError "Model gave no letter. Raw: $raw" }
        Finish $letter 0
    }

    if ($Mode -eq "multi") {
        $letters = [regex]::Matches($raw, '[A-Za-z]') |
                   ForEach-Object { $_.Value.ToUpper() } |
                   Select-Object -Unique
        if ($letters.Count -eq 0) { FinishError "Model gave no letters. Raw: $raw" }
        Finish ($letters -join ', ') 0
    }

    Finish $raw 0

} catch {
    $detail = "Mode=$Mode Model=$model | $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream)
            $detail += " | HTTP body: " + $reader.ReadToEnd()
            $reader.Dispose()
        } catch {}
    }
    FinishError $detail
}