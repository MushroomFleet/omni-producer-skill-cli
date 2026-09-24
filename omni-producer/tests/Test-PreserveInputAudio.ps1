<#
.SYNOPSIS
    Stage 5 preserve-input-audio smoke test (human quality gate, free).

.DESCRIPTION
    Two parts, both free (no API key, no network call):

    1. Dry-run assertion: preserve-audio-omni-prompts.md (two Source jobs
       plus a plain text job) dry-runs under --preserve-input-audio and
       prints the right `audio:` line per job.
    2. Merge assertion: generates a 4-second tone clip (with audio) and a
       4-second silent clip (no audio), plus a stand-in "returned" video
       (a different tone, standing in for what the model would return), then
       runs the exact ffmpeg commands the merge step uses directly against
       copies of the returned video and asserts with ffprobe that:
         - the tone clip's output has an audio stream matching the returned
           video's duration (both clips are 4s in this fixture) within 0.1s;
         - the silent clip's output has no audio stream;
         - the video stream is untouched (same MD5 as the returned video's).

    No ffmpeg splitting or generation happens against the API - this never
    reaches the Gemini Omni Flash endpoint.

.PARAMETER ExePath
    Path to OmniProducer.exe. Defaults to the sibling build output.

.EXAMPLE
    .\Test-PreserveInputAudio.ps1
#>
[CmdletBinding()]
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '..\OmniProducer.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    throw "ffmpeg not found on PATH - required to generate the test fixtures."
}
if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    throw "ffprobe not found on PATH - required to assert against the merged outputs."
}
if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "OmniProducer.exe not found at '$ExePath'. Build it first (dotnet publish) or pass -ExePath."
}

