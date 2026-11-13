# IT Audit and Controls Assistant

An AI assistant hotkey utility for Windows, tuned for the university course **IT Audit and Controls**. Captures clipboard text and/or screenshot, sends it to the Groq API with a course-specific system prompt, and returns the answer instantly via tooltip and clipboard.

## Course

The course provides a comprehensive understanding of auditing principles and practices within information technology. Participants learn how to assess and evaluate IT systems, processes, and controls to ensure compliance with regulations, mitigate risks, and safeguard organizational assets. The aim is to equip learners to conduct effective IT audits, identify vulnerabilities and weaknesses in IT environments, and recommend strategies for enhancing security and compliance, contributing to robust IT governance frameworks that manage IT risks and protect against cyber threats.

| Week | Topic | Format |
|---|---|---|
| 1 | Introduction to IT Audit and Governance | Reading / Seminar discussion |
| 2 | IT Control Frameworks: COBIT, ISO 27001 | Lecture, Homework 1 |
| 3 | Risk Management in IT Audit | Lecture, case discussion |
| 4 | IT General Controls and Application Controls | Lecture, Homework 2 |
| 5 | Auditing Networks and Cloud Environments | Lecture, case study |
| 6 | Regulatory Compliance and IT Audit | Lecture, discussion |
| 7 | Midterm Review and Exam | Review and midterm exam |
| 8 | Data Analytics in IT Auditing | Lecture, practical exercise |
| 9 | Cybersecurity Controls and Incident Management | Lecture, scenario discussion |
| 10 | Auditing Business Continuity and Disaster Recovery | Lecture |
| 11 | Emerging Technologies and IT Auditing | Lecture, discussion |
| 12 | Auditing in Agile and DevOps Environments | Lecture, practical examples |
| 13-15 | Case Studies in IT Auditing | Research paper presentation |

### AI course prompt

`src/gemini.ps1` prepends a `$courseContext` block to every mode's system prompt. It tells the model to answer as an IT auditor following the CISA / ISACA body of knowledge and lists exam reasoning rules per topic: auditor independence and "what first" questions, audit process and evidence reliability, the audit risk model and risk responses, control types and segregation of duties, ITGCs and application controls, COBIT 2019 / ISO 27001:2022 / NIST CSF 2.0, cloud shared responsibility and SOC 1 / SOC 2 reports, SOX 404 / GDPR / PCI DSS, CAATs and data analytics, NIST SP 800-61 incident handling, BIA / RTO / RPO and DR test types, emerging technologies, and DevOps pipeline controls. Edit that block to add lecture-specific rules.

## Files

```
src/
  assistant.ahk           -- Hotkey definitions and IPC orchestration (AHK v2)
  auto_sender.ahk         -- Auxiliary automation script
  gemini.ps1              -- Groq API backend (PowerShell)
  groq_api_key.local.txt  -- Your personal API key (git-ignored)
  groq_api_key.txt        -- Placeholder template (committed, not used if placeholder)
```

## Hotkeys

| Hotkey | Mode | Input | Output |
|---|---|---|---|
| `Ctrl+2` | Casual | clipboard text and/or image | 3-5 sentence natural answer (clipboard only, no tooltip) |
| `Ctrl+3` | Single-choice | clipboard text and/or image | One letter: `B` (clipboard + tooltip) |
| `Ctrl+4` | Multiple-choice | clipboard text and/or image | Letter list: `A, C` (clipboard + tooltip) |
| `Ctrl+5` | Wiki | clipboard text and/or image | Full encyclopedia answer (clipboard only, no tooltip) |
| `Ctrl+9` | Re-read | -- | Shows + copies last saved answer, no API call (clipboard + tooltip) |

All modes copy the result to the clipboard. Modes 3, 4, and 9 also display it as a tooltip for 5 seconds.

## Setup

### 1. Install AutoHotkey v2

Download from https://www.autohotkey.com — install the v2 branch.

### 2. Add your Groq API key

Create `src/groq_api_key.local.txt` and paste your key (no quotes, no spaces):

```
gsk_yourkeyhere
```

Get a free key at https://console.groq.com

### 3. Fix encoding on non-English Windows (required for Russian/Kazakh locale) (optional if you use English locale)

PowerShell defaults to the regional code page (e.g. Windows-1251) when reading
.ps1 files without a BOM. Run this once after placing gemini.ps1 in the src folder:

```powershell
$p = "C:\path\to\src\gemini.ps1"
[IO.File]::WriteAllText($p, (Get-Content $p -Raw), [Text.UTF8Encoding]::new($true))
```

### 4. Run

Double-click `src/assistant.ahk`. The AHK tray icon confirms it is active.

## How it works

```
Ctrl+Number   ->  AHK reads existing clipboard text  ->  %TEMP%\gemini_input.txt
              ->  AHK captures clipboard image (RunWait, synchronous)
                       ->  %TEMP%\gemini_image.jpg
              ->  AHK launches gemini.ps1 (RunWait, blocks until exit)
                       ->  PS writes gemini.lock   (acquired)
                       ->  PS calls Groq API
                       ->  PS writes gemini_output.txt
                       ->  PS deletes gemini.lock  (released)
              ->  AHK reads output
              ->  result copied to clipboard + shown in tooltip for 5 s
```

The lock file is a write-complete sentinel. AHK reads the output only after
`RunWait` returns, by which point all PS file handles are closed. No sleep-based
polling anywhere in the flow.

## Models

| Input | Model | Notes |
|---|---|---|
| Text only | `openai/gpt-oss-120b` | Production text/reasoning model; available on the Free Plan |
| Image (with or without text) | `qwen/qwen3.8-27b` | Preview vision/reasoning model; available on the Free Plan |

Verified on **2026-10-08** against Groq's [supported models](https://console.groq.com/docs/models), [vision documentation](https://console.groq.com/docs/vision), and [Free Plan limits](https://console.groq.com/docs/rate-limits). Both models currently list 30 requests/minute, 1,000 requests/day, 8,000 tokens/minute, and 200,000 tokens/day; account-specific limits may differ. Qwen is a preview model and may change or be discontinued.

All modes use medium reasoning effort for both text-only and image requests, with 1,024 extra completion tokens reserved for reasoning. Only the final answer is returned: `include_reasoning=false` for GPT-OSS and `reasoning_format=hidden` for Qwen, following Groq's [reasoning documentation](https://console.groq.com/docs/reasoning).

### Offline validation

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\reasoning_effort.ps1` from the project folder. This checks PowerShell syntax and request construction for every supported mode with text-only, image-only, and combined inputs, without reading API keys or making API calls.

## API key lookup order

1. `GROQ_API_KEY` environment variable
2. `src/groq_api_key.local.txt` (recommended, git-ignored)
3. `src/groq_api_key.txt` (skipped if it still contains the placeholder text)
