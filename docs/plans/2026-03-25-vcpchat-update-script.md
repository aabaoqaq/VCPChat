# VCPChat Update Script Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild the VCPChat local update flow so it can merge `upstream/main` into local `custom` while preserving local configs, user assets, and a readable audit report.

**Architecture:** Keep `自动更新.bat` as the human-facing entrypoint, but move the real workflow into a PowerShell script under `tools/update/`. The PowerShell script owns backup, merge, protected-file restore, example-key import, dependency checks, conflict reporting, and report retention.

**Tech Stack:** Windows batch, PowerShell 7, local Git CLI

---

### Task 1: Clean local rule inputs

**Files:**
- Modify: `F:/VCP/VCPChat/.update-exclude.txt`

**Step 1: Rewrite the exclude file into stable sections**

Use three sections:
- `核心配置`
- `用户数据`
- `运行时产物`

**Step 2: Preserve the user-approved paths**

Keep the config and local-data paths that were already confirmed in discussion, including wallpapers and sensitive env files.

**Step 3: Remove corrupt lines**

Delete duplicated sections and `ECHO is off.` noise so the file is human-editable again.

### Task 2: Add the PowerShell update workflow

**Files:**
- Create: `F:/VCP/VCPChat/tools/update/VCPChatUpdate.ps1`

**Step 1: Add repo safety checks**

Validate repository root, current branch, and `upstream` remote before doing any Git write operation.

**Step 2: Add protected-file backup and restore**

Snapshot protected files and directories before merge, then restore them after merge.

**Step 3: Add merge and conflict reporting**

Fetch `upstream/main`, show pending commit summary, merge locally, and only prompt when real merge conflicts occur.

**Step 4: Add config post-processing**

For env-like files:
- import missing keys from matching `.example`
- preserve local active config
- save upstream changed real configs into the report history area for review

**Step 5: Add dependency and report handling**

Detect changed dependency manifests, optionally install them, then write a readable Markdown report and prune old report history.

### Task 3: Keep the batch entrypoint simple

**Files:**
- Modify: `F:/VCP/VCPChat/自动更新.bat`

**Step 1: Replace the old batch logic with a launcher**

The batch file should only:
- switch to UTF-8
- locate repo root
- call `tools/update/VCPChatUpdate.ps1`
- preserve exit code
- pause for manual runs

### Task 4: Validate without doing a live merge

**Files:**
- Reference: `F:/VCP/VCPChat/tools/update/VCPChatUpdate.ps1`
- Reference: `F:/VCP/VCPChat/自动更新.bat`

**Step 1: Add a validate-only mode**

The PowerShell script should support `-ValidateOnly` so syntax and path logic can be checked without touching Git state.

**Step 2: Run validation**

Run the PowerShell script in validate mode and confirm:
- no syntax errors
- exclude file loads
- report directory logic builds
- branch/remote checks are readable

