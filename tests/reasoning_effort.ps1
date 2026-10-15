$ErrorActionPreference = "Stop"

$backendPath = Join-Path (Split-Path $PSScriptRoot -Parent) "src\gemini.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $backendPath, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Out-String)
}

$modeParameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq "Mode" }
$modeAttribute = $modeParameter.Attributes | Where-Object { $_.TypeName.FullName -eq "ValidateSet" }
$modes = @($modeAttribute.PositionalArguments | ForEach-Object { $_.Value })
if ($modes.Count -eq 0) { throw "No supported modes found." }

$source = [System.IO.File]::ReadAllText($backendPath)
$assignments = [regex]::Matches($source, '\$reasoningEffort\s*=\s*"([^"]+)"')
if ($assignments.Count -ne 1 -or $assignments[0].Groups[1].Value -ne "medium") {
    throw "Expected exactly one shared medium reasoning-effort setting."
}

# Execute only request construction: exclude key lookup, IPC, and the API call.
$start = $source.IndexOf("# -- Models")
$end = $source.IndexOf("# -- API call")
if ($start -lt 0 -or $end -le $start) { throw "Request-construction boundaries not found." }
$buildRequest = [scriptblock]::Create($source.Substring($start, $end - $start) + "`n`$body")

$fixturePath = Join-Path ([System.IO.Path]::GetTempPath()) ("assistant-test-" + [guid]::NewGuid() + ".jpg")
$scenarios = @(
    @{ Name = "text-only"; Text = "Explain this topic."; HasImage = $false },
    @{ Name = "image-only"; Text = ""; HasImage = $true },
    @{ Name = "text-and-image"; Text = "Explain this topic."; HasImage = $true }
)
$passed = 0

try {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new(1, 1)
    try {
        $bitmap.Save($fixturePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {
        $bitmap.Dispose()
    }

    foreach ($queryMode in $modes) {
        foreach ($scenario in $scenarios) {
            $json = & {
                param($builder, $selectedMode, $inputScenario, $imageFixture)
                $Mode = $selectedMode
                $text = $inputScenario.Text
                $hasImage = $inputScenario.HasImage
                $imagePath = $imageFixture
                & $builder
            } $buildRequest $queryMode $scenario $fixturePath
            $request = $json | ConvertFrom-Json
            $label = "$queryMode / $($scenario.Name)"

            if ($request.reasoning_effort -ne "medium") { throw "$label : reasoning must be medium." }
            if ([string]::IsNullOrWhiteSpace($request.messages[0].content)) { throw "$label : missing system prompt." }

            if ($scenario.HasImage) {
                if ($request.model -ne "qwen/qwen3.8-27b") { throw "$label : incorrect vision model." }
                if ($request.reasoning_format -ne "hidden") { throw "$label : reasoning is not hidden." }
                if ($request.messages[1].content[1].image_url.url -notlike "data:image/jpeg;base64,*") {
                    throw "$label : missing image payload."
                }
            } else {
                if ($request.model -ne "openai/gpt-oss-120b") { throw "$label : incorrect text model." }
                if ($request.include_reasoning -ne $false) { throw "$label : reasoning is not hidden." }
                if ($request.messages[1].content -ne $scenario.Text) { throw "$label : text input changed." }
            }

            $expectedTokens = switch ($queryMode) {
                "casual" { 1324 }
                "wiki" { 1624 }
                "code" { 2048 }
                default { if ($scenario.HasImage) { 1152 } else { 2048 } }
            }
            if ($request.max_completion_tokens -ne $expectedTokens) { throw "$label : token budget changed." }
            if ($queryMode -in @("single", "multi") -and $request.messages[-1].content -ne "Answer: ") {
                throw "$label : choice prefill changed."
            }

            Write-Output "PASS: $label"
            $passed++
        }
    }
} finally {
    if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Force }
}

Write-Output "Passed $passed request-construction cases; no API calls made."