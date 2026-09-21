<#
.SYNOPSIS
    Omni Producer - a zero-UI PowerShell CLI that turns "video job catalogue"
    files into finished .mp4 videos on disk via the Gemini Omni Flash
    Interactions API.

.DESCRIPTION
    Parses one markdown catalogue (or a folder of them), or consumes a
    Claude-extracted JSON manifest, and for each job builds the task-specific
    Omni Flash request (text_to_video, image_to_video, reference_to_video, or
    edit - both chained edits via previous_interaction_id and uploads of the
    user's own videos via the Files API), delivers the video (inline base64 or
    URI polling), and writes NN-<slug>.mp4 plus an NN-<slug>.json sidecar
    recording the interaction id so later runs can chain edits.

    Implementation spec: omni-producer-CLI-TINS.md (project root). API shapes
    are grounded in Google's Omni Flash docs and the proven Rust client in
    omnotation-dev/src-tauri/src/gemini.rs.

.PARAMETER Path
    Markdown mode: a single .md catalogue, or a folder of .md files.

.PARAMETER Manifest
    Manifest mode: a Claude-extracted JSON job list.

.PARAMETER ConfigPath
    Path to the JSON config. Defaults to config.cfg next to this script.

.PARAMETER Index
    1-based index of a single job to run (0 = all).

.PARAMETER Limit
    Run at most this many jobs (0 = no limit). Applied after -Index.

.PARAMETER Model
    Override the model id from config.

.PARAMETER AspectRatio
    Override the default aspect ratio (16:9 or 9:16) for jobs without their own.

.PARAMETER Delivery
    Override the default delivery (inline or uri) for jobs without their own.

.PARAMETER ApiKey
    Override the API key (otherwise config.apiKey, then $env:GEMINI_API_KEY,
    then $env:OMNI_API_KEY).

.PARAMETER Force
    Regenerate even when the output .mp4 already exists.

.PARAMETER DryRun
    Parse, validate, and list what WOULD be generated. No API call, no key.

.PARAMETER Recurse
    When Path is a folder, search subfolders for .md files too.

.EXAMPLE
    .\Invoke-OmniProducer.ps1 -Path .\tests\demo-videos-omni-prompts.md -DryRun

.EXAMPLE
    .\Invoke-OmniProducer.ps1 -Path .\tests\demo-videos-omni-prompts.md -Index 1
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    [string]$Manifest,

    [string]$ConfigPath,

    [int]$Index = 0,

    [int]$Limit = 0,

    [string]$Model,

    [ValidateSet('16:9', '9:16')]
    [string]$AspectRatio,

    [ValidateSet('inline', 'uri')]
    [string]$Delivery,

    [string]$ApiKey,

    [switch]$Force,

    [switch]$DryRun,

    [switch]$Recurse
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The Gemini endpoints require TLS 1.2; Windows PowerShell 5.1 may default lower.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:NetworkErrorMsg = "Couldn't reach Gemini - check your connection and retry."

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

function Get-OmniConfig {
    param([string]$ConfigPath)

    $defaults = [ordered]@{
        apiKey                    = ''
        model                     = 'gemini-omni-flash-preview'
        endpointBase              = 'https://generativelanguage.googleapis.com/v1beta'
        uploadEndpointBase        = 'https://generativelanguage.googleapis.com/upload/v1beta/files'
        defaultAspectRatio        = '16:9'
        defaultDelivery           = 'uri'
        store                     = $true
        timeoutSeconds            = 600
        pollIntervalSeconds       = 5
        pollTimeoutSeconds        = 600
        uploadPollIntervalSeconds = 3
        uploadPollTimeoutSeconds  = 300
        maxRetries                = 2
        delayBetweenJobsSeconds   = 2
        saveResponseJson          = $true
        saveJobSidecar            = $true
        slugMaxLength             = 80
        ffmpegPath                = 'ffmpeg'
        ffprobePath               = 'ffprobe'
        generationSeconds         = 8
    }

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $PSScriptRoot 'config.cfg'
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        if ($raw.Trim()) {
            $loaded = $raw | ConvertFrom-Json
            foreach ($key in @($defaults.Keys)) {
                if ($loaded.PSObject.Properties.Name -contains $key -and $null -ne $loaded.$key) {
                    $defaults[$key] = $loaded.$key
                }
            }
        }
    } else {
        Write-Warning "Config not found at '$ConfigPath'. Using built-in defaults."
    }

    return [pscustomobject]$defaults
}

# ---------------------------------------------------------------------------
# Shared helpers (proven verbatim in Lyra Producer)
# ---------------------------------------------------------------------------

function ConvertTo-Slug {
    param([string]$Text, [int]$MaxLength = 80)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'untitled' }

    $s = $Text
    $s = $s -replace '[*_`~]', ''
    $s = $s -replace '(?<=\d),(?=\d)', ''
    $expand = [ordered]@{
        ([char]0x00DF) = 'ss'
        ([char]0x00F8) = 'o'
        ([char]0x00D8) = 'o'
        ([char]0x00E6) = 'ae'
        ([char]0x00C6) = 'ae'
        ([char]0x0153) = 'oe'
        ([char]0x0152) = 'oe'
    }
    foreach ($k in $expand.Keys) { $s = $s.Replace([string]$k, [string]$expand[$k]) }

    $norm = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $norm.ToCharArray()) {
        $cat = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString().Normalize([Text.NormalizationForm]::FormC)

    $s = $s.ToLowerInvariant()
    $s = $s -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')

    if ([string]::IsNullOrWhiteSpace($s)) { return 'untitled' }
    if ($s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength).Trim('-')
    }
    return $s
}

function Get-OutputFolderName {
    param([string]$FileBaseName)

    $parts = $FileBaseName -split '[-_\s]+' | Where-Object { $_ -ne '' }
    $first4 = $parts | Select-Object -First 4
    return (($first4 -join '-')).ToLowerInvariant()
}

function Get-Prop {
    # Case/style-tolerant property fetch (downloadUri vs download_uri, etc.)
    param($Object, [string[]]$Names)
    if ($null -eq $Object) { return $null }
    foreach ($n in $Names) {
        if ($Object.PSObject.Properties.Name -contains $n) { return $Object.$n }
    }
    return $null
}

function Resolve-ApiError {
    param($ErrorRecord)
    # Gemini returns a JSON error body; surface error.message verbatim (safety
    # blocks and region restrictions carry their reason there). Falls back to
    # reading the raw response stream, then the exception message.
    $detail = $null
    try {
        $raw = $null
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $raw = $ErrorRecord.ErrorDetails.Message
        } elseif ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $ErrorRecord.Exception.Response) {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $raw = $reader.ReadToEnd()
            }
        }
        if ($raw) {
            $parsed = $raw | ConvertFrom-Json
            $detail = Get-Prop (Get-Prop $parsed @('error')) @('message', 'status')
        }
    } catch { }
    if (-not $detail) { $detail = $ErrorRecord.Exception.Message }
    return $detail
}

function Get-HttpStatus {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch { }
    return $null
}

function Get-HeaderValue {
    param($Headers, [string]$Name)
    foreach ($k in $Headers.Keys) {
        if ($k -ieq $Name) { return [string]$Headers[$k] }
    }
    return $null
}

function Resolve-JobPath {
    # Relative media paths resolve against the catalogue/manifest directory.
    param([string]$BaseDir, [string]$Value)
    $v = $Value.Trim().Trim('"').Trim("'")
    if ([System.IO.Path]::IsPathRooted($v)) {
        return [System.IO.Path]::GetFullPath($v)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $v))
}

# ---------------------------------------------------------------------------
# Mime tables
# ---------------------------------------------------------------------------

$script:ImageMimes = @{
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
}
$script:VideoExts = @('.mp4', '.mov', '.webm', '.m4v')
$script:MaxUploadBytes = 2GB

