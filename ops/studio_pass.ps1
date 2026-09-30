param(
    [Parameter(Mandatory = $true)][string]$Run,        # e.g. fishing_nostudio_1 (a run built on the rig)
    [Parameter(Mandatory = $true)][string]$Idea,       # e.g. lakeside_fishing
    [int]$RepairRounds = 2,
    [int]$PolishRounds = 2,
    [switch]$NoPull,                                   # resume a run already on the laptop
    [switch]$PrepareOnly                               # tunnel + pull, then stop (stage a run before Studio is free)
)
# Studio pass on the laptop: pull a rig-built run, then capture -> judge -> fix -> integrate -> polish -> report,
# with Cybus reached through an SSH tunnel (127.0.0.1:18000 -> rig vLLM). Run it as a scheduled task so Claude
# Code's memory reaper cannot stop it. The laptop must stay awake and Studio's window visible while it runs.
# Native commands are checked by exit code: in PowerShell 5.1 their stderr must not be redirected (it turns into
# error records), so ssh/scp/python output goes through cmd.
$ErrorActionPreference = "Continue"
$root = "C:\Users\sarta\cybus-harness"
$runs = "$root\runs"
$local = "$runs\$Run"
$log = "$runs\$Run.studio_pass.log"
New-Item -ItemType Directory -Force -Path $runs | Out-Null
function Say([string]$msg) { "$(Get-Date -Format s) $msg" | Out-File -Append -Encoding utf8 $log }
function PortUp([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync("127.0.0.1", $port).Wait(2000) } catch { return $false } finally { $c.Dispose() }
}
Say "=== studio pass start run=$Run idea=$Idea"

# 1) Cybus through the tunnel
if (-not (PortUp 18000)) {
    Start-Process -WindowStyle Hidden ssh -ArgumentList "-N", "-o", "ServerAliveInterval=30", "-o",
        "ExitOnForwardFailure=yes", "-L", "18000:127.0.0.1:8000", "squaredcube1"
    Start-Sleep 6
}
if (-not (PortUp 18000)) { Say "FAIL: no tunnel to the rig's model server on 127.0.0.1:18000"; exit 2 }

# 3) pull the run from the rig: pack there (agent transcripts stay behind), copy, verify md5, unpack fresh
if (-not $NoPull) {
    $out = cmd /c "ssh squaredcube1 wsl -d Ubuntu-24.04 -e bash /home/sarta/rig_pack_run.sh $Run 2>nul"
    $m = $out | Select-String -Pattern "^([0-9a-f]{32})\s" | Select-Object -Last 1
    if (-not $m) { Say "FAIL: packing $Run on the rig printed no md5: $out"; exit 3 }
    $want = $m.Matches[0].Groups[1].Value
    cmd /c "scp -q squaredcube1:C:/Users/sarta/rig_tmp/$Run.tgz $env:TEMP\$Run.tgz 2>nul"
    $got = (Get-FileHash -Algorithm MD5 "$env:TEMP\$Run.tgz").Hash.ToLower()
    if ($got -ne $want) { Say "FAIL: $Run.tgz md5 $got, rig says $want"; exit 3 }
    if (Test-Path $local) {
        $aside = "$local.prev-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Move-Item $local $aside
        Say "moved the earlier local copy to $aside"
    }
    tar -xzf "$env:TEMP\$Run.tgz" -C $runs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$local\architecture.json")) { Say "FAIL: unpacking $Run"; exit 3 }
    Say "pulled $Run (md5 $got)"
}

if ($PrepareOnly) { Say "prepared $Run (no Studio pass)"; exit 0 }

# 2) the Studio bridge server (the dist build lacks session_list in /health, so run the source)
if (-not (PortUp 3000)) {
    Start-Process -WindowStyle Hidden -WorkingDirectory "C:\Users\sarta\roblox-studio-mcp\packages\server" cmd `
        -ArgumentList "/c", "npx tsx src/index.ts > $runs\bridge_server.log 2>&1"
    for ($i = 0; $i -lt 30 -and -not (PortUp 3000); $i++) { Start-Sleep 2 }
}
if (-not (PortUp 3000)) { Say "FAIL: the Studio bridge server is not up on localhost:3000"; exit 2 }

# 4) model roles (the same thinking policy as the rig builds)
$env:HARNESS_DEFAULT_BASE_URL = "http://127.0.0.1:18000/v1"
$env:HARNESS_DEFAULT_MODEL = "cybus"
$env:HARNESS_DEFAULT_API_KEY = (Get-Content "$HOME\.cybus_serve_key" -Raw).Trim()
$noThink = '{"chat_template_kwargs":{"enable_thinking":false}}'
$env:HARNESS_BUILDER_EXTRA = $noThink
$env:HARNESS_JUDGE_EXTRA = $noThink
$env:HARNESS_REVISER_EXTRA = $noThink
$env:HARNESS_ARCHITECT_EXTRA = $noThink
$env:HARNESS_ARCHITECT_MAX_TOKENS = "32768"
$env:HARNESS_CONCURRENCY = "3"
$env:HARNESS_CONTEXT_BUDGET = "56000"
$env:PYTHONUNBUFFERED = "1"
Set-Location $root

# 5) preflight: tools, bridge, no other Studio window, every model role answers
cmd /c "python -m harness.doctor --run-root $runs >> $log 2>&1"
if ($LASTEXITCODE -ne 0) { Say "FAIL: harness.doctor says not ready (see above)"; exit 4 }

# 6) the pass itself (a resume: plan/style/architecture are pinned and built items are skipped)
cmd /c "python -m harness.workflows.build_game --idea bench/ideas.yaml#$Idea --run-dir $local --repair-rounds $RepairRounds --polish-rounds $PolishRounds --evidence >> $log 2>&1"
Say "exit=$LASTEXITCODE"
