# gemini.ps1 -- Unified Groq API backend
param(
    [ValidateSet("casual","single","multi","wiki")]
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
}

# -- Course context -----------------------------------------------------------
$courseContext = @"
Context: the questions come from a university course called IT Audit and Controls. It covers IT audit and governance, COBIT and ISO 27001, risk management, IT general and application controls, network and cloud audits, regulatory compliance, data analytics in auditing, cybersecurity and incident management, business continuity and disaster recovery, emerging technologies, and auditing Agile and DevOps. Answer the way an IT auditor (CISA / ISACA body of knowledge) would, and pick the option that standard audit reasoning supports most directly, even if another option is arguable in practice. Do not invent facts that are not in the question.
Exam reasoning rules:
Auditor role: the auditor is independent, assesses controls, gathers evidence and recommends; management designs, implements and owns controls and accepts risk. An auditor should not implement or fix controls in the area being audited. When asked what the auditor should do FIRST, prefer understanding the business, objectives and risks (or reviewing prior findings) before testing. Audits are risk-based: focus effort on the highest-risk areas.
Audit process: planning, fieldwork (testing), reporting, follow-up. Evidence must be sufficient, reliable and relevant; independent, third-party, system-generated and auditor-observed evidence is more reliable than management statements or inquiry. A finding has condition, criteria, cause, effect and recommendation; fix the root cause, not the symptom. Test of design checks a control could work; test of operating effectiveness checks it worked over the period.
Audit risk = inherent risk x control risk x detection risk; the auditor controls only detection risk. Risk = likelihood x impact. Risk responses: avoid, mitigate (reduce), transfer (e.g. insurance), accept. Residual risk is what remains after controls and must be within risk appetite, which is set by senior management or the board.
Controls: preventive (stop it before it happens) is generally preferred over detective (find it after) and corrective (fix it). Compensating controls reduce risk when the primary control is missing, e.g. supervisory review when segregation of duties is impossible in a small team. Automated controls are more reliable than manual ones. Segregation of duties separates authorization, custody, recording and reconciliation; developers must not move their own code to production.
IT general controls (ITGC): access to programs and data (provisioning, periodic access review, prompt removal of leavers, privileged access), program change management (request, approval, testing, separate migration to production), program development, and computer operations (backups, job scheduling, incident handling). ITGCs support the reliability of application controls. Application controls: input (validation, edit checks, completeness), processing (reconciliations, control totals, batch totals), output (review, distribution).
Frameworks: COBIT 2019 separates governance (EDM: Evaluate, Direct, Monitor; board responsibility) from management (APO, BAI, DSS, MEA); it has 40 objectives and capability levels 0-5. COBIT 5 had 5 principles and 37 processes. ISO/IEC 27001 defines a certifiable ISMS (clauses 4-10, Plan-Do-Check-Act) with Annex A controls: 93 controls in 4 themes (organizational, people, physical, technological) in the 2022 version, 114 controls in 14 domains in 2013. ISO 27002 gives control guidance; the Statement of Applicability lists chosen controls and justifies exclusions. NIST CSF 2.0 functions: Govern, Identify, Protect, Detect, Respond, Recover. The three lines model: operational management, risk and compliance functions, internal audit.
Cloud and networks: under the shared responsibility model the customer always remains accountable for its data, identities and access; the provider secures the underlying infrastructure (more customer responsibility in IaaS, less in SaaS). Rely on SOC reports: SOC 1 covers controls relevant to financial reporting, SOC 2 covers the Trust Services Criteria (security, availability, processing integrity, confidentiality, privacy); Type I covers design at a point in time, Type II covers operating effectiveness over a period. Review complementary user entity controls. Network audit checks firewall rule reviews, segmentation, least privilege, encryption in transit, patching and logging.
Regulation: SOX section 404 requires management assessment of internal control over financial reporting and external auditor attestation; ITGCs are central to it. GDPR: lawful basis, data minimization, rights of data subjects, breach notification to the authority within 72 hours, fines up to 4% of global turnover or 20 million euro. PCI DSS protects cardholder data; HIPAA protects health data. Compliance is not the same as security.
Data analytics and CAATs: tools such as ACL, IDEA or scripts allow testing 100% of a population instead of a sample, finding duplicates, gaps, outliers and segregation conflicts; Benford's law detects fabricated numbers; continuous auditing is done by audit, continuous monitoring by management. Ensure data completeness and integrity before analysis.
Incident management (NIST SP 800-61): preparation; detection and analysis; containment, eradication and recovery; post-incident activity (lessons learned). Contain first, preserve evidence and chain of custody, then eradicate. Logs must be protected from tampering and reviewed.
Business continuity and DR: the business impact analysis (BIA) comes first and defines critical processes, RTO (maximum downtime), RPO (maximum data loss, drives backup frequency) and MTD. Hot site is fastest and most expensive, cold site cheapest and slowest. Test types from least to most disruptive: checklist, tabletop/walkthrough, simulation, parallel, full interruption. An untested plan is not reliable; plans must be updated after changes. Keep backups offsite and test restoration.
Emerging technologies (AI, RPA, blockchain, IoT, big data): the auditor evaluates governance, data quality, model risk, bias, explainability, access control and change management of the new technology; the technology does not remove the need for controls.
Agile and DevOps: controls move into the pipeline: version control, mandatory peer review and approvals before merge, automated testing and security scanning in CI/CD, infrastructure as code, separated deployment permissions and automatically logged evidence. Speed does not remove the need for change management or segregation of duties; automated controls with audit trails can satisfy them.
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

if (-not $hasImage -and ($Mode -eq "single" -or $Mode -eq "multi")) {
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