function Get-VideoMime {
    param([string]$FilePath)
    switch ([System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()) {
        '.mov'  { return 'video/quicktime' }
        '.webm' { return 'video/webm' }
        '.m4v'  { return 'video/x-m4v' }
        default { return 'video/mp4' }
    }
}

# ---------------------------------------------------------------------------
# Job model + validation
# ---------------------------------------------------------------------------

$script:ValidTasks = @('text_to_video', 'image_to_video', 'reference_to_video', 'edit')
$script:MaxReferences = 6

function New-OmniJob {
    param([int]$Idx, [string]$Title)
    return [pscustomobject]@{
        Index        = $Idx
        Title        = $Title
        Prompt       = ''
        TaskExplicit = ''
        Task         = ''      # resolved by Resolve-JobTask
        Aspect       = ''      # per-job override, '' = use effective default
        Delivery     = ''
        Image        = ''
        Refs         = (New-Object System.Collections.Generic.List[string])
        Source       = ''
        EditFrom     = ''
        Errors       = (New-Object System.Collections.Generic.List[string])

        # Sequence mode (Stage 3): directives as parsed from the catalogue/manifest.
        Split          = ''
        SegmentSeconds = 0     # 0 = unset -> resolves to config.generationSeconds
        Walk           = $null # $null = default (on when Split is set)
        Vision         = $null # $null = default (on when Walk resolves on)

        # Sequence mode: set by Expand-OmniSequences on the expanded per-segment jobs.
        IsSequenceSegment = $false
        SeqParentIndex    = 0
        SeqIndex          = 0
        SeqCount          = 0
        SeqSegmentPath    = ''
        SeqFramePath      = ''
        SeqVisionText     = ''
    }
}

function Resolve-JobTask {
    # Explicit task wins; else infer. Records contradictions into Job.Errors.
    param([object]$Job)

    $hasImage = [bool]$Job.Image
    $hasRefs = $Job.Refs.Count -gt 0
    $hasSource = [bool]$Job.Source
    $hasEditFrom = [bool]$Job.EditFrom
    $hasSplit = [bool]$Job.Split

    if (-not $hasSplit -and $Job.SegmentSeconds -ne 0) { [void]$Job.Errors.Add('Segment requires Split') }
    if (-not $hasSplit -and $null -ne $Job.Walk) { [void]$Job.Errors.Add('Walk requires Split') }
    if (-not $hasSplit -and $null -ne $Job.Vision) { [void]$Job.Errors.Add('Vision requires Split') }
    if ($hasSplit -and ($hasImage -or $hasRefs -or $hasSource -or $hasEditFrom)) {
        [void]$Job.Errors.Add('Split cannot be combined with Image/Ref/Source/Edit-from')
    }
    if ($hasSplit -and $Job.TaskExplicit -and $Job.TaskExplicit -ne 'edit') {
        [void]$Job.Errors.Add('Split jobs always use task edit per segment - remove Task or set it to edit')
    }

    if ($Job.TaskExplicit -and $script:ValidTasks -notcontains $Job.TaskExplicit) {
        [void]$Job.Errors.Add("unknown task '$($Job.TaskExplicit)'")
        return
    }
    if ($Job.Aspect -and @('16:9', '9:16') -notcontains $Job.Aspect) {
        [void]$Job.Errors.Add("invalid aspect '$($Job.Aspect)' (use 16:9 or 9:16)")
    }
    if ($Job.Delivery -and @('inline', 'uri') -notcontains $Job.Delivery) {
        [void]$Job.Errors.Add("invalid delivery '$($Job.Delivery)' (use inline or uri)")
    }

    # Cross-media contradictions.
    if ($hasSource -and ($hasImage -or $hasRefs)) {
        [void]$Job.Errors.Add('Source cannot be combined with Image/Ref')
    }
    if ($hasEditFrom -and ($hasImage -or $hasRefs -or $hasSource)) {
        [void]$Job.Errors.Add('Edit-from cannot be combined with Image/Ref/Source')
    }
    if ($hasRefs -and -not $hasImage) {
        [void]$Job.Errors.Add('Ref requires an Image (the first-frame image)')
    }
    if ($Job.Refs.Count -gt $script:MaxReferences) {
        [void]$Job.Errors.Add("too many references ($($Job.Refs.Count); max $script:MaxReferences)")
    }

    $inferred = ''
    if ($hasSplit) { $inferred = 'edit' }
    elseif ($hasEditFrom) { $inferred = 'edit' }
    elseif ($hasSource) { $inferred = 'edit' }
    elseif ($hasImage -and $hasRefs) { $inferred = 'reference_to_video' }
    elseif ($hasImage) { $inferred = 'image_to_video' }
    else { $inferred = 'text_to_video' }

    if ($hasSplit) {
        # Split jobs are replaced by per-segment edit jobs before the queue runs
        # (Expand-OmniSequences); the parent's own task is never sent.
        $Job.Task = 'edit'
        return
    }

    if ($Job.TaskExplicit) {
        # An explicit task its media can't satisfy is a contradiction.
        switch ($Job.TaskExplicit) {
            'text_to_video' {
                if ($hasImage -or $hasRefs -or $hasSource -or $hasEditFrom) {
                    [void]$Job.Errors.Add('text_to_video takes no media or Edit-from')
                }
            }
            'image_to_video' {
                if (-not $hasImage) { [void]$Job.Errors.Add('image_to_video requires an Image') }
                if ($hasRefs -or $hasSource -or $hasEditFrom) {
                    [void]$Job.Errors.Add('image_to_video takes only an Image')
                }
            }
            'reference_to_video' {
                if (-not ($hasImage -and $hasRefs)) {
                    [void]$Job.Errors.Add('reference_to_video requires an Image plus at least one Ref')
                }
                if ($hasSource -or $hasEditFrom) {
                    [void]$Job.Errors.Add('reference_to_video takes no Source/Edit-from')
                }
            }
            'edit' {
                if (-not ($hasSource -or $hasEditFrom)) {
                    [void]$Job.Errors.Add('edit requires a Source video or Edit-from')
                }
            }
        }
        $Job.Task = $Job.TaskExplicit
    } else {
        $Job.Task = $inferred
    }
}

function Test-JobMedia {
    # Existence/type checks for everything the job references on disk.
    param([object]$Job, [int]$JobCount)

    foreach ($img in (@($Job.Image) + @($Job.Refs) | Where-Object { $_ })) {
        $ext = [System.IO.Path]::GetExtension($img).ToLowerInvariant()
        if (-not $script:ImageMimes.ContainsKey($ext)) {
            [void]$Job.Errors.Add("unsupported image type '$ext' - use PNG, JPG, or WEBP: $img")
        } elseif (-not (Test-Path -LiteralPath $img)) {
            [void]$Job.Errors.Add("media not found: $img")
        }
    }

    if ($Job.Source) {
        $ext = [System.IO.Path]::GetExtension($Job.Source).ToLowerInvariant()
        if ($script:VideoExts -notcontains $ext) {
            [void]$Job.Errors.Add("Unsupported file type - use MP4, MOV, or WEBM: $($Job.Source)")
        } elseif (-not (Test-Path -LiteralPath $Job.Source)) {
            [void]$Job.Errors.Add("media not found: $($Job.Source)")
        } elseif ((Get-Item -LiteralPath $Job.Source).Length -gt $script:MaxUploadBytes) {
            [void]$Job.Errors.Add('Video is larger than the 2 GB upload limit.')
        }
    }

    if ($Job.Split) {
        $ext = [System.IO.Path]::GetExtension($Job.Split).ToLowerInvariant()
        if ($script:VideoExts -notcontains $ext) {
            [void]$Job.Errors.Add("Unsupported file type - use MP4, MOV, or WEBM: $($Job.Split)")
        } elseif (-not (Test-Path -LiteralPath $Job.Split)) {
            [void]$Job.Errors.Add("media not found: $($Job.Split)")
        }
    }

    if ($Job.EditFrom) {
        $ef = $Job.EditFrom
        if ($ef -match '^#(\d+)$') {
            $n = [int]$Matches[1]
            if ($n -lt 1 -or $n -gt $JobCount) {
                [void]$Job.Errors.Add("Edit-from #$n is out of range (catalogue has $JobCount job(s))")
            } elseif ($n -ge $Job.Index) {
                [void]$Job.Errors.Add("Edit-from #$n must reference an earlier job (this is job $($Job.Index))")
            }
        } elseif ($ef -match '(?i)\.json$') {
            if (-not (Test-Path -LiteralPath $ef)) {
                [void]$Job.Errors.Add("Edit-from sidecar not found: $ef")
            }
        } elseif ($script:VideoExts -contains [System.IO.Path]::GetExtension($ef).ToLowerInvariant()) {
            $side = [System.IO.Path]::ChangeExtension($ef, '.json')
            if (-not (Test-Path -LiteralPath $side)) {
                [void]$Job.Errors.Add("Edit-from video has no sidecar beside it: $side")
            }
        }
        # Anything else is treated as a literal interaction id at run time.
    }
}

# ---------------------------------------------------------------------------
# Input mode A: markdown catalogue parser
# ---------------------------------------------------------------------------

$script:DirectiveRe = '(?i)^\s*(?:\*\*|__)?(task|aspect|delivery|image|ref|source|edit-from|split|segment|walk|vision)(?:\s*:\s*(?:\*\*|__)?|\s*(?:\*\*|__)\s*:)\s*(.+?)\s*$'

function ConvertTo-OnOff {
    param([object]$Job, [string]$Label, [string]$Value)
    switch ($Value.Trim().ToLowerInvariant()) {
        'on'    { return $true }
        'off'   { return $false }
        default {
            [void]$Job.Errors.Add("invalid $Label '$Value' (use on or off)")
            return $null
        }
    }
}

function Get-VideoJobs {
    param([string[]]$Lines, [string]$BaseDir)

    # A job is a `###` heading + a fenced prompt block, with optional directive
    # lines. `#`/`##` close the current job; fenced blocks outside a job are
    # ignored; sections without a prompt are dropped.
    $sections = New-Object System.Collections.Generic.List[object]
    $current = $null
    $inFence = $false
    $fenceLines = $null

    foreach ($line in $Lines) {
        $lead = $line.TrimStart()

        if ($inFence) {
            if ($lead.StartsWith('```')) {
                if ($null -ne $current) {
                    $block = ($fenceLines -join "`n").Trim()
                    if ($block) {
                        if ($current.Prompt) { $current.Prompt = "$($current.Prompt)`n$block" }
                        else { $current.Prompt = $block }
                    }
                }
                $inFence = $false
                $fenceLines = $null
            } else {
                [void]$fenceLines.Add($line)
            }
            continue
        }

        if ($lead.StartsWith('```')) {
            $inFence = $true
            $fenceLines = New-Object System.Collections.Generic.List[string]
            continue
        }

        $m = [regex]::Match($line, '^(#{1,6})\s+(.*)$')
        if ($m.Success) {
            $level = $m.Groups[1].Value.Length
            $text = $m.Groups[2].Value.Trim()
            if ($level -eq 3) {
                $current = New-OmniJob -Idx 0 -Title $text
                [void]$sections.Add($current)
            } elseif ($level -le 2) {
                $current = $null
            }
            # `####`+ lines are informational; ignored.
            continue
        }

        if ($null -eq $current) { continue }

        $d = [regex]::Match($line, $script:DirectiveRe)
        if ($d.Success) {
            $label = $d.Groups[1].Value.ToLowerInvariant()
            $value = $d.Groups[2].Value.Trim()
            switch ($label) {
                'task'      { $current.TaskExplicit = $value.ToLowerInvariant() }
                'aspect'    { $current.Aspect = $value }
                'delivery'  { $current.Delivery = $value.ToLowerInvariant() }
                'image'     { $current.Image = Resolve-JobPath $BaseDir $value }
                'ref'       { [void]$current.Refs.Add((Resolve-JobPath $BaseDir $value)) }
                'source'    { $current.Source = Resolve-JobPath $BaseDir $value }
                'edit-from' {
                    if ($value -match '^#\d+$' -or $value -notmatch '[\\/]|\.(json|mp4|mov|webm|m4v)$') {
                        $current.EditFrom = $value   # same-run ref or literal id
                    } else {
                        $current.EditFrom = Resolve-JobPath $BaseDir $value
                    }
                }
                'split' { $current.Split = Resolve-JobPath $BaseDir $value }
                'segment' {
                    $segSecs = 0
                    if (-not [int]::TryParse($value, [ref]$segSecs) -or $segSecs -le 0) {
                        [void]$current.Errors.Add("invalid Segment '$value' (use a whole number of seconds)")
                    } else {
                        $current.SegmentSeconds = $segSecs
                    }
                }
                'walk'   { $current.Walk = ConvertTo-OnOff -Job $current -Label 'Walk' -Value $value }
                'vision' { $current.Vision = ConvertTo-OnOff -Job $current -Label 'Vision' -Value $value }
            }
            continue
        }
        # Ordinary prose / blockquote taglines are ignored.
    }

    # Keep only sections with a prompt; number them 1-based.
    $jobs = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($sec in $sections) {
        if (-not $sec.Prompt) { continue }
        $n++
        $sec.Index = $n
        [void]$jobs.Add($sec)
    }
    foreach ($job in $jobs) {
        Resolve-JobTask -Job $job
        Test-JobMedia -Job $job -JobCount $jobs.Count
    }
    return $jobs
}

# ---------------------------------------------------------------------------
# Input mode B: Claude-extracted JSON manifest
# ---------------------------------------------------------------------------

function Read-OmniManifest {
    param([string]$ManifestPath)

    $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    $mf = $raw | ConvertFrom-Json
    $baseDir = Split-Path -Parent $ManifestPath

    $mfJobs = Get-Prop $mf @('jobs')
    if (-not $mfJobs -or @($mfJobs).Count -eq 0) {
        throw "Manifest '$ManifestPath' has no 'jobs' array."
    }

    $jobs = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($mj in @($mfJobs)) {
        $n++
        $prompt = Get-Prop $mj @('prompt')
        if (-not $prompt -or -not "$prompt".Trim()) {
            throw "Manifest job $n is missing a non-empty 'prompt'."
        }
        $title = Get-Prop $mj @('title')
        $job = New-OmniJob -Idx $n -Title $(if ($title) { "$title" } else { "job-$n" })
        $job.Prompt = "$prompt".Trim()

        $v = Get-Prop $mj @('task');        if ($v) { $job.TaskExplicit = "$v".ToLowerInvariant() }
        $v = Get-Prop $mj @('aspectRatio'); if ($v) { $job.Aspect = "$v" }
        $v = Get-Prop $mj @('delivery');    if ($v) { $job.Delivery = "$v".ToLowerInvariant() }
        $v = Get-Prop $mj @('image');       if ($v) { $job.Image = Resolve-JobPath $baseDir "$v" }
        $v = Get-Prop $mj @('references')
        if ($v) { foreach ($r in @($v)) { [void]$job.Refs.Add((Resolve-JobPath $baseDir "$r")) } }
        $v = Get-Prop $mj @('sourceVideo'); if ($v) { $job.Source = Resolve-JobPath $baseDir "$v" }
        $v = Get-Prop $mj @('editFrom')
        if ($v) {
            $ef = "$v".Trim()
            if ($ef -match '^#\d+$' -or $ef -notmatch '[\\/]|\.(json|mp4|mov|webm|m4v)$') {
                $job.EditFrom = $ef
            } else {
                $job.EditFrom = Resolve-JobPath $baseDir $ef
            }
        }
        $v = Get-Prop $mj @('split');          if ($v) { $job.Split = Resolve-JobPath $baseDir "$v" }
        $v = Get-Prop $mj @('segmentSeconds'); if ($null -ne $v) { $job.SegmentSeconds = [int]$v }
        $v = Get-Prop $mj @('walk');           if ($null -ne $v) { $job.Walk = [bool]$v }
        $v = Get-Prop $mj @('vision');         if ($null -ne $v) { $job.Vision = [bool]$v }
        [void]$jobs.Add($job)
    }
    foreach ($job in $jobs) {
        Resolve-JobTask -Job $job
        Test-JobMedia -Job $job -JobCount $jobs.Count
    }

    # Output directory: explicit outputDir wins, else derive from sourceFile.
    $outDir = Get-Prop $mf @('outputDir')
    $srcFile = Get-Prop $mf @('sourceFile')
    if (-not $outDir) {
        if (-not $srcFile) {
            throw "Manifest needs 'outputDir' or 'sourceFile' so the output folder is known."
        }
        $srcDir = Split-Path -Parent $srcFile
        if (-not $srcDir) { $srcDir = '.' }
        $srcBase = [System.IO.Path]::GetFileNameWithoutExtension($srcFile)
        $outDir = Join-Path $srcDir (Get-OutputFolderName -FileBaseName $srcBase)
    }

    $display = $(if ($srcFile) { Split-Path $srcFile -Leaf } else { Split-Path $ManifestPath -Leaf })

    return [pscustomobject]@{
        Jobs        = $jobs
        OutDir      = "$outDir"
        DisplayName = $display
    }
}

# ---------------------------------------------------------------------------
# Gemini Omni Flash API
# ---------------------------------------------------------------------------

function Get-FileIdFromUri {
    param([string]$Uri)
    $idx = $Uri.LastIndexOf('files/')
    $id = if ($idx -ge 0) { $Uri.Substring($idx + 6) } else { $Uri }
    return ($id -split '[?#:]')[0]
}

function Build-OmniRequestBody {
    # Per-task input shapes verbatim from the proven build_request_body.
    param(
        [object]$Job,
        [string]$ModelId,
        [string]$EffAspect,
        [string]$EffDelivery,
        [bool]$Store,
        [string]$UploadedUri,
        [string]$PreviousInteractionId
    )

    $textItem = [ordered]@{ type = 'text'; text = $Job.Prompt }
    $imageItem = {
        param([string]$ImgPath)
        $ext = [System.IO.Path]::GetExtension($ImgPath).ToLowerInvariant()
        [ordered]@{
            type      = 'image'
            data      = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ImgPath))
            mime_type = $script:ImageMimes[$ext]
        }
    }

    $input = $null
    switch ($Job.Task) {
        'text_to_video' {
            $input = @(, $textItem)
        }
        'image_to_video' {
            $input = @((& $imageItem $Job.Image), $textItem)
        }
        'reference_to_video' {
            # First-frame image first (binds <FIRST_FRAME>), then refs in order
            # (bind <IMAGE_REF_0..> by array position), then the text.
            $items = New-Object System.Collections.Generic.List[object]
            [void]$items.Add((& $imageItem $Job.Image))
            foreach ($r in $Job.Refs) { [void]$items.Add((& $imageItem $r)) }
            [void]$items.Add($textItem)
            $input = $items.ToArray()
        }
        'edit' {
            if ($PreviousInteractionId) {
                # Chained edit of a stored generation: plain-string input.
                $input = $Job.Prompt
            } else {
                # Uploaded-video edit: reference the Files API upload. Live-API
                # verified: the item must be type "video" with uri + mime_type -
                # the SDK docs' {type:"document"} isn't counted as a video by the
                # REST endpoint ("Exactly one input video is required").
                # Sequence mode (Stage 3, unverified): a walked segment prepends
                # the previous segment's last frame as a driving continuity image.
                $editItems = New-Object System.Collections.Generic.List[object]
                if ($Job.Image) { [void]$editItems.Add((& $imageItem $Job.Image)) }
                [void]$editItems.Add([ordered]@{
                    type      = 'video'
                    uri       = $UploadedUri
                    mime_type = (Get-VideoMime $Job.Source)
                })
                [void]$editItems.Add($textItem)
                $input = $editItems.ToArray()
            }
        }
        default { throw "Unknown task $($Job.Task)." }
    }

    # Live-API verified (2026-08-03): the API rejects video_config.task together
    # with previous_interaction_id, and an edit inherits its aspect from the
    # source video, so edits omit aspect_ratio.
    $responseFormat = [ordered]@{ type = 'video' }
    if ($Job.Task -ne 'edit') { $responseFormat['aspect_ratio'] = $EffAspect }
    $responseFormat['delivery'] = $EffDelivery

    $body = [ordered]@{
        model = $ModelId
        input = $input
    }
    if (-not $PreviousInteractionId) {
        $body['generation_config'] = [ordered]@{ video_config = [ordered]@{ task = $Job.Task } }
    }
    $body['response_format'] = $responseFormat
    $body['background'] = $false
    $body['store'] = $Store
    $body['stream'] = $false
    if ($PreviousInteractionId) {
        $body['previous_interaction_id'] = $PreviousInteractionId
    }
    return ConvertTo-Json -InputObject $body -Depth 8
}

