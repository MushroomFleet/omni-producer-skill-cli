<#
.SYNOPSIS
    Stage 6 skill-package smoke test (human quality gate, free).

.DESCRIPTION
    Builds the same zip shape cut-release's `git archive --format=zip
    --output=omni-producer.skill HEAD:skill omni-producer` produces, and
    asserts:
      - the packaged scripts/Invoke-OmniProducer.ps1 is byte-identical to the
        repo's omni-producer/Invoke-OmniProducer.ps1 (the skill-sync copy ran
        and is committed);
      - the package has omni-producer/ at its root, contains SKILL.md, and
        contains no .exe and no config.cfg;
      - SKILL.md mentions --preserve-input-audio, Split, and
        scripts/OmniProducer.exe.

    No API key, no network call, no ffmpeg.

.PARAMETER Ref
    Git ref to archive from. Defaults to HEAD. Ignored with -WorkingTree.

.PARAMETER WorkingTree
    Build the package from the on-disk contents of whatever `git ls-files`
    reports as tracked under skill/omni-producer, instead of archiving a
    commit. Use this to test Stage 6's edits before committing them - a
    plain `git archive HEAD` would still package the pre-edit files.

.EXAMPLE
    .\Test-SkillPackage.ps1              # tests the last commit

.EXAMPLE
    .\Test-SkillPackage.ps1 -WorkingTree # tests the working tree, pre-commit
#>
[CmdletBinding()]
param(
    [string]$Ref = 'HEAD',
    [switch]$WorkingTree
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git not found on PATH - required to build the package for this test."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$masterScript = Join-Path $repoRoot 'omni-producer\Invoke-OmniProducer.ps1'
if (-not (Test-Path -LiteralPath $masterScript)) {
    throw "Master script not found at '$masterScript'."
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("omni-skill-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $zipPath = Join-Path $tempRoot 'omni-producer.skill.zip'
    $extractDir = Join-Path $tempRoot 'extracted'

    if ($WorkingTree) {
        Write-Host "Building the package from the working tree's tracked files (git ls-files)."
        $trackedFiles = & git -C $repoRoot ls-files -- 'skill/omni-producer'
        if (-not $trackedFiles) {
            throw "git ls-files found no tracked files under skill/omni-producer."
        }
        $stageDir = Join-Path $tempRoot 'stage'
        foreach ($rel in $trackedFiles) {
            $src = Join-Path $repoRoot $rel
            $destRel = $rel -replace '^skill/', ''
            $dest = Join-Path $stageDir $destRel
            New-Item -ItemType Directory -Path (Split-Path -Path $dest -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
        Compress-Archive -Path (Join-Path $stageDir 'omni-producer') -DestinationPath $zipPath -Force
    }
    else {
        Write-Host "Building the package with 'git archive' from ref '$Ref'."
        $treeish = "$Ref" + ':skill'
        & git -C $repoRoot archive --format=zip --output=$zipPath $treeish omni-producer
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zipPath)) {
            throw "git archive failed for ref '$Ref' (exit $LASTEXITCODE). Commit Stage 6's changes first, or pass -WorkingTree to test the working tree."
        }
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    # -------------------------------------------------------------------
    # Assertion 1: the packaged script is byte-identical to the master.
    # -------------------------------------------------------------------
    $packagedScript = Join-Path $extractDir 'omni-producer\scripts\Invoke-OmniProducer.ps1'
    if (-not (Test-Path -LiteralPath $packagedScript)) {
        throw "Package is missing omni-producer/scripts/Invoke-OmniProducer.ps1."
    }
    $masterHash = (Get-FileHash -LiteralPath $masterScript -Algorithm SHA256).Hash
    $packagedHash = (Get-FileHash -LiteralPath $packagedScript -Algorithm SHA256).Hash
    if ($packagedHash -ne $masterHash) {
        throw "skill/omni-producer/scripts/Invoke-OmniProducer.ps1 is not byte-identical to omni-producer/Invoke-OmniProducer.ps1 - run the build step's skill-sync copy (and commit it before testing a ref)."
    }
    Write-Host "PASS: packaged Invoke-OmniProducer.ps1 matches the master script byte-for-byte." -ForegroundColor Green

    # -------------------------------------------------------------------
    # Assertion 2: package shape - omni-producer/ at root, SKILL.md present,
    # no .exe, no live config.cfg.
    # -------------------------------------------------------------------
    $rootDirs = Get-ChildItem -LiteralPath $extractDir -Directory
    if (@($rootDirs).Count -ne 1 -or $rootDirs[0].Name -ne 'omni-producer') {
        throw "Package root is not exactly 'omni-producer/' (found: $(@($rootDirs.Name) -join ', '))."
    }
    $skillMdPath = Join-Path $extractDir 'omni-producer\SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMdPath)) {
        throw "Package is missing omni-producer/SKILL.md."
    }
    $allFiles = Get-ChildItem -LiteralPath $extractDir -Recurse -File
    $exeFiles = $allFiles | Where-Object { $_.Extension -eq '.exe' }
    if ($exeFiles) {
        throw "Package unexpectedly contains .exe file(s): $($exeFiles.FullName -join ', ')."
    }
    $configCfgFiles = $allFiles | Where-Object { $_.Name -eq 'config.cfg' }
    if ($configCfgFiles) {
        throw "Package unexpectedly contains a live config.cfg: $($configCfgFiles.FullName -join ', ')."
    }
    Write-Host "PASS: package has omni-producer/ at its root, SKILL.md present, no .exe, no config.cfg." -ForegroundColor Green

    # -------------------------------------------------------------------
    # Assertion 3: SKILL.md documents the newer CLI surface.
    # -------------------------------------------------------------------
    $skillMdText = Get-Content -LiteralPath $skillMdPath -Raw
    foreach ($needle in @('--preserve-input-audio', 'Split', 'scripts/OmniProducer.exe')) {
        if ($skillMdText -notmatch [regex]::Escape($needle)) {
            throw "SKILL.md is missing expected mention of '$needle'."
        }
    }
    Write-Host "PASS: SKILL.md mentions --preserve-input-audio, Split, and scripts/OmniProducer.exe." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
