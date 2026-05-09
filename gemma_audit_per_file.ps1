<#
.SYNOPSIS
    Run a per-file audit prompt through Gemma and aggregate findings.

.DESCRIPTION
    Pattern: ask the same focused question of every file in a glob.
    Each call is small enough that smaller models stay sharp and don't
    degenerate into repetition (a real failure mode of the 8B class on
    >5K input tokens).  Aggregates findings to stdout, grouped by file.

.PARAMETER Glob
    Path glob (relative to -Root) for files to audit.  Recursive.

.PARAMETER Prompt
    The audit question.  Should ask for a terse list of findings, with
    a sentinel like "NONE" to indicate no findings (lines matching the
    sentinel are filtered out of the aggregate).

.PARAMETER Model
    Ollama model tag.  Defaults to gemma4:latest.

.PARAMETER NumCtx
    Per-call context window.  Default 16384 (per-file calls rarely need
    more).

.PARAMETER MaxTokens
    Per-call response cap.  Default 600 — keep findings terse.

.PARAMETER Root
    Working directory the glob is relative to.  Defaults to current dir.

.EXAMPLE
    pwsh gemma_audit_per_file.ps1 `
        -Glob 'src\**\*.py' `
        -Prompt 'List every silently-swallowed exception. Format: line N - <action>. If none: NONE'
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Glob,
    [Parameter(Mandatory=$true)]
    [string]$Prompt,
    [string]$Model       = 'gemma4:26B',
    [int]$NumCtx         = 16384,
    [int]$MaxTokens      = 600,
    [string]$Root        = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ask       = Join-Path $scriptDir 'ask_gemma.ps1'

$files = Get-ChildItem -Recurse -File -Path (Join-Path $Root $Glob)

foreach ($f in $files) {
    $rel = (Resolve-Path -LiteralPath $f.FullName -Relative)
    if ($rel.StartsWith('.\') -or $rel.StartsWith('./')) { $rel = $rel.Substring(2) }
    Write-Information "[gemma_audit] scanning $rel" -InformationAction Continue

    $resp = & $ask -Prompt $Prompt -Files $f.FullName `
                   -Model $Model -NumCtx $NumCtx -MaxTokens $MaxTokens 2>$null
    $resp = $resp.Trim()
    if (-not $resp -or $resp -eq 'NONE' -or $resp -eq 'None.' -or $resp -eq '(none)') {
        continue
    }
    Write-Output ('=== {0} ===' -f $rel)
    Write-Output $resp
    Write-Output ''
}