function Invoke-OmniInteraction {
    param([string]$BodyJson, [string]$ApiKey, [object]$Config)

    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Post `
            -Uri "$($Config.endpointBase.TrimEnd('/'))/interactions" `
            -Headers @{ 'x-goog-api-key' = $ApiKey } `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($BodyJson)) `
            -TimeoutSec ([int]$Config.timeoutSeconds)
    } catch {
        $status = Get-HttpStatus $_
        if ($null -eq $status) { throw $script:NetworkErrorMsg }
        $msg = Resolve-ApiError $_
        if ($msg -eq $_.Exception.Message) {
            if ($status -ge 500) { $msg = 'Gemini had a server error - retry in a moment.' }
            else { $msg = 'Gemini rejected this request.' }
        }
        throw $msg
    }

    $raw = $resp.Content
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { }
    return [pscustomobject]@{ Raw = $raw; Parsed = $parsed }
}

function Test-VideoMap {
    param($Node)
    if ($null -eq $Node -or $Node -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $names = $Node.PSObject.Properties.Name
    return (($names -contains 'type') -and ("$($Node.type)" -eq 'video') -and
            (($names -contains 'data') -or ($names -contains 'uri')))
}

function Search-AnyVideo {
    param($Node)
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if (Test-VideoMap $Node) { return $Node }
        foreach ($p in $Node.PSObject.Properties) {
            $r = Search-AnyVideo $p.Value
            if ($r) { return $r }
        }
    } elseif ($Node -is [array]) {
        foreach ($e in $Node) {
            $r = Search-AnyVideo $e
            if ($r) { return $r }
        }
    }
    return $null
}

