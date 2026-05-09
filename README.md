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

## Model selection (from benchmark testing)

Ran the same three tasks (structured extract, multi-file pattern detect,
open-ended summary) against several Ollama models. Results on a 16 GB
GPU (RTX 4080 SUPER):

| Model                          | 3-test total | GPU split (32K ctx) | Format adherence                                  |
| ------------------------------ | -----------: | ------------------- | ------------------------------------------------- |
| `gemma4:latest` (8B)           |   16 s       | 100% GPU            | poor — ignores filters, hallucinates line counts  |
| **`qwen2.5-coder:14b`** *(at 16K ctx)* | **16 s** | **100% GPU**     | similar to 8B; code-tuned wording is cleaner      |
| `qwen2.5-coder:14b` (32K ctx)  |   30 s       | 78% GPU             | same                                              |
| **`gemma4:26B`**               |   54 s       | 73% GPU             | **strong — actually filters and constrains**      |
| `qwen3.6:35b-a3b` (MoE)        |   77 s cold / 56 s warm | 55% GPU  | similar to 26B but errors persist; no edge        |

**Two recommended defaults depending on the task:**

- **`gemma4:26B`** — *current wrapper default.* Use when you want the
  model's output to be **trusted directly** (a structured list, a
  filtered set, a typed answer). The only model that reliably honored
  format/filter constraints in testing.

- **`qwen2.5-coder:14b -NumCtx 16384`** — Use when you want **speed
  with grep-verification afterwards** (find candidate file:line
  locations, list files matching a pattern, one-line summaries).
  Code-tuned, fully on GPU, equal speed to 8B. Override `-NumCtx` to
  16384 to keep it 100% GPU; 32K context bumps it to partial offload
  and ~2× slower.

### A note on VRAM (RTX 4080 SUPER, 16 GB)

`ollama ps` reports the GPU/CPU split.  On 16 GB cards, ANY model
whose weights are >~13 GB will partial-offload to CPU regardless of
how small you make `num_ctx` — the weights themselves are the
constraint, not the KV cache.

`qwen3.6:35b-a3b`'s MoE design (3 B active params per token) doesn't
help here: routing decisions still touch all the experts, and any
expert layer that lives on CPU costs per-token latency.  Lowering its
context from 32 K to 8 K kept the split at 55/45 — worth knowing
before assuming bigger MoE = faster on consumer GPUs.

For models that **do** fit (`qwen2.5-coder:14b` and smaller), the KV
cache CAN push you over the edge.  At 32 K ctx the 14B uses 18 GB
total and partial-offloads (78% GPU); at 16 K ctx it's 13 GB and
100% GPU.  Lower `num_ctx` is usually a free speedup if your inputs
are smaller than the cap.

## Caveats / lessons learned

- **8B-class models hallucinate line numbers and ignore filters.** Use
  them only to find candidate locations to grep-verify.
- **`num_ctx`** defaults are way too low. Override every time.
- **Think mode** silently eats your output budget. Default off in this
  wrapper.
- **Big single prompts (>5K tokens) on the 8B** start to repeat
  themselves. Chunk per-file with `gemma_audit_per_file.ps1`.
- **MoE models** like Qwen3.6 35b-a3b were not faster than the dense
  26B on these short sequential calls — the routing overhead dominates.
- **Temp file body**: the wrapper writes the JSON request to a temp file
  before POSTing it. Direct `-Body` passing of long strings containing
  source code can trip PowerShell's quoting and result in `invalid
  character` errors from Ollama's JSON parser.

## License

MIT.
