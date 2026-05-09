# Claude + Local LLM Integration

PowerShell helpers for offloading token-heavy bulk code analysis from Claude
(or any cloud LLM driving a Bash/PowerShell tool) to a local Gemma model
running in Ollama.

## Why

When Claude reads a 30 KB source file, those bytes enter its context — and
get billed. For tasks like "scan 20 files for pattern X" or "summarize each
of these in 3 bullets", that adds up fast.

These scripts let Claude shell out to a local model. The file content is
read from disk by **PowerShell**, sent to **Ollama** (running on the same
machine), and only the model's short response comes back across the
tool-call boundary into Claude's context.

Tasks that are great fits:
- Listing TODOs / FIXMEs / dead code candidates across many files
- One-line summaries of a directory of source
- Spotting suspect patterns ("places that catch Exception without re-raising")
- Pre-filtering: "which files mention X?" before Claude reads the hits

Tasks that are bad fits:
- Anything where exact line numbers matter (8B-class models hallucinate
  line numbers; verify with grep)
- Surgical edits — Claude should still do those itself
- Single short questions Claude could answer trivially from context it
  already has

## Setup

1. Install [Ollama](https://ollama.com/) and start the daemon. By default
   it listens on `http://localhost:11434`.
2. Pull a model:
   ```powershell
   ollama pull gemma4:latest    # ~8B, fast
   ollama pull gemma4:31b       # bigger, slower, better reasoning
   ```
3. Clone this repo somewhere stable. The two `.ps1` scripts are
   self-contained — no install step.

If running `.ps1` is blocked by Windows execution policy, prefix sessions
with:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## Scripts

### `ask_gemma.ps1` — single-shot wrapper

```powershell
# Quick smoke test
pwsh ask_gemma.ps1 -Prompt 'Reply with PONG'

# Summarize a single file
pwsh ask_gemma.ps1 -Prompt 'Summarize in 5 bullets.' -Files src/foo.py

# Audit many files in one call (best on a larger model)
pwsh ask_gemma.ps1 `
    -Prompt 'List places that swallow exceptions.' `
    -Files (Get-ChildItem -Recurse src -Filter *.py).FullName `
    -Model gemma4:31b -NumCtx 65536
```

### `gemma_audit_per_file.ps1` — per-file iteration

When the input would be too big for one call (or when smaller models would
loop on themselves), iterate per-file and aggregate.

```powershell
pwsh gemma_audit_per_file.ps1 `
    -Glob 'src\**\*.py' `
    -Prompt 'List every silently-swallowed exception. Format: line N - <action>. If none: NONE'
```

## Important parameters (and why they exist)

| Param        | Why it matters                                                                                                         |
| ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `-NumCtx`    | Ollama defaults to **2048 tokens** regardless of model. For real files set 16K / 32K / 65K explicitly or your prompt is silently truncated and the model returns nonsense. |
| `-Think`     | Gemma 4 has thinking mode ON by default and burns `num_predict` on internal reasoning that doesn't surface in the response field. Default is `$false` here for that reason. |
| `-MaxTokens` | `num_predict` — cap on response length.                                                                                |
| `-Model`     | `gemma4:latest` (8B) for speed, `gemma4:31b` (31B) for harder reasoning.                                               |

## How Claude uses this

In a Claude Code session, when an analysis task would be expensive in
Claude's context, Claude can call:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
& 'D:\path\to\ask_gemma.ps1' -Prompt '<question>' -Files <paths>
```

via its Bash/PowerShell tool. Claude sees the model's short answer, not
the file content that went into it.

A useful follow-up pattern for findings that include code citations:
1. Gemma flags candidate file:line locations
2. Claude verifies each with a `Grep` call
3. Claude only reads the verified lines in detail

## Caveats / lessons learned

- **8B-class models hallucinate line numbers.** Use them to find
  candidate locations, then verify with grep before acting.
- **`num_ctx`** defaults are way too low. Override every time.
- **Think mode** silently eats your output budget. Default off in this
  wrapper.
- **Big single prompts (>5K tokens) on the 8B** start to repeat
  themselves. Chunk per-file with `gemma_audit_per_file.ps1` instead.
- **31B is slow** on most consumer hardware — fine for a few well-chosen
  prompts, not for batch loops.
- **Temp file body**: the wrapper writes the JSON request to a temp file
  before POSTing it. This is deliberate — direct `-Body` passing of long
  strings containing source code can trip PowerShell's quoting and result
  in `invalid character` errors from Ollama's JSON parser.

## License

MIT.