function Find-VideoItem {
    # Documented path: steps[] -> model_output -> content[] -> {type:video}.
    # Keep the LAST hit (model_output follows user_input). Falls back to the
    # older output_video shape, then a tolerant recursive scan.
    param($Parsed)

    $found = $null
    $steps = Get-Prop $Parsed @('steps')
    if ($steps) {
        foreach ($step in @($steps)) {
            $content = Get-Prop $step @('content')
            if ($content) {
                foreach ($item in @($content)) {
                    if (Test-VideoMap $item) { $found = $item }
                }
            }
        }
    }
    if ($found) { return $found }

    $ov = Get-Prop $Parsed @('output_video')
    if ($ov -and (Test-VideoMap ([pscustomobject]@{
        type = 'video'
        data = (Get-Prop $ov @('data'))
        uri  = (Get-Prop $ov @('uri'))
    }))) {
        # output_video has no 'type' key itself - accept it if it has data|uri.
    }
    if ($ov) {
        $names = $ov.PSObject.Properties.Name
        if (($names -contains 'data') -or ($names -contains 'uri')) { return $ov }
    }

    return Search-AnyVideo $Parsed
}

function Test-TextMap {
    param($Node)
    if ($null -eq $Node -or $Node -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $names = $Node.PSObject.Properties.Name
    return (($names -contains 'type') -and ("$($Node.type)" -eq 'text') -and ($names -contains 'text'))
}

function Find-TextItem {
    # Same walk-and-keep-last strategy as Find-VideoItem, for a text response.
    param($Parsed)
    $found = $null
    $steps = Get-Prop $Parsed @('steps')
    if ($steps) {
        foreach ($step in @($steps)) {
            $content = Get-Prop $step @('content')
            if ($content) {
                foreach ($item in @($content)) {
                    if (Test-TextMap $item) { $found = $item.text }
                }
            }
        }
    }
    if ($found) { return $found }
    return Get-Prop $Parsed @('output_text')
}

function Wait-OmniFileActive {
    # Poll GET /files/{id} until ACTIVE (returns downloadUri or $null),
    # FAILED (throws), or the deadline (throws). HTTP error statuses are
    # terminal; network errors without a response keep polling.
    param(
        [string]$FileId,
        [string]$ApiKey,
        [object]$Config,
        [int]$IntervalSeconds,
        [int]$TimeoutSeconds,
        [string]$TimeoutMessage
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $state = $null
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Get `
                -Uri "$($Config.endpointBase.TrimEnd('/'))/files/$FileId" `
                -Headers @{ 'x-goog-api-key' = $ApiKey } `
                -TimeoutSec 60
            $info = $null
            try { $info = $resp.Content | ConvertFrom-Json } catch { }
            $state = Get-Prop $info @('state')
            if (-not $state) { $state = 'PROCESSING' }
            if ("$state" -eq 'ACTIVE') {
                return (Get-Prop $info @('downloadUri', 'download_uri'))
            }
            if ("$state" -eq 'FAILED') {
                $msg = Get-Prop (Get-Prop $info @('error')) @('message')
                if (-not $msg) { $msg = 'Generation failed server-side.' }
                throw $msg
            }
            # else PROCESSING - fall through to sleep
        } catch {
            $status = Get-HttpStatus $_
            if ($status -eq 404) {
                throw "This generation's file expired server-side - retry to generate again."
            }
            if ($null -ne $status) { throw (Resolve-ApiError $_) }
            if ("$state" -eq 'FAILED') { throw }   # re-throw the FAILED message above
            # Transient network error - keep polling until the deadline.
        }
        if ((Get-Date) -ge $deadline) { throw $TimeoutMessage }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Invoke-OmniDownload {
    param([string]$Url, [string]$ApiKey, [string]$OutFile, [object]$Config)
    try {
        Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Url `
            -Headers @{ 'x-goog-api-key' = $ApiKey } `
            -OutFile $OutFile -TimeoutSec ([int]$Config.timeoutSeconds)
    } catch {
        throw "Couldn't download the generated video."
    }
}

function Invoke-OmniFilesUpload {
    # Files API resumable upload: start (session URL in a response header) ->
    # upload+finalize -> poll until ACTIVE. Returns the file uri.
    param([string]$FilePath, [string]$ApiKey, [object]$Config)

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $mime = Get-VideoMime $FilePath
    $displayName = Split-Path $FilePath -Leaf
    $startBody = ConvertTo-Json -InputObject @{ file = @{ display_name = $displayName } } -Depth 4

    try {
        $start = Invoke-WebRequest -UseBasicParsing -Method Post `
            -Uri $Config.uploadEndpointBase `
            -Headers @{
                'x-goog-api-key'                     = $ApiKey
                'X-Goog-Upload-Protocol'             = 'resumable'
                'X-Goog-Upload-Command'              = 'start'
                'X-Goog-Upload-Header-Content-Length' = "$($bytes.Length)"
                'X-Goog-Upload-Header-Content-Type'  = $mime
            } `
            -ContentType 'application/json' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($startBody)) `
            -TimeoutSec 120
    } catch {
        $status = Get-HttpStatus $_
        if ($null -eq $status) { throw $script:NetworkErrorMsg }
        throw (Resolve-ApiError $_)
    }

    $uploadUrl = Get-HeaderValue $start.Headers 'x-goog-upload-url'
    if (-not $uploadUrl) { throw "Upload session couldn't be started." }

    try {
        $done = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uploadUrl `
            -Headers @{
                'X-Goog-Upload-Offset'  = '0'
                'X-Goog-Upload-Command' = 'upload, finalize'
            } `
            -Body $bytes -TimeoutSec ([int]$Config.timeoutSeconds)
    } catch {
        $status = Get-HttpStatus $_
        if ($null -eq $status) { throw $script:NetworkErrorMsg }
        throw (Resolve-ApiError $_)
    }

    $info = $null
    try { $info = $done.Content | ConvertFrom-Json } catch {
        throw 'Upload finished but the response was unreadable.'
    }
    $uri = Get-Prop (Get-Prop $info @('file')) @('uri')
    if (-not $uri) { throw 'Upload response had no file uri.' }

    # Wait for server-side processing before referencing the file.
    $fileId = Get-FileIdFromUri $uri
    [void](Wait-OmniFileActive -FileId $fileId -ApiKey $ApiKey -Config $Config `
        -IntervalSeconds ([int]$Config.uploadPollIntervalSeconds) `
        -TimeoutSeconds ([int]$Config.uploadPollTimeoutSeconds) `
        -TimeoutMessage 'Video upload processing timed out - retry the job.')
    return $uri
}

