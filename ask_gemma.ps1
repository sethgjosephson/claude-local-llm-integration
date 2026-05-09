<#
.SYNOPSIS
    Send a prompt (and optional files) to a local Ollama-hosted model.

.DESCRIPTION
    Reads each file LOCALLY and stuffs its content into the prompt sent
    to Ollama's /api/generate endpoint.  The file content never leaves
    this machine — and when invoked by Claude Code from a Bash/PowerShell
    tool call, the content never enters Claude's context either.  Only
    the model's response (printed to stdout) does.

    The point: offload token-heavy bulk analysis to local hardware so
    cloud-LLM context budget can be spent on the steps that need
    precision.

.PARAMETER Prompt
    The instruction for the model.  Use plain text or a multi-line
    here-string.

.PARAMETER Files
    One or more paths.  Each is read with Get-Content -Raw and appended
    to the prompt under a "--- FILE: <path> ---" delimiter.

.PARAMETER Model
    Ollama model tag.  Defaults to gemma4:26B — the sweet spot in
    benchmark testing: only ~3x slower than 8B but reliably follows
    format/filter constraints, so its output can be trusted without
    re-verifying every line.  Use gemma4:latest for "find candidates
    to verify with grep" tasks where throughput matters more than
    precision.

.PARAMETER MaxTokens
    Cap on response length (Ollama "num_predict").  Default 4096.

.PARAMETER NumCtx
    Context window size (Ollama "num_ctx").  Default 32768.
    IMPORTANT: Ollama defaults to 2048 regardless of the model's actual
    context window — for any non-trivial input this MUST be raised, or
    the prompt is silently truncated and the model returns nonsense.

.PARAMETER Think
    Enable Gemma 4-style thinking mode.  Default $false because thinking
    burns through `num_predict` on internal reasoning that doesn't
    surface in the response field — leaving you with empty output.

.PARAMETER System
    Optional system prompt (Ollama "system" field).

.PARAMETER Format
    Optional output format ("json" forces JSON-mode generation).

.EXAMPLE
    pwsh ask_gemma.ps1 -Prompt "Summarize in 5 bullets" -Files src/foo.py

.EXAMPLE
    pwsh ask_gemma.ps1 `
        -Prompt "Find any places that swallow exceptions silently. List file:line + the exception type." `
        -Files (Get-ChildItem -Recurse src -Filter *.py).FullName `
        -Model gemma4:31b

.NOTES
    PowerShell ExecutionPolicy: if running .ps1 files is blocked, prefix
    your commands with:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Prompt,
    [string[]]$Files     = @(),
    [string]$Model       = 'gemma4:26B',
    [int]$MaxTokens      = 4096,
    [int]$NumCtx         = 32768,    # Ollama defaults to 2048 — too small
    [bool]$Think         = $false,   # Thinking mode silently eats output budget
    [string]$System      = '',
    [string]$Format      = '',
    [double]$Temperature = 0.2,
    [string]$Endpoint    = 'http://localhost:11434/api/generate',
    [int]$TimeoutSec     = 600
)

$ErrorActionPreference = 'Stop'

# Stitch together the prompt with any file payloads
$body = New-Object System.Text.StringBuilder
[void]$body.AppendLine($Prompt)
foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Warning "File not found, skipping: $f"
        continue
    }
    $resolved = (Resolve-Path -LiteralPath $f).Path
    [void]$body.AppendLine("")
    [void]$body.AppendLine("--- FILE: $resolved ---")
    [void]$body.AppendLine((Get-Content -Raw -LiteralPath $resolved))
}

$req = @{
    model   = $Model
    prompt  = $body.ToString()
    stream  = $false
    think   = $Think
    options = @{
        num_ctx      = $NumCtx
        num_predict  = $MaxTokens
        temperature  = $Temperature
    }
}
if ($System)  { $req.system = $System }
if ($Format)  { $req.format = $Format }

$json = $req | ConvertTo-Json -Depth 8

# Write to a temp file as UTF-8 (no BOM) to avoid PowerShell quoting mishaps
# when source code contains backslashes / embedded quotes.
$tmp = [System.IO.Path]::GetTempFileName()
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)

try {
    $r = Invoke-RestMethod -Method Post -Uri $Endpoint `
            -ContentType 'application/json' -InFile $tmp -TimeoutSec $TimeoutSec
} catch {
    Write-Error "Ollama call failed: $_"
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    exit 1
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

# Print stats to the Information stream so callers can grep just the
# response on stdout (or merge with `6>&1` if they want both).
$inTok  = $r.prompt_eval_count
$outTok = $r.eval_count
$ms     = [math]::Round(($r.total_duration / 1e6))
Write-Information "[ask_gemma] $Model | in=$inTok out=$outTok tokens | $($ms)ms" -InformationAction Continue

Write-Output $r.response
