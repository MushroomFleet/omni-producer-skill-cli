<#
.SYNOPSIS
    Stage 3 sequence-mode smoke test (human quality gate, free).

.DESCRIPTION
    Generates a 20-second silent test clip with ffmpeg, dry-runs
    sequence-omni-prompts.md (Split: ./clips/sequence-fixture.mp4,
    Segment: 8) against it, and asserts exactly 3 segment jobs are planned
    (ceil(20/8) = 3) with exit code 0. Dry-run only - no API key, no network
    call, no ffmpeg splitting (ffprobe only).

.PARAMETER ExePath
    Path to OmniProducer.exe. Defaults to the sibling build output.

.EXAMPLE
    .\Test-Sequence.ps1

.EXAMPLE
    .\Test-Sequence.ps1 -ExePath ..\OmniProducer\bin\Debug\net8.0\win-x64\OmniProducer.exe
#>
[CmdletBinding()]
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '..\OmniProducer.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw "ffmpeg not found on PATH - required to generate the test fixture."
}
if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "OmniProducer.exe not found at '$ExePath'. Build it first (dotnet publish) or pass -ExePath."
}

$clipsDir = Join-Path $PSScriptRoot 'clips'
if (-not (Test-Path -LiteralPath $clipsDir)) {
    New-Item -ItemType Directory -Path $clipsDir -Force | Out-Null
}
$fixture = Join-Path $clipsDir 'sequence-fixture.mp4'

Write-Host "Generating 20s test clip: $fixture"
& ffmpeg -y -f lavfi -i 'testsrc=duration=20:size=640x360:rate=24' -pix_fmt yuv420p $fixture *>$null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixture)) {
    throw "ffmpeg could not generate the test fixture at $fixture"
}

$catalogue = Join-Path $PSScriptRoot 'sequence-omni-prompts.md'
Write-Host "Dry-running $catalogue"
$output = & $ExePath -Path $catalogue -DryRun 2>&1 | ForEach-Object { "$_" }
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

$segMatches = [regex]::Matches(($output -join "`n"), '\[01-\d\d\]')
if ($segMatches.Count -ne 3) {
    throw "Expected 3 planned segment jobs for Segment: 8 on a 20s clip, found $($segMatches.Count)."
}
if ($exitCode -ne 0) {
    throw "Dry-run exited $exitCode; expected 0."
}

Write-Host "PASS: 3 segment jobs planned for Segment: 8 on a 20s clip, exit 0." -ForegroundColor Green
