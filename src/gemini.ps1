# gemini.ps1 -- Unified Groq API backend
param(
    [ValidateSet("casual","single","multi","wiki","code")]
    [string]$Mode = "casual"
)

# -- Paths --------------------------------------------------------------------
$lockPath   = "$env:TEMP\gemini.lock"
$outputPath = "$env:TEMP\gemini_output.txt"
$errorLog   = "$env:TEMP\gemini_error.log"
$inputPath  = "$env:TEMP\gemini_input.txt"
$imagePath  = "$env:TEMP\gemini_image.jpg"

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

# Read a key file robustly: strips all BOMs, decodes as UTF-8,
# removes every non-printable character, then trims whitespace.
function Read-KeyFile([string]$path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    } catch {
        return ""
    }
    # Strip UTF-8 BOM (EF BB BF)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    # Strip UTF-16 LE BOM (FF FE)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $bytes = $bytes[2..($bytes.Length - 1)]
    }
    # Strip UTF-16 BE BOM (FE FF)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $bytes = $bytes[2..($bytes.Length - 1)]
    }
    $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Remove ALL control chars, zero-width chars, BOM remnants, and any whitespace
    $cleaned = $decoded -replace '[\x00-\x1F\x7F\u00A0\u200B\u200C\u200D\u2028\u2029\uFEFF]', ''
    return $cleaned.Trim()
}

# -- API key: env var > .local.txt > .txt -------------------------------------
$apiKey = ""

if (-not [string]::IsNullOrWhiteSpace($env:GROQ_API_KEY)) {
    $apiKey = $env:GROQ_API_KEY.Trim()
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $p = Join-Path $PSScriptRoot "groq_api_key.local.txt"
    if (Test-Path $p) { $apiKey = Read-KeyFile $p }
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $p = Join-Path $PSScriptRoot "groq_api_key.txt"
    if (Test-Path $p) {
        $c = Read-KeyFile $p
        if ($c -notmatch '^(?i)put your (g|q)roq api( key)? here$') { $apiKey = $c }
    }
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    FinishError "Missing API key. Set GROQ_API_KEY or create groq_api_key.local.txt next to the script."
}

# Groq keys look like:  gsk_xxxxxxxxxxxxxxxxxxxx
# Only keep characters valid in a Groq key: letters, digits, underscore, hyphen
$apiKey = ($apiKey -replace '[^a-zA-Z0-9_\-]', '').Trim()

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    FinishError "API key is empty after cleanup. Open groq_api_key.txt in Notepad, select all, delete, retype/paste the key, and save as UTF-8 without BOM."
}

# Sanity-check: Groq keys start with "gsk_"
if (-not $apiKey.StartsWith("gsk_")) {
    FinishError "API key does not start with 'gsk_'. Current value starts with: '$($apiKey.Substring(0, [Math]::Min(6,$apiKey.Length)))'. Re-copy the key from console.groq.com."
}

# -- Read inputs --------------------------------------------------------------
$text = ""
if (Test-Path $inputPath) {
    $text = (Get-Content $inputPath -Raw -Encoding UTF8).Trim()
    if ($text.Length -gt 1500) { $text = $text.Substring(0, 1500) + "..." }
}

$hasImage = Test-Path $imagePath

if ($text -eq "" -and -not $hasImage) {
    FinishError "No input: clipboard was empty and no image was captured. Copy some text or an image first, then press the hotkey."
}

# -- Models -------------------------------------------------------------------
#   Verified 2026-10-08 against https://console.groq.com/docs/rate-limits
#   Vision: qwen3.8-27b (preview); text: gpt-oss-120b (production).
#   Both are available on the Free Plan. Use medium reasoning effort and
#   reserve extra completion tokens for reasoning before the final answer.
$textModel   = "openai/gpt-oss-120b"
$visionModel = "qwen/qwen3.8-27b"
$reasoningEffort = "medium"

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
        $max_tokens   = 128
        $prefill      = "Answer: "
    }
    "multi" {
        $systemPrompt = "You are taking a multiple choice exam. One or more answers may be correct. Output ONLY the correct letters separated by a comma and space. No words, no explanation. Example outputs: A / A, C / A, B, D"
        $temperature  = 0.0
        $max_tokens   = 128
        $prefill      = "Answer: "
    }
    "wiki" {
        $systemPrompt = "You are a knowledgeable encyclopedia assistant. Give a thorough, well-structured explanation covering the key concepts, context, and details. Write in clear prose paragraphs (no bullet points). Aim for 6-10 sentences that fully explain the topic."
        $temperature  = 0.5
        $max_tokens   = 600
        $prefill      = ""
    }
    "code" {
        $systemPrompt = "You are a programming assistant for a Parallel Computing course. Write a complete, working solution in the language the task requires: Python if it mentions multiprocessing, threading, concurrent.futures, mpi4py or numpy; C if it mentions OpenMP pragmas, MPI, pthreads, CUDA or kernels; if no language is stated, default to Python unless the task clearly needs OpenMP/MPI/CUDA, then use C. If the task already contains code or a snippet, keep its language, complete it and fix it. A bare problem statement with no code means: write the full program from scratch. Output ONLY the raw code, no markdown fences, no explanations, no comments beyond what the code itself needs to compile and run."
        $temperature  = 0.2
        $max_tokens   = 1024
        $prefill      = ""
    }
}