# ---------------------------------------------------------------------------
# Sequence mode (Stage 3): FFmpeg split, batch expansion, prompt walking with
# last-frame continuity. New ground - unverified against the live API; the
# vision text-interaction shape below is best-effort, modeled on the proven
# video-interaction shapes above.
# ---------------------------------------------------------------------------

function Invoke-OmniTool {
    # Runs an external tool (ffmpeg/ffprobe) and captures stdout/stderr/exit
    # code. A missing executable is surfaced naming both config keys.
    param([string]$Exe, [string]$Arguments, [string]$WorkingDirectory)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        throw "'$Exe' not found. Set 'ffmpegPath'/'ffprobePath' in config.cfg or add ffmpeg/ffprobe to PATH."
    }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Get-VideoDuration {
    param([string]$FfprobePath, [string]$InputPath)
    $r = Invoke-OmniTool -Exe $FfprobePath `
        -Arguments "-v error -show_entries format=duration -of csv=p=0 `"$InputPath`"" `
        -WorkingDirectory (Split-Path $InputPath -Parent)
    $text = $r.StdOut.Trim()
    $dur = 0.0
    $ok = [double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)
    if ($r.ExitCode -ne 0 -or -not $ok -or $dur -le 0) {
        $msg = if ($r.StdErr.Trim()) { $r.StdErr.Trim() } else { 'ffprobe returned no readable duration' }
        throw "Could not read duration of '$InputPath': $msg"
    }
    return $dur
}

function Split-OmniVideo {
    param(
        [string]$FfmpegPath, [string]$InputPath, [string]$SegmentsDir,
        [int]$SegmentSeconds, [string]$BaseName, [bool]$Force
    )

    if (-not (Test-Path -LiteralPath $SegmentsDir)) {
        New-Item -ItemType Directory -Path $SegmentsDir -Force | Out-Null
    }
    $pattern = Join-Path $SegmentsDir "$BaseName-%03d.mp4"
    $existing = @(Get-ChildItem -LiteralPath $SegmentsDir -Filter "$BaseName-*.mp4" -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($existing.Count -gt 0 -and -not $Force) {
        return @($existing | ForEach-Object { $_.FullName })
    }
    foreach ($f in $existing) { Remove-Item -LiteralPath $f.FullName -Force }

    $r = Invoke-OmniTool -Exe $FfmpegPath `
        -Arguments "-y -i `"$InputPath`" -c copy -map 0 -segment_time $SegmentSeconds -f segment -reset_timestamps 1 `"$pattern`"" `
        -WorkingDirectory $SegmentsDir
    if ($r.ExitCode -ne 0) {
        # Stream copy failed on a keyframe boundary - re-encode instead.
        $r2 = Invoke-OmniTool -Exe $FfmpegPath `
            -Arguments "-y -i `"$InputPath`" -c:v libx264 -preset veryfast -c:a aac -map 0 -segment_time $SegmentSeconds -f segment -reset_timestamps 1 `"$pattern`"" `
            -WorkingDirectory $SegmentsDir
        if ($r2.ExitCode -ne 0) {
            $msg = if ($r2.StdErr.Trim()) { $r2.StdErr.Trim() } else { $r.StdErr.Trim() }
            throw "ffmpeg could not split '$InputPath': $msg"
        }
    }

    $produced = @(Get-ChildItem -LiteralPath $SegmentsDir -Filter "$BaseName-*.mp4" -File | Sort-Object Name)
    if ($produced.Count -eq 0) { throw "ffmpeg produced no segments for '$InputPath'." }
    return @($produced | ForEach-Object { $_.FullName })
}

