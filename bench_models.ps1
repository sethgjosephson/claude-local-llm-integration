<#
.SYNOPSIS  Compare Ollama models on representative offload tasks.
#>
param(
    [string[]]$Models = @('gemma4:latest', 'gemma4:26B', 'gemma4:31b', 'qwen3.6:35b-a3b'),
    [string]$ProjectRoot = 'D:\Projects\1004_Nodes_For_3D_Slicer'
)

$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$ask     = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'ask_gemma.ps1'
$canvas  = Join-Path $ProjectRoot 'SlicerNodeEditor\NodeGraph\canvas.py'
$scene   = Join-Path $ProjectRoot 'SlicerNodeEditor\NodeGraph\scene.py'
$results = @()

function Run-Test {
    param($Name, $Model, $Prompt, $Files, $MaxTokens)
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = & $ask -Prompt $Prompt -Files $Files -Model $Model `
                   -NumCtx 32768 -MaxTokens $MaxTokens 2>$null
    $sw.Stop()
    $obj = [pscustomobject]@{
        Model    = $Model
        Test     = $Name
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Bytes    = $resp.Length
        Response = $resp.Trim()
    }
    return $obj
}

foreach ($m in $Models) {
    Write-Information "===== $m =====" -InformationAction Continue

    # --- Test 1: structured extraction ---
    $p1 = @'
List every public method (no leading underscore) declared on the NodeEditorCanvas class in this file, in declaration order.
Output format: just `method_name` (no parens, no args). One per line. No preamble. No bullet points. No code fences.
'@
    $r1 = Run-Test 'extract' $m $p1 @($canvas) 400
    $results += $r1
    Write-Information "  [extract] $($r1.Seconds)s, $($r1.Bytes) bytes" -InformationAction Continue

    # --- Test 2: pattern detection (multi-file, ~6 files) ---
    $p2 = @'
For each of the files below, list any function/method bodies that are >40 lines long.
Output exactly:
<basename>: <function_name> (<line_count> lines)
One per line. If a file has none, omit it entirely (do not say "no findings" for it).
No preamble. No commentary. No markdown.
'@
    $nodeFiles = Get-ChildItem -Path (Join-Path $ProjectRoot 'SlicerNodeEditor\Nodes') -Filter *.py -File `
                 | Where-Object { $_.Name -ne '__init__.py' } | Select-Object -ExpandProperty FullName
    $r2 = Run-Test 'detect' $m $p2 $nodeFiles 600
    $results += $r2
    Write-Information "  [detect] $($r2.Seconds)s, $($r2.Bytes) bytes" -InformationAction Continue

    # --- Test 3: open-ended summary ---
    $p3 = @'
In ONE sentence each (max 25 words), describe what each top-level class in this file does.
Output:
<ClassName>: <one-sentence description>
One class per line. No preamble.
'@
    $r3 = Run-Test 'summarize' $m $p3 @($scene) 500
    $results += $r3
    Write-Information "  [summarize] $($r3.Seconds)s, $($r3.Bytes) bytes" -InformationAction Continue
}

# Print results
Write-Output ''
Write-Output '## Timing summary'
$results | Group-Object Model | ForEach-Object {
    $total = ($_.Group | Measure-Object Seconds -Sum).Sum
    Write-Output ('  {0,-22}  total {1,5:N1}s' -f $_.Name, $total)
    foreach ($r in $_.Group) {
        Write-Output ('    {0,-10} {1,5:N1}s  {2,5} bytes' -f $r.Test, $r.Seconds, $r.Bytes)
    }
}

Write-Output ''
Write-Output '## Responses'
foreach ($r in $results) {
    Write-Output ''
    Write-Output ('### {0} / {1} ({2}s)' -f $r.Model, $r.Test, $r.Seconds)
    Write-Output '```'
    Write-Output $r.Response
    Write-Output '```'
}