function Invoke-Ffmpeg {
    param([string[]]$Arguments)
    $out = & ffmpeg @Arguments *>&1
    if ($LASTEXITCODE -ne 0) {
        throw "ffmpeg failed (args: $($Arguments -join ' ')):`n$($out -join "`n")"
    }
}

function Get-AudioProbe {
    # Returns '' when the file has no audio stream, else the codec_type text.
    param([string]$Path)
    & ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 -- $Path 2>$null
}

function Get-AudioDuration {
    param([string]$Path)
    $text = & ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 -- $Path 2>$null
    return [double]$text
}

function Get-VideoStreamMd5 {
    param([string]$Path)
    $out = & ffmpeg -y -i $Path -map 0:v:0 -c copy -f md5 - 2>$null
    return ($out | Where-Object { $_ -like 'MD5=*' } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Part 1: dry-run - the right `audio:` line per job, no key, no network.
# ---------------------------------------------------------------------------

$clipsDir = Join-Path $PSScriptRoot 'clips'
if (-not (Test-Path -LiteralPath $clipsDir)) {
    New-Item -ItemType Directory -Path $clipsDir -Force | Out-Null
}
$toneClip = Join-Path $clipsDir 'tone-clip.mp4'
$silentClip = Join-Path $clipsDir 'silent-clip.mp4'
$returned = Join-Path $clipsDir 'returned.mp4'

Write-Host "Generating 4s tone clip (with audio): $toneClip"
Invoke-Ffmpeg @(
    '-y', '-f', 'lavfi', '-i', 'testsrc=duration=4:size=640x360:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=4',
    '-pix_fmt', 'yuv420p', '-shortest', $toneClip
)

Write-Host "Generating 4s silent clip (no audio): $silentClip"
Invoke-Ffmpeg @(
    '-y', '-f', 'lavfi', '-i', 'testsrc=duration=4:size=640x360:rate=24',
    '-pix_fmt', 'yuv420p', $silentClip
)

Write-Host "Generating 4s stand-in 'returned' video: $returned"
Invoke-Ffmpeg @(
    '-y', '-f', 'lavfi', '-i', 'testsrc2=duration=4:size=640x360:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=880:duration=4',
    '-pix_fmt', 'yuv420p', '-shortest', $returned
)

$catalogue = Join-Path $PSScriptRoot 'preserve-audio-omni-prompts.md'
Write-Host "Dry-running $catalogue --preserve-input-audio"
$output = & $ExePath -Path $catalogue -DryRun --preserve-input-audio 2>&1 | ForEach-Object { "$_" }
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }
$joined = $output -join "`n"

if ($joined -notmatch 'audio: input \(tone-clip\.mp4\)') {
    throw "Expected 'audio: input (tone-clip.mp4)' for the Mirror Ripple Edit job."
}
if ($joined -notmatch 'audio: input \(silent-clip\.mp4\)') {
    throw "Expected 'audio: input (silent-clip.mp4)' for the Silent Source Edit job."
}
if ($joined -notmatch 'audio: generated \(no input clip\)') {
    throw "Expected 'audio: generated (no input clip)' for the Neon City Flyover job."
}
if ($exitCode -ne 0) {
    throw "Dry-run exited $exitCode; expected 0."
}
Write-Host "PASS: dry-run prints the right audio: line per job, exit 0." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Part 2: merge - the documented ffmpeg commands, run directly (free, no API).
# ---------------------------------------------------------------------------

$outTone = Join-Path $clipsDir 'out-tone.mp4'
$outSilent = Join-Path $clipsDir 'out-silent.mp4'
Copy-Item -LiteralPath $returned -Destination $outTone -Force
Copy-Item -LiteralPath $returned -Destination $outSilent -Force

$returnedMd5 = Get-VideoStreamMd5 -Path $returned
if (-not $returnedMd5) { throw "Could not read the returned video's video-stream MD5." }

if (-not (Get-AudioProbe -Path $toneClip)) { throw "tone-clip.mp4 unexpectedly has no audio stream." }
if (Get-AudioProbe -Path $silentClip) { throw "silent-clip.mp4 unexpectedly has an audio stream." }

Write-Host "Merging tone-clip.mp4's audio onto out-tone.mp4"
$tmpTone = "$outTone.tmp.mp4"
Invoke-Ffmpeg @(
    '-y', '-i', $outTone, '-i', $toneClip,
    '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k',
    '-af', 'apad', '-shortest', $tmpTone
)
Move-Item -LiteralPath $tmpTone -Destination $outTone -Force

Write-Host "Dropping generated audio on out-silent.mp4 (silent input)"
$tmpSilent = "$outSilent.tmp.mp4"
Invoke-Ffmpeg @('-y', '-i', $outSilent, '-map', '0:v:0', '-c:v', 'copy', '-an', $tmpSilent)
Move-Item -LiteralPath $tmpSilent -Destination $outSilent -Force

if (-not (Get-AudioProbe -Path $outTone)) {
    throw "out-tone.mp4 has no audio stream after the merge - expected the input clip's audio."
}
$toneDuration = Get-AudioDuration -Path $outTone
if ([Math]::Abs($toneDuration - 4.0) -gt 0.1) {
    throw "out-tone.mp4's audio duration is $toneDuration s; expected ~4.0s (within 0.1s)."
}
if (Get-AudioProbe -Path $outSilent) {
    throw "out-silent.mp4 unexpectedly has an audio stream - the silent input should drop the generated audio entirely."
}
$toneVideoMd5 = Get-VideoStreamMd5 -Path $outTone
$silentVideoMd5 = Get-VideoStreamMd5 -Path $outSilent
if ($toneVideoMd5 -ne $returnedMd5) {
    throw "out-tone.mp4's video stream changed during the audio merge (expected -c:v copy to leave it untouched)."
}
if ($silentVideoMd5 -ne $returnedMd5) {
    throw "out-silent.mp4's video stream changed while dropping audio (expected -c:v copy to leave it untouched)."
}

Write-Host "PASS: merge keeps the returned video untouched and swaps in the input clip's audio (or drops it when the input is silent)." -ForegroundColor Green