function Get-LastFrame {
    param([string]$FfmpegPath, [string]$VideoPath, [string]$OutFramePath)
    $dir = Split-Path $OutFramePath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $r = Invoke-OmniTool -Exe $FfmpegPath `
        -Arguments "-y -sseof -0.05 -i `"$VideoPath`" -frames:v 1 -update 1 `"$OutFramePath`"" `
        -WorkingDirectory (Split-Path $VideoPath -Parent)
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutFramePath)) {
        throw "ffmpeg could not extract the last frame of '$VideoPath': $($r.StdErr.Trim())"
    }
}

function Get-FrameDescription {
    param([string]$FramePath, [string]$ModelId, [string]$ApiKey, [object]$Config)
    $ext = [System.IO.Path]::GetExtension($FramePath).ToLowerInvariant()
    $body = [ordered]@{
        model = $ModelId
        input = @(
            [ordered]@{
                type      = 'image'
                data      = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($FramePath))
                mime_type = $script:ImageMimes[$ext]
            },
            [ordered]@{
                type = 'text'
                text = 'Describe this image in at most 60 words, focusing on scene, subject, and action, to help continue a video from this frame.'
            }
        )
        response_format = [ordered]@{ type = 'text' }
        background      = $false
        store           = $false
        stream          = $false
    }
    $bodyJson = ConvertTo-Json -InputObject $body -Depth 8
    $result = Invoke-OmniInteraction -BodyJson $bodyJson -ApiKey $ApiKey -Config $Config
    $text = $null
    if ($result.Parsed) { $text = Find-TextItem $result.Parsed }
    if (-not $text) { return '' }
    return "$text".Trim()
}

function Expand-OmniSequences {
    # Replaces each Split job with its per-segment edit jobs before the queue
    # runs. Dry-run probes duration (ffprobe) but never splits (ffmpeg).
    param([object[]]$Jobs, [object]$Config, [string]$OutDir, [int]$CatalogWidth, [bool]$DryRun, [bool]$Force)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($job in @($Jobs)) {
        if (-not $job.Split -or $job.Errors.Count -gt 0) {
            [void]$result.Add($job)
            continue
        }

        $segmentSeconds = if ($job.SegmentSeconds -gt 0) { $job.SegmentSeconds } else { [int]$Config.generationSeconds }
        $walk = if ($null -ne $job.Walk) { [bool]$job.Walk } else { $true }
        $vision = if ($null -ne $job.Vision) { [bool]$job.Vision } else { $walk }
        $slug = ConvertTo-Slug -Text $job.Title -MaxLength ([int]$Config.slugMaxLength)
        $parentNum = $job.Index.ToString().PadLeft($CatalogWidth, '0')
        $baseName = "$parentNum-$slug"
        $segmentsDir = Join-Path $OutDir 'segments'
        $framesDir = Join-Path $OutDir 'frames'

        $segmentPaths = $null
        try {
            if ($DryRun) {
                $duration = Get-VideoDuration -FfprobePath $Config.ffprobePath -InputPath $job.Split
                $count = [int][Math]::Max(1, [Math]::Ceiling($duration / $segmentSeconds))
                $planned = New-Object System.Collections.Generic.List[string]
                for ($k = 1; $k -le $count; $k++) {
                    [void]$planned.Add((Join-Path $segmentsDir ('{0}-{1:D3}.mp4' -f $baseName, $k)))
                }
                $segmentPaths = @($planned)
            } else {
                $segmentPaths = Split-OmniVideo -FfmpegPath $Config.ffmpegPath -InputPath $job.Split `
                    -SegmentsDir $segmentsDir -SegmentSeconds $segmentSeconds -BaseName $baseName -Force $Force
            }
        } catch {
            [void]$job.Errors.Add($_.Exception.Message)
            [void]$result.Add($job)
            continue
        }

        $segWidth = [Math]::Max(2, "$($segmentPaths.Count)".Length)
        for ($i = 0; $i -lt $segmentPaths.Count; $i++) {
            $k = $i + 1
            $seg = New-OmniJob -Idx $job.Index -Title $job.Title
            $seg.Prompt = $job.Prompt
            $seg.Task = 'edit'
            $seg.Aspect = $job.Aspect
            $seg.Delivery = $job.Delivery
            $seg.Source = $segmentPaths[$i]
            $seg.IsSequenceSegment = $true
            $seg.SeqParentIndex = $job.Index
            $seg.SeqIndex = $k
            $seg.SeqCount = $segmentPaths.Count
            $seg.SeqSegmentPath = $segmentPaths[$i]
            $seg.Walk = $walk
            $seg.Vision = $vision
            if ($k -gt 1 -and $walk) {
                $segNum = $k.ToString().PadLeft($segWidth, '0')
                $seg.SeqFramePath = Join-Path $framesDir "$baseName-$segNum-first.png"
            }
            [void]$result.Add($seg)
        }
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Edit-from resolution
# ---------------------------------------------------------------------------

function Get-SidecarInteractionId {
    param([string]$SidecarPath)
    if (-not (Test-Path -LiteralPath $SidecarPath)) {
        throw "Edit-from sidecar not found: $SidecarPath"
    }
    $side = Get-Content -LiteralPath $SidecarPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $id = Get-Prop $side @('interactionId', 'interaction_id')
    if (-not $id) { throw 'That output has no interaction id to chain from.' }
    return "$id"
}

function Resolve-EditFrom {
    param(
        [string]$Value,
        [object[]]$AllJobs,
        [hashtable]$RunResults,   # index -> interactionId, this run
        [string]$OutDir,
        [int]$SlugMaxLength,
        [int]$NumWidth
    )

    if ($Value -match '^#(\d+)$') {
        $n = [int]$Matches[1]
        if ($RunResults.ContainsKey($n)) { return $RunResults[$n] }
        $target = $AllJobs | Where-Object { $_.Index -eq $n }
        if (-not $target) { throw "Edit-from #$n does not exist in this catalogue." }
        $slug = ConvertTo-Slug -Text $target.Title -MaxLength $SlugMaxLength
        $side = Join-Path $OutDir ("{0}-{1}.json" -f $n.ToString().PadLeft($NumWidth, '0'), $slug)
        if (-not (Test-Path -LiteralPath $side)) {
            throw "Job #$n has not completed in this run and no sidecar was found at $side"
        }
        return Get-SidecarInteractionId $side
    }
    if ($Value -match '(?i)\.json$') {
        return Get-SidecarInteractionId $Value
    }
    if ($script:VideoExts -contains [System.IO.Path]::GetExtension($Value).ToLowerInvariant()) {
        return Get-SidecarInteractionId ([System.IO.Path]::ChangeExtension($Value, '.json'))
    }
    return $Value   # literal interaction id
}

# ---------------------------------------------------------------------------
# Generation queue
# ---------------------------------------------------------------------------

function Get-JobMediaNote {
    param([object]$Job)
    $bits = New-Object System.Collections.Generic.List[string]
    if ($Job.Aspect) { [void]$bits.Add($Job.Aspect) }
    if ($Job.IsSequenceSegment) { [void]$bits.Add("seq $($Job.SeqIndex)/$($Job.SeqCount)") }
    if ($Job.Image -and $Job.Refs.Count -gt 0) {
        [void]$bits.Add("image + $($Job.Refs.Count) refs")
    } elseif ($Job.Image) {
        [void]$bits.Add("image: $(Split-Path $Job.Image -Leaf)")
    }
    if ($Job.Source) {
        $size = ''
        if (Test-Path -LiteralPath $Job.Source) {
            $size = ' ({0:n1} MB)' -f ((Get-Item -LiteralPath $Job.Source).Length / 1MB)
        }
        $label = if ($Job.IsSequenceSegment) { 'segment' } else { 'upload' }
        [void]$bits.Add("${label}: $(Split-Path $Job.Source -Leaf)$size")
    }
    if ($Job.IsSequenceSegment -and $Job.SeqFramePath) { [void]$bits.Add('first frame <- previous output') }
    if ($Job.EditFrom) { [void]$bits.Add("chain: $($Job.EditFrom)") }
    if ($bits.Count -eq 0) { return '' }
    return '  ' + ($bits -join '  ')
}

function Get-TaskTag {
    param([string]$Task)
    switch ($Task) {
        'text_to_video'      { return '[t2v]' }
        'image_to_video'     { return '[i2v]' }
        'reference_to_video' { return '[r2v]' }
        'edit'               { return '[edit]' }
        default              { return '[?]' }
    }
}

