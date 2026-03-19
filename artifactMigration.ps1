<#
.SYNOPSIS
    Migrates NuGet artifacts (.nupkg / .snupkg) from GitLab CI/CD job artifacts
    to an Azure DevOps Artifacts feed.

.DESCRIPTION
    This script:
    1. Queries the GitLab API for projects (single or multiple).
    2. For each project, retrieves all CI/CD jobs that produced artifacts.
    3. Downloads each artifact ZIP.
    4. Extracts .nupkg and .snupkg files from the ZIP (expected path: artifacts/nuget/*.nupkg).
    5. Pushes each package to an Azure DevOps NuGet feed using 'dotnet nuget push'.

.PARAMETER GitLabUrl
    Base URL of your GitLab instance (e.g., https://gitlab.com).

.PARAMETER GitLabToken
    GitLab Personal Access Token with at least 'read_api' scope.

.PARAMETER ProjectIds
    Array of GitLab project IDs to migrate. Use @(123) for a single project or @(123, 456, 789) for multiple.

.PARAMETER ADOFeedUrl
    The Azure DevOps NuGet feed source URL.
    Example: https://pkgs.dev.azure.com/{org}/{project}/_packaging/{feed}/nuget/v3/index.json

.PARAMETER ADOPat
    Azure DevOps Personal Access Token with 'Packaging (Read & Write)' permissions.

.PARAMETER TempDir
    Temporary directory for downloading and extracting artifacts. Default: .\temp_artifacts

.PARAMETER SkipDuplicates
    If set, the script will continue (with a warning) when a package version already exists in the feed.
    This is enabled by default.

.PARAMETER JobNameFilter
    Optional regex pattern to filter jobs by name (e.g., "^pack" or "nuget"). 
    If not specified, all jobs with artifacts are processed.

.PARAMETER DryRun
    If set, the script will list all packages it would migrate without actually pushing them.

.EXAMPLE
    # Single project (demo)
    .\Migrate-GitLabNuGetToADO.ps1 `
        -GitLabUrl "https://gitlab.com" `
        -GitLabToken "glpat-xxxxxxxxxxxx" `
        -ProjectIds @(42) `
        -ADOFeedUrl "https://pkgs.dev.azure.com/Organization/MyProject/_packaging/NuGetFeed/nuget/v3/index.json" `
        -ADOPat "ado-pat-xxxxxxxxxxxx"

.EXAMPLE
    # Multiple projects (full migration)
    .\Migrate-GitLabNuGetToADO.ps1 `
        -GitLabUrl "https://gitlab.com" `
        -GitLabToken "glpat-xxxxxxxxxxxx" `
        -ProjectIds @(42, 55, 78, 101) `
        -ADOFeedUrl "https://pkgs.dev.azure.com/Organization/MyProject/_packaging/NuGetFeed/nuget/v3/index.json" `
        -ADOPat "ado-pat-xxxxxxxxxxxx"

.EXAMPLE
    # Dry run to preview what would be migrated
    .\Migrate-GitLabNuGetToADO.ps1 `
        -GitLabUrl "https://gitlab.com" `
        -GitLabToken "glpat-xxxxxxxxxxxx" `
        -ProjectIds @(42) `
        -ADOFeedUrl "https://pkgs.dev.azure.com/Organization/MyProject/_packaging/NuGetFeed/nuget/v3/index.json" `
        -ADOPat "ado-pat-xxxxxxxxxxxx" `
        -DryRun

.NOTES
    Author  : Ben Coteur
    Date    : 2026-03-12
    Requires: dotnet CLI (for 'dotnet nuget push')
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitLabUrl,

    [Parameter(Mandatory = $true)]
    [string]$GitLabToken,

    [Parameter(Mandatory = $true)]
    [long[]]$ProjectIds,

    [Parameter(Mandatory = $true)]
    [string]$ADOFeedUrl,

    [Parameter(Mandatory = $true)]
    [string]$ADOPat,

    [string]$TempDir = ".\temp_artifacts",

    [switch]$SkipDuplicates = $true,

    [string]$JobNameFilter = "",

    [switch]$DryRun
)

# ──────────────────────────────────────────────
# CONFIGURATION & SETUP
# ──────────────────────────────────────────────

$ErrorActionPreference = "Stop"

# Ensure base URL has no trailing slash
$GitLabUrl = $GitLabUrl.TrimEnd('/')

# GitLab API headers
$GitLabHeaders = @{
    "PRIVATE-TOKEN" = $GitLabToken
}

# Stats tracking
$stats = @{
    ProjectsProcessed = 0
    JobsProcessed     = 0
    PackagesFound     = 0
    PackagesPushed    = 0
    PackagesSkipped   = 0
    Errors            = 0
}

# Logging helper
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colors = @{
        INFO    = "Cyan"
        WARN    = "Yellow"
        ERROR   = "Red"
        SUCCESS = "Green"
        DEBUG   = "Gray"
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}


function Invoke-GitLabApi {
    param(
        [string]$Endpoint,
        [hashtable]$QueryParams = @{},
        [switch]$Paginate
    )

    $uri = "$GitLabUrl/api/v4$Endpoint"
    $allResults = @()
    $page = 1
    $perPage = 100

    do {
        $params = @{} + $QueryParams
        $params["page"] = $page
        $params["per_page"] = $perPage

        $queryString = ($params.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $fullUri = "${uri}?${queryString}"

        Write-Log "GET $fullUri" -Level DEBUG

        try {
            $response = Invoke-WebRequest -Uri $fullUri -Headers $GitLabHeaders -Method Get -UseBasicParsing
            $results = $response.Content | ConvertFrom-Json

            if ($results -is [array]) {
                $allResults += $results
            }
            else {
                $allResults += @($results)
            }

            $totalPages = [int]($response.Headers["X-Total-Pages"] | Select-Object -First 1)
            $page++
        }
        catch {
            Write-Log "API call failed: $($_.Exception.Message)" -Level ERROR
            throw
        }

    } while ($Paginate -and $page -le $totalPages)

    return $allResults
}

function Get-ProjectInfo {
    param([long]$ProjectId)
    $result = Invoke-GitLabApi -Endpoint "/projects/$ProjectId"
    return $result
}

function Get-ProjectJobs {
    param([long]$ProjectId)

    Write-Log "Fetching jobs with artifacts for project $ProjectId..."

    $jobs = Invoke-GitLabApi -Endpoint "/projects/$ProjectId/jobs" `
        -QueryParams @{ scope = "success" } `
        -Paginate

    $jobsWithArtifacts = $jobs | Where-Object {
        $_.artifacts -and $_.artifacts.Count -gt 0
    }

    if ($JobNameFilter -ne "") {
        $jobsWithArtifacts = $jobsWithArtifacts | Where-Object {
            $_.name -match $JobNameFilter
        }
        Write-Log "Filtered jobs by pattern '$JobNameFilter': $($jobsWithArtifacts.Count) match(es)" -Level DEBUG
    }

    return $jobsWithArtifacts
}

function Get-JobArtifactZip {
    param(
        [long]$ProjectId,
        [long]$JobId,
        [string]$OutputDir
    )

    $zipPath = Join-Path $OutputDir "job_${JobId}_artifacts.zip"
    $downloadUrl = "$GitLabUrl/api/v4/projects/$ProjectId/jobs/$JobId/artifacts"

    Write-Log "Downloading artifacts for job $JobId -> $zipPath"

    try {
        Invoke-WebRequest -Uri $downloadUrl `
            -Headers $GitLabHeaders `
            -OutFile $zipPath `
            -UseBasicParsing

        if (Test-Path $zipPath) {
            $size = (Get-Item $zipPath).Length
            Write-Log "Downloaded: $zipPath ($([math]::Round($size / 1KB, 1)) KB)" -Level SUCCESS
            return $zipPath
        }
    }
    catch {
    if ($_.Exception.Message -match "404") {
        Write-Log "Artifacts expired/not found for job ${JobId} (404) — skipping" -Level WARN
    }
    else {
        Write-Log "Failed to download artifacts for job ${JobId}: $($_.Exception.Message)" -Level ERROR
        $stats.Errors++
    }
    return $null
    }
}

function Extract-NuGetPackages {
    param(
        [string]$ZipPath,
        [string]$ExtractDir
    )

    $extractPath = Join-Path $ExtractDir "extracted_$(Split-Path $ZipPath -LeafBase)"

    if (Test-Path $extractPath) {
        Remove-Item $extractPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null

    Write-Log "Extracting $ZipPath..."

    try {
        Expand-Archive -Path $ZipPath -DestinationPath $extractPath -Force
    }
    catch {
        Write-Log "Failed to extract ${ZipPath}: $($_.Exception.Message)" -Level ERROR
        $stats.Errors++
        return @()
    }

    $nugetFiles = Get-ChildItem -Path $extractPath -Recurse -Include "*.nupkg", "*.snupkg" -File

    if ($nugetFiles.Count -eq 0) {
        Write-Log "No .nupkg/.snupkg files found in $ZipPath" -Level WARN
    }
    else {
        foreach ($f in $nugetFiles) {
            Write-Log "Found: $($f.Name)" -Level SUCCESS
        }
    }

    return $nugetFiles
}

$adoSourceName = "ADO_Migration_Feed_Temp"
$adoSourceRegistered = $false

function Register-ADONuGetSource {
    $existingSources = & dotnet nuget list source 2>&1
    if ($existingSources -match $adoSourceName) {
        Write-Log "Removing existing temp NuGet source '$adoSourceName'..." -Level DEBUG
        & dotnet nuget remove source $adoSourceName 2>&1 | Out-Null
    }

    Write-Log "Registering ADO feed as NuGet source '$adoSourceName'..."

    $output = & dotnet nuget add source $ADOFeedUrl `
        --name $adoSourceName `
        --username "az" `
        --password $ADOPat `
        --store-password-in-clear-text 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Log "NuGet source registered successfully" -Level SUCCESS
        $script:adoSourceRegistered = $true
    }
    else {
        $outputStr = $output -join "`n"
        Write-Log "Failed to register NuGet source: $outputStr" -Level ERROR
        throw "Could not register ADO NuGet source"
    }
}

function Unregister-ADONuGetSource {
    if ($script:adoSourceRegistered) {
        Write-Log "Cleaning up temp NuGet source '$adoSourceName'..." -Level DEBUG
        & dotnet nuget remove source $adoSourceName 2>&1 | Out-Null
    }
}

function Push-NuGetPackage {
    param(
        [string]$PackagePath,
        [string]$FeedUrl,
        [string]$ApiKey
    )

    $fileName = Split-Path $PackagePath -Leaf
    Write-Log "Pushing $fileName to ADO feed..."

    if ($DryRun) {
        Write-Log "[DRY RUN] Would push: $fileName" -Level WARN
        $stats.PackagesSkipped++
        return $true
    }

    try {
        $output = & dotnet nuget push $PackagePath `
            --source $adoSourceName `
            --api-key az `
            --skip-duplicate 2>&1

        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            $outputStr = $output -join "`n"
            if ($outputStr -match "already exists|409|Conflict") {
                Write-Log "Skipped (already exists): $fileName" -Level WARN
                $stats.PackagesSkipped++
            }
            else {
                Write-Log "Pushed successfully: $fileName" -Level SUCCESS
                $stats.PackagesPushed++
            }
            return $true
        }
        else {
            $outputStr = $output -join "`n"

            if ($SkipDuplicates -and ($outputStr -match "already exists|409|Conflict")) {
                Write-Log "Skipped (already exists): $fileName" -Level WARN
                $stats.PackagesSkipped++
                return $true
            }

            Write-Log "Failed to push ${fileName}: $outputStr" -Level ERROR
            $stats.Errors++
            return $false
        }
    }
    catch {
        Write-Log "Exception pushing ${fileName}: $($_.Exception.Message)" -Level ERROR
        $stats.Errors++
        return $false
    }
}

$processedPackages = @{}

function Test-AlreadyProcessed {
    param([string]$PackageName)
    if ($processedPackages.ContainsKey($PackageName)) {
        return $true
    }
    $processedPackages[$PackageName] = $true
    return $false
}

function Start-Migration {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║  GitLab -> Azure DevOps NuGet Artifact Migration     ║" -ForegroundColor Magenta
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    if ($DryRun) {
        Write-Log "*** DRY RUN MODE — no packages will be pushed ***" -Level WARN
    }

    if (-not $DryRun) {
        try {
            $dotnetVersion = & dotnet --version 2>&1
            Write-Log "dotnet CLI version: $dotnetVersion"
        }
        catch {
            Write-Log "dotnet CLI not found! Please install the .NET SDK." -Level ERROR
            exit 1
        }
    }

    if (-not (Test-Path $TempDir)) {
        New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    }

    if (-not $DryRun) {
        try {
            Register-ADONuGetSource
        }
        catch {
            Write-Log "Cannot proceed without a valid NuGet source registration." -Level ERROR
            exit 1
        }
    }

    Write-Log "Processing $($ProjectIds.Count) project(s)..."
    Write-Host ""

    foreach ($projectId in $ProjectIds) {
        Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

        try {
            $project = Get-ProjectInfo -ProjectId $projectId
            Write-Log "Project: $($project.name) (ID: $projectId)" -Level INFO
        }
        catch {
            Write-Log "Could not fetch project $projectId — skipping. Error: $($_.Exception.Message)" -Level ERROR
            $stats.Errors++
            continue
        }

        $stats.ProjectsProcessed++

        $projectTempDir = Join-Path $TempDir "project_$projectId"
        if (-not (Test-Path $projectTempDir)) {
            New-Item -ItemType Directory -Path $projectTempDir -Force | Out-Null
        }

        $jobs = Get-ProjectJobs -ProjectId $projectId

        if ($jobs.Count -eq 0) {
            Write-Log "No matching jobs with artifacts found for project $($project.name)" -Level WARN
            continue
        }

        Write-Log "Found $($jobs.Count) job(s) with artifacts"

        foreach ($job in $jobs) {
            Write-Log "Processing job: $($job.name) (ID: $($job.id), Pipeline: $($job.pipeline.id))" -Level INFO
            $stats.JobsProcessed++

            $zipPath = Get-JobArtifactZip -ProjectId $projectId -JobId $job.id -OutputDir $projectTempDir
            if (-not $zipPath) { continue }

            $packages = Extract-NuGetPackages -ZipPath $zipPath -ExtractDir $projectTempDir
            $stats.PackagesFound += $packages.Count

            foreach ($pkg in $packages) {
                if (Test-AlreadyProcessed -PackageName $pkg.Name) {
                    Write-Log "Skipping duplicate: $($pkg.Name) (already processed in this run)" -Level WARN
                    $stats.PackagesSkipped++
                    continue
                }

                Push-NuGetPackage -PackagePath $pkg.FullName -FeedUrl $ADOFeedUrl -ApiKey $ADOPat
            }

            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        }

        Write-Host ""
    }

    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "║                 MIGRATION SUMMARY                    ║" -ForegroundColor Magenta
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Magenta
    Write-Host "║  Projects processed : $($stats.ProjectsProcessed.ToString().PadLeft(6))                         ║" -ForegroundColor Cyan
    Write-Host "║  Jobs processed     : $($stats.JobsProcessed.ToString().PadLeft(6))                         ║" -ForegroundColor Cyan
    Write-Host "║  Packages found     : $($stats.PackagesFound.ToString().PadLeft(6))                         ║" -ForegroundColor Cyan
    Write-Host "║  Packages pushed    : $($stats.PackagesPushed.ToString().PadLeft(6))                         ║" -ForegroundColor Green
    Write-Host "║  Packages skipped   : $($stats.PackagesSkipped.ToString().PadLeft(6))                         ║" -ForegroundColor Yellow
    Write-Host "║  Errors             : $($stats.Errors.ToString().PadLeft(6))                         ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    if ($DryRun) {
        Write-Log "This was a DRY RUN — re-run without -DryRun to actually push packages." -Level WARN
    }

    Unregister-ADONuGetSource

    Write-Log "Cleaning up temp directory: $TempDir"
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($stats.Errors -gt 0) {
        Write-Log "Migration completed with $($stats.Errors) error(s). Check the output above." -Level WARN
    }
    else {
        Write-Log "Migration completed successfully!" -Level SUCCESS
    }
}

Start-Migration