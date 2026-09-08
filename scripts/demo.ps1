[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Inspect', 'Reset')][string]$Action = 'Inspect',
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$OrgId,
    [ValidateRange(0, 2147483647)][int]$ClientId = 0,
    [string]$ConfirmReset = '',
    [switch]$Production,
    [string]$Profile = 'nila',
    [string]$Region = 'ap-south-2',
    [string]$InstanceId = 'i-0547b7fd7907f3a21'
)

$ErrorActionPreference = 'Stop'
$demoRepo = Split-Path $PSScriptRoot -Parent
$demoSource = Get-Content -LiteralPath (Join-Path $demoRepo 'lib/nila/demo_session.ex') -Raw
if ($Action -ne 'Setup' -and $ClientId -lt 1) { throw '-ClientId is required for Inspect and Reset.' }
if ($Action -eq 'Reset' -and $ConfirmReset -cne "RESET $OrgId/$ClientId/2026-06") {
    throw "Inspect first, then pass -ConfirmReset 'RESET $OrgId/$ClientId/2026-06'."
}

$demoCall = switch ($Action) {
    'Setup' { "with {:ok, c} <- Nila.DemoSession.setup($OrgId), do: Nila.DemoSession.inspect_session($OrgId, c.id)" }
    'Inspect' { "Nila.DemoSession.inspect_session($OrgId, $ClientId)" }
    'Reset' { "Nila.DemoSession.reset($OrgId, $ClientId, `"$ConfirmReset`")" }
}
$demoCode = "unless Code.ensure_loaded?(Nila.DemoSession) do`n" + $demoSource + "`nend`nresult = ($demoCall)`nIO.inspect(result, limit: :infinity)`nif match?({:error, _}, result), do: raise(`"Demo operation refused`")`nIO.puts(`"NILA_DEMO_OK`")`n"
$demoScratch = Join-Path $demoRepo 'tmp/demo-operator'
New-Item -ItemType Directory -Force -Path $demoScratch | Out-Null

if ($Production) {
    # Same SSM target/container as scripts/prod-console. No deployment required.
    if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
        $demoPluginDirs = @(
            (Join-Path $env:ProgramFiles 'Amazon/SessionManagerPlugin/bin'),
            (Join-Path $demoRepo 'tmp/demo-prep/ssm-plugin/bin')
        )
        foreach ($demoPluginDir in $demoPluginDirs) {
            if (Test-Path -LiteralPath (Join-Path $demoPluginDir 'session-manager-plugin.exe')) {
                $env:PATH = $demoPluginDir + [IO.Path]::PathSeparator + $env:PATH
                break
            }
        }
    }
    if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
        throw 'AWS Session Manager plugin is missing. See docs/demo-runbook.md.'
    }
    $demoEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($demoCode))
    $demoCommand = "sudo docker exec nila-nila-1 /app/bin/nila rpc 'Code.eval_string(Base.decode64!(`"$demoEncoded`"))'"
    $demoParamsFile = Join-Path $demoScratch ('ssm-' + [Guid]::NewGuid().ToString() + '.json')
    @{ command = @($demoCommand) } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $demoParamsFile -Encoding utf8
    & aws ssm start-session --profile $Profile --region $Region --target $InstanceId --document-name AWS-StartInteractiveCommand --parameters "file://$demoParamsFile" | Tee-Object -Variable demoOutput
} else {
    $demoLocalFile = Join-Path $demoScratch ('local-' + [Guid]::NewGuid().ToString() + '.exs')
    $demoBootstrap = "Application.ensure_all_started(:ecto_sql)`n{:ok, _} = Nila.Repo.start_link()`nLogger.configure(level: :warning)`n"
    $demoBootstrap + $demoCode | Set-Content -LiteralPath $demoLocalFile -Encoding utf8
    Push-Location $demoRepo
    try { & mix run --no-start $demoLocalFile | Tee-Object -Variable demoOutput } finally { Pop-Location }
}
if ($LASTEXITCODE -ne 0) { throw "Demo operation failed (exit $LASTEXITCODE)." }
if (($demoOutput -join "`n") -notmatch 'NILA_DEMO_OK') { throw 'No success acknowledgement was received. Inspect before retrying.' }