function Invoke-JobQueue {
    param(
        [object[]]$Jobs,
        [string]$OutDir,
        [string]$DisplayName,
        [object]$Config,
        [string]$ApiKey,
        [string]$ModelId,
        [string]$DefAspect,
        [string]$DefDelivery,
        [int]$Index,
        [int]$Limit,
        [bool]$Force,
        [bool]$DryRun,
        [hashtable]$Totals
    )

    Write-Host ''
    Write-Host "=== $DisplayName ===" -ForegroundColor Cyan

    $Jobs = @($Jobs)
    if ($Jobs.Count -eq 0) {
        Write-Warning "No jobs found in '$DisplayName'."
        return
    }

    # Catalog width is fixed by the pre-expansion job count, so NN numbering
    # (and Edit-from #N) stays stable regardless of how many segments a Split
    # job expands into.
    $catalogWidth = [Math]::Max(2, "$($Jobs.Count)".Length)
    $Jobs = Expand-OmniSequences -Jobs $Jobs -Config $Config -OutDir $OutDir -CatalogWidth $catalogWidth -DryRun $DryRun -Force $Force

    Write-Host "Jobs: $($Jobs.Count)   ->   output: $OutDir" -ForegroundColor DarkGray

    if (-not $DryRun -and -not (Test-Path -LiteralPath $OutDir)) {
        [void](New-Item -ItemType Directory -Path $OutDir -Force)
    }

    $width = $catalogWidth
    $runResults = @{}      # catalogue index -> interactionId (this run)
    $seqLastOutput = @{}   # sequence parent index -> last successful segment output path

    # Select which jobs to act on (numbering stays based on the full set).
    $selected = $Jobs
    if ($Index -gt 0) {
        $selected = $Jobs | Where-Object { $_.Index -eq $Index }
        if (-not $selected) { Write-Warning "No job at index $Index (set has $($Jobs.Count))."; return }
    }
    if ($Limit -gt 0) {
        $selected = $selected | Select-Object -First $Limit
    }

    foreach ($job in @($selected)) {
        $slug = ConvertTo-Slug -Text $job.Title -MaxLength ([int]$Config.slugMaxLength)
        if ($job.IsSequenceSegment) {
            $segWidth = [Math]::Max(2, "$($job.SeqCount)".Length)
            $num = "$($job.Index.ToString().PadLeft($width, '0'))-$($job.SeqIndex.ToString().PadLeft($segWidth, '0'))"
        } else {
            $num = $job.Index.ToString().PadLeft($width, '0')
        }
        $baseName = "$num-$slug"
        $tag = Get-TaskTag $job.Task
        $note = Get-JobMediaNote $job
        $effAspect = if ($job.Aspect) { $job.Aspect } else { $DefAspect }
        $effDelivery = if ($job.Delivery) { $job.Delivery } else { $DefDelivery }

        if ($DryRun) {
            Write-Host ("  [{0}] {1,-34} {2}{3}" -f $num, $job.Title, $tag, $note) -ForegroundColor White
            Write-Host ("        -> {0}.mp4   ({1} chars)" -f $baseName, $job.Prompt.Length) -ForegroundColor DarkGray
            if ($job.Errors.Count -gt 0) {
                foreach ($e in $job.Errors) {
                    Write-Host ("        !! {0}" -f $e) -ForegroundColor Red
                }
                $Totals.Failed++
            } else {
                $Totals.Planned++
            }
            continue
        }

        $outFile = Join-Path $OutDir "$baseName.mp4"
        if ((Test-Path -LiteralPath $outFile) -and -not $Force) {
            Write-Host ("  [{0}] SKIP (exists): {1}.mp4" -f $num, $baseName) -ForegroundColor Yellow
            $Totals.Skipped++
            continue
        }

        Write-Host ("  [{0}] {1,-34} {2}" -f $num, $job.Title, $tag) -ForegroundColor White

        # Validation errors fail immediately - no retry, no API call.
        if ($job.Errors.Count -gt 0) {
            foreach ($e in $job.Errors) {
                Write-Host ("        FAILED: {0}" -f $e) -ForegroundColor Red
            }
            $Totals.Failed++
            continue
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Resolve the edit chain up front (not retryable).
        $previousId = ''
        if ($job.EditFrom) {
            try {
                $previousId = Resolve-EditFrom -Value $job.EditFrom -AllJobs $Jobs `
                    -RunResults $runResults -OutDir $OutDir `
                    -SlugMaxLength ([int]$Config.slugMaxLength) -NumWidth $width
            } catch {
                Write-Host ("        FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                $Totals.Failed++
                continue
            }
        }

        # Sequence walk (Stage 3): drive segment k>1 from the last successful
        # segment's output - the in-run cache first, then a resume-safe scan of
        # disk for the nearest earlier segment that already completed.
        if ($job.IsSequenceSegment -and $job.SeqIndex -gt 1 -and [bool]($job.Walk)) {
            $driveSrc = $null
            if ($seqLastOutput.ContainsKey($job.SeqParentIndex) -and (Test-Path -LiteralPath $seqLastOutput[$job.SeqParentIndex])) {
                $driveSrc = $seqLastOutput[$job.SeqParentIndex]
            } else {
                $segWidthLocal = [Math]::Max(2, "$($job.SeqCount)".Length)
                $parentNumStr = $job.Index.ToString().PadLeft($width, '0')
                for ($j = $job.SeqIndex - 1; $j -ge 1 -and -not $driveSrc; $j--) {
                    $candidate = Join-Path $OutDir "$parentNumStr-$slug-$($j.ToString().PadLeft($segWidthLocal, '0')).mp4"
                    if (Test-Path -LiteralPath $candidate) { $driveSrc = $candidate }
                }
            }

            if ($driveSrc) {
                try {
                    Get-LastFrame -FfmpegPath $Config.ffmpegPath -VideoPath $driveSrc -OutFramePath $job.SeqFramePath
                    $job.Image = $job.SeqFramePath
                    if ([bool]($job.Vision)) {
                        Write-Host '        describing last frame...' -ForegroundColor DarkGray
                        $job.SeqVisionText = Get-FrameDescription -FramePath $job.SeqFramePath -ModelId $ModelId -ApiKey $ApiKey -Config $Config
                        if ($job.SeqVisionText) {
                            $job.Prompt = "$($job.Prompt)`nContinue from this scene: $($job.SeqVisionText)"
                        }
                    }
                } catch {
                    Write-Host ("        FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                    $Totals.Failed++
                    continue
                }
            }
        }

        $partFile = "$outFile.part"
        if (Test-Path -LiteralPath $partFile) { Remove-Item -LiteralPath $partFile -Force }

        $attempt = 0
        $succeeded = $false
        $uploadedUri = ''    # cached across attempts within this job
        $interactionId = $null
        $fileId = $null

        while ($true) {
            $attempt++
            try {
                # Upload the source video if this is an upload-edit (once per job;
                # a failed upload is retried on the next attempt).
                if ($job.Source -and -not $uploadedUri) {
                    $srcMb = '{0:n1}' -f ((Get-Item -LiteralPath $job.Source).Length / 1MB)
                    Write-Host ("        uploading {0} ({1} MB)..." -f (Split-Path $job.Source -Leaf), $srcMb) -ForegroundColor DarkGray
                    $upSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $uploadedUri = Invoke-OmniFilesUpload -FilePath $job.Source -ApiKey $ApiKey -Config $Config
                    $upSw.Stop()
                    Write-Host ("        uploaded ({0}, {1:n1}s)" -f (Get-FileIdFromUri $uploadedUri), $upSw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
                }

                $bodyJson = Build-OmniRequestBody -Job $job -ModelId $ModelId `
                    -EffAspect $effAspect -EffDelivery $effDelivery `
                    -Store ([bool]$Config.store) -UploadedUri $uploadedUri `
                    -PreviousInteractionId $previousId

                Write-Host '        generating...' -ForegroundColor DarkGray
                $result = Invoke-OmniInteraction -BodyJson $bodyJson -ApiKey $ApiKey -Config $Config
                $parsed = $result.Parsed

                $interactionId = $null
                if ($parsed) { $interactionId = Get-Prop $parsed @('id') }

                # Anything other than a happy terminal status is surfaced with
                # the API's own message where available.
                $statusField = Get-Prop $parsed @('status')
                if ($statusField -and @('failed', 'error', 'cancelled') -contains "$statusField") {
                    $msg = Get-Prop (Get-Prop $parsed @('error')) @('message')
                    if (-not $msg) { $msg = 'Gemini reported the generation failed.' }
                    throw $msg
                }

                $video = $null
                if ($parsed) { $video = Find-VideoItem $parsed }
                if (-not $video) {
                    if ([bool]$Config.saveResponseJson) {
                        $dump = Join-Path $OutDir "$baseName-response.json"
                        Set-Content -LiteralPath $dump -Value $result.Raw -Encoding UTF8
                        throw "Gemini's response didn't include a video - raw response saved to $dump for inspection."
                    }
                    throw 'Gemini returned no video in its response.'
                }

                $fileId = $null
                $data = Get-Prop $video @('data')
                if ($data) {
                    $videoBytes = [Convert]::FromBase64String("$data")
                    [System.IO.File]::WriteAllBytes($partFile, $videoBytes)
                } else {
                    $uri = Get-Prop $video @('uri')
                    $fileId = Get-FileIdFromUri "$uri"
                    Write-Host ("        polling files/{0}..." -f $fileId) -ForegroundColor DarkGray
                    $pollSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $downloadUri = Wait-OmniFileActive -FileId $fileId -ApiKey $ApiKey -Config $Config `
                        -IntervalSeconds ([int]$Config.pollIntervalSeconds) `
                        -TimeoutSeconds ([int]$Config.pollTimeoutSeconds) `
                        -TimeoutMessage 'Generation is taking longer than expected - check back later or retry.'
                    $pollSw.Stop()
                    Write-Host ("        ACTIVE after {0:n0}s, downloading..." -f $pollSw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
                    if (-not $downloadUri) {
                        $downloadUri = "$($Config.endpointBase.TrimEnd('/'))/files/${fileId}:download?alt=media"
                    }
                    Invoke-OmniDownload -Url $downloadUri -ApiKey $ApiKey -OutFile $partFile -Config $Config
                }

                # Atomic completion: video into place, then the sidecar.
                Move-Item -LiteralPath $partFile -Destination $outFile -Force
                $succeeded = $true
                break
            } catch {
                $msg = $_.Exception.Message
                if (Test-Path -LiteralPath $partFile) { Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue }
                # Deterministic input-safety blocks can never pass on retry.
                $nonRetryable = $msg -match '(?i)input blocked|prohibited use policy'
                if ($nonRetryable -or $attempt -gt [int]$Config.maxRetries) {
                    Write-Host ("        FAILED: {0}" -f $msg) -ForegroundColor Red
                    $Totals.Failed++
                    break
                }
                $backoff = [Math]::Min(30, 3 * $attempt)
                Write-Host ("        attempt {0} failed: {1} - retrying in {2}s" -f $attempt, $msg, $backoff) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $backoff
            }
        }

        if (-not $succeeded) { continue }
        $sw.Stop()

        if ($interactionId) { $runResults[$job.Index] = "$interactionId" }
        if ($job.IsSequenceSegment) { $seqLastOutput[$job.SeqParentIndex] = $outFile }

        if ([bool]$Config.saveJobSidecar) {
            $sidecar = [ordered]@{
                title                 = $job.Title
                index                 = $job.Index
                task                  = $job.Task
                prompt                = $job.Prompt
                model                 = $ModelId
                aspectRatio           = $(if ($job.Task -eq 'edit') { $null } else { $effAspect })
                delivery              = $effDelivery
                interactionId         = $(if ($interactionId) { "$interactionId" } else { $null })
                fileId                = $(if ($fileId) { "$fileId" } else { $null })
                previousInteractionId = $(if ($previousId) { $previousId } else { $null })
                image                 = $(if ($job.Image) { $job.Image } else { $null })
                references            = @($job.Refs)
                sourceVideo           = $(if ($job.Source) { $job.Source } else { $null })
                videoFile             = "$baseName.mp4"
                createdAt             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                elapsedSeconds        = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
                status                = 'completed'
            }
            if ($job.IsSequenceSegment) {
                $sidecar['sequence'] = [ordered]@{
                    parent         = $job.SeqParentIndex
                    index          = $job.SeqIndex
                    count          = $job.SeqCount
                    segmentPath    = $job.SeqSegmentPath
                    firstFramePath = $(if ($job.SeqFramePath) { $job.SeqFramePath } else { $null })
                    visionText     = $(if ($job.SeqVisionText) { $job.SeqVisionText } else { $null })
                }
            }
            $sideJson = ConvertTo-Json -InputObject $sidecar -Depth 5
            Set-Content -LiteralPath (Join-Path $OutDir "$baseName.json") -Value $sideJson -Encoding UTF8
        }

        $sizeKb = [Math]::Round((Get-Item -LiteralPath $outFile).Length / 1KB, 0)
        Write-Host ("        OK  {0}.mp4  ({1:n0} KB, {2:n1}s)" -f $baseName, $sizeKb, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
        $Totals.Generated++

        if ([int]$Config.delayBetweenJobsSeconds -gt 0) {
            Start-Sleep -Seconds ([int]$Config.delayBetweenJobsSeconds)
        }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$config = Get-OmniConfig -ConfigPath $ConfigPath

$effModel = if ($Model) { $Model } else { $config.model }
$effAspect = if ($AspectRatio) { $AspectRatio } else { "$($config.defaultAspectRatio)" }
$effDelivery = if ($Delivery) { $Delivery } else { "$($config.defaultDelivery)" }

# Resolve API key (only strictly required when actually generating).
$effKey = $ApiKey
if (-not $effKey) { $effKey = $config.apiKey }
if (-not $effKey) { $effKey = $env:GEMINI_API_KEY }
if (-not $effKey) { $effKey = $env:OMNI_API_KEY }

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($effKey)) {
    throw "No API key. Set 'apiKey' in config.cfg, pass -ApiKey, or set `$env:GEMINI_API_KEY / `$env:OMNI_API_KEY."
}

if ($Manifest -and $Path) {
    throw 'Provide either -Path or -Manifest, not both.'
}
if (-not $Manifest -and -not $Path) {
    throw 'Provide -Path <markdown-or-folder> or -Manifest <json>.'
}

$modeLabel = if ($Manifest) { 'MANIFEST (Claude-extracted)' } else { 'MARKDOWN' }
Write-Host 'Omni Producer' -ForegroundColor Magenta
Write-Host ("Model: {0}   Aspect: {1}   Delivery: {2}   Mode: {3}   {4}" -f `
    $effModel, $effAspect, $effDelivery, $modeLabel, ($(if ($DryRun) { 'DRY-RUN' } else { 'GENERATE' }))) -ForegroundColor DarkGray

$totals = @{ Planned = 0; Generated = 0; Skipped = 0; Failed = 0 }

if ($Manifest) {
    $mfPath = (Resolve-Path -LiteralPath $Manifest).Path
    $mfData = Read-OmniManifest -ManifestPath $mfPath
    Invoke-JobQueue -Jobs $mfData.Jobs -OutDir $mfData.OutDir -DisplayName $mfData.DisplayName `
        -Config $config -ApiKey $effKey -ModelId $effModel `
        -DefAspect $effAspect -DefDelivery $effDelivery `
        -Index $Index -Limit $Limit -Force:$Force -DryRun:$DryRun -Totals $totals
} else {
    $resolved = Resolve-Path -LiteralPath $Path
    $item = Get-Item -LiteralPath $resolved
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $item.FullName -Filter '*.md' -File -Recurse:$Recurse |
            Sort-Object FullName
    } else {
        $files = @($item)
    }

    if (-not $files -or @($files).Count -eq 0) {
        throw "No .md files found at '$Path'."
    }

    foreach ($f in $files) {
        $lines = Get-Content -LiteralPath $f.FullName -Encoding UTF8
        $jobs = Get-VideoJobs -Lines $lines -BaseDir $f.DirectoryName
        $outDir = Join-Path $f.DirectoryName (Get-OutputFolderName -FileBaseName $f.BaseName)
        Invoke-JobQueue -Jobs $jobs -OutDir $outDir -DisplayName $f.Name `
            -Config $config -ApiKey $effKey -ModelId $effModel `
            -DefAspect $effAspect -DefDelivery $effDelivery `
            -Index $Index -Limit $Limit -Force:$Force -DryRun:$DryRun -Totals $totals
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host ("Dry run complete. {0} job(s) would be generated." -f $totals.Planned) -ForegroundColor Magenta
    if ($totals.Failed -gt 0) {
        Write-Host ("{0} job(s) have validation errors (marked !!)." -f $totals.Failed) -ForegroundColor Red
        exit 1
    }
    exit 0
} else {
    Write-Host ("Done. Generated: {0}  Skipped: {1}  Failed: {2}" -f `
        $totals.Generated, $totals.Skipped, $totals.Failed) -ForegroundColor Magenta
    if ($totals.Failed -gt 0) { exit 1 }
    exit 0
}