# -- Course context -----------------------------------------------------------
$courseContext = @"
Context: the questions come from a university course called Parallel Computing (SDU). Answer the way the course frames the topic, and pick the option that course reasoning supports most directly, even if another option is arguable in real life. Do not invent facts that are not in the question. For wording like "most likely" or "probably", choose the simplest explanation.
Course ideas:
Architectures: multi-core CPUs use shared memory; distributed clusters use distributed memory with separate address spaces per node; GPUs are massively data-parallel accelerators with their own device memory and host-device transfers.
Programming models: OpenMP is for shared-memory parallelism on CPUs (threads, pragmas such as parallel for, critical sections, barriers). MPI is for distributed memory (explicit message passing between processes: point-to-point send/recv, collectives like broadcast, scatter, gather, reduce, barrier). CUDA is for GPUs (kernels executed by many threads organized in grids and blocks; watch memory coalescing and host-device transfer cost).
Parallelism types: task parallelism means different tasks run concurrently; data parallelism means the same operation runs on different data partitions. Know basic terminology: speedup = serial time / parallel time; efficiency = speedup / number of processors; strong scaling fixes problem size while adding processors; weak scaling grows the problem with the processor count.
Algorithm design: decompose the problem (data/domain decomposition vs task/functional decomposition), then map work to processors. Prefer coarse granularity when communication is expensive; fine granularity only when overhead stays low. Balance computation against communication cost.
Correctness challenges: shared-memory programs suffer race conditions when threads access shared data without synchronization; use locks, critical sections, atomics and barriers. Message-passing programs suffer deadlocks and communication mismatch (for example blocking send/recv in the wrong order); use matching sends and receives, non-blocking calls or collectives, and overlap communication with computation where possible.
Load balancing: uneven work distribution leaves processors idle and kills speedup. Use static distribution for regular workloads and dynamic scheduling or work stealing for irregular ones.
Performance laws: Amdahl's law says the serial fraction of a program limits maximum speedup no matter how many processors are added. Gustafson's law says scaled speedup is possible when the problem grows with the machine. Always account for overhead: communication, synchronization, and load imbalance.
Optimization: minimize communication volume and synchronization points, maximize data locality, avoid false sharing, keep load balanced, and measure before optimizing (speedup, efficiency, scalability).
"@

$systemPrompt = "$courseContext`n`n$systemPrompt"

# -- Build messages -----------------------------------------------------------
if ($hasImage) {
    $model = $visionModel

    $userPrompt = switch ($Mode) {
        "casual" { if ($text -ne "") { $text } else { "Explain what this shows in a few clear sentences." } }
        "single" { if ($text -ne "") { "Context: $text`nPick the single correct answer letter." } else { "Pick the single correct answer letter from the question in the image." } }
        "multi"  { if ($text -ne "") { "Context: $text`nPick all correct answer letters." } else { "Pick all correct answer letters from the question in the image." } }
        "wiki"   { if ($text -ne "") { $text } else { "Give a thorough explanation of what this image shows." } }
        "code"   { if ($text -ne "") { "Task: $text`nWrite the complete solution code for the task in the image." } else { "Write the complete solution code for the task in the image." } }
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($imagePath)
    } catch {
        FinishError "Could not read image file: $_"
    }
    $base64Image = [Convert]::ToBase64String($bytes)

    $userContent = @(
        @{ type = "text";      text      = $userPrompt },
        @{ type = "image_url"; image_url = @{ url = "data:image/jpeg;base64,$base64Image" } }
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

if (-not $hasImage -and ($Mode -eq "single" -or $Mode -eq "multi" -or $Mode -eq "code")) {
    $max_tokens = 1024
}

# -- Request body -------------------------------------------------------------
$body = @{
    model            = $model
    messages         = $messages
    temperature      = $temperature
    max_completion_tokens = $max_tokens + 1024
    reasoning_effort = $reasoningEffort
}
# Qwen otherwise includes <think> text in content, which breaks letter modes.
# GPT-OSS uses include_reasoning instead of reasoning_format.
if ($hasImage) {
    $body.reasoning_format = "hidden"
} else {
    $body.include_reasoning = $false
}
$body = $body | ConvertTo-Json -Depth 10

# -- API call -----------------------------------------------------------------
try {
    $httpResponse = Invoke-WebRequest -UseBasicParsing `
        -Method POST `
        -Uri "https://api.groq.com/openai/v1/chat/completions" `
        -Headers @{
            "Authorization" = "Bearer $apiKey"
            "Content-Type"  = "application/json; charset=utf-8"
        } `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -ErrorAction Stop

    # Windows PowerShell 5.1 can misdecode JSON when no response charset is set.
    # Decode the original bytes as UTF-8 before parsing the JSON.
    $httpResponse.RawContentStream.Position = 0
    $responseReader = [System.IO.StreamReader]::new($httpResponse.RawContentStream, [System.Text.Encoding]::UTF8)
    try {
        $response = $responseReader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $responseReader.Dispose()
    }

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

    if ($Mode -eq "code") {
        # Model sometimes wraps code in ``` fences despite the prompt — strip them.
        $raw = $raw -replace '(?m)^```[a-zA-Z0-9+\-#]*\s*\r?\n', '' -replace '(?m)^```\s*$', ''
        $raw = $raw.Trim()
        Finish $raw 0
    }

    Finish $raw 0

} catch {
    $detail = "Mode=$Mode Model=$model | $($_.Exception.Message)"
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream.CanSeek) { $stream.Position = 0 }
            $reader = [System.IO.StreamReader]::new($stream)
            $detail += " | HTTP body: " + $reader.ReadToEnd()
            $reader.Dispose()
        } catch {}
    }
    FinishError $detail
}
