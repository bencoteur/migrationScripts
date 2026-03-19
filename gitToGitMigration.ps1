<#
.SYNOPSIS
    Migreert meerdere Git-repositories van GitLab naar Azure DevOps
    aan de hand van een CSV-bestand.

.DESCRIPTION
    Leest een CSV in met per repo de GitLab URL en Azure DevOps URL.
    Per repo: bare clone -> inventarisatie -> mirror push.
    Inclusief alle branches, tags, commits en volledige historiek.
    Stopt bij de eerste fout (alles of niets).

.PARAMETER CsvPath
    Pad naar het CSV-bestand met kolommen: GitLabUrl, AzureUrl

.EXAMPLE
    .\Migrate-GitRepos.ps1 -CsvPath ".\migratie.csv"

    Inhoud van migratie.csv:
    GitLabUrl,AzureUrl
    https://gitlab.com/Organisation/app-backend.git,https://dev.azure.com/Organisation/ProjectA/_git/app-backend
    https://gitlab.com/Organisation/app-frontend.git,https://dev.azure.com/Organisation/ProjectA/_git/app-frontend
    https://gitlab.com/Organisation/infra/deploy-tools.git,https://dev.azure.com/Organisation/ProjectB/_git/deploy-tools

.NOTES
    Author  : Ben Coteur
    Date    : 2026-03-18
    Requires: GIT CLI 
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CsvPath
)

$ErrorActionPreference = "Stop"
$StartTime = Get-Date

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir    = "./logs"
$LogFile   = Join-Path $LogDir "batch_migratie_${Timestamp}.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $Entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Add-Content -Path $LogFile -Value $Entry -Encoding UTF8
    $Color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
    }
    Write-Host $Entry -ForegroundColor $Color
}

$OriginalDir = Get-Location

try {
    Write-Host ""
    Write-Host "=== Batch Git Migratie: GitLab -> Azure DevOps ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $CsvPath)) { throw "CSV-bestand niet gevonden: $CsvPath" }

    $Repos = Import-Csv -Path $CsvPath
    $Total = ($Repos | Measure-Object).Count

    if ($Total -eq 0) { throw "CSV-bestand is leeg." }

    foreach ($Repo in $Repos) {
        if (-not $Repo.GitLabUrl -or -not $Repo.AzureUrl) {
            throw "CSV moet kolommen 'GitLabUrl' en 'AzureUrl' bevatten. Controleer: $CsvPath"
        }
    }

    Log "Logbestand: $LogFile"
    Log "$Total repo('s) gevonden in CSV."

    $GitVer = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git niet gevonden in PATH." }
    Log "Git gevonden: $GitVer"

    Write-Host ""
    Log "Overzicht:"
    $i = 0
    foreach ($Repo in $Repos) {
        $i++
        $Name = [System.IO.Path]::GetFileNameWithoutExtension(($Repo.GitLabUrl -split '/')[-1])
        Log "  $i. $Name"
        Log "     GitLab: $($Repo.GitLabUrl)"
        Log "     Azure:  $($Repo.AzureUrl)"
    }

    Write-Host ""
    $Confirm = Read-Host "Alle $Total repo('s) migreren? (j/n)"
    if ($Confirm -notin @('j', 'J', 'y', 'Y')) {
        Log "Geannuleerd door gebruiker." -Level "WARN"
        exit 0
    }
    Write-Host ""

    $Migrated = 0
    $Results  = @()

    foreach ($Repo in $Repos) {
        $Migrated++
        $RepoName = [System.IO.Path]::GetFileNameWithoutExtension(($Repo.GitLabUrl -split '/')[-1])
        $CloneDir = "${RepoName}.git"

        Log "==========================================================="
        Log "  Repo $Migrated/$Total : $RepoName"
        Log "==========================================================="

        # Stap 1: Mirror clone
        Log "Stap 1/3: Mirror clone van GitLab..."
        if (Test-Path $CloneDir) { Remove-Item -Recurse -Force $CloneDir }

        & git clone --mirror $Repo.GitLabUrl $CloneDir 2>&1 | ForEach-Object { Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "git clone --mirror mislukt voor: $RepoName" }
        Log "Mirror clone voltooid." -Level "SUCCESS"

        Push-Location $CloneDir

        $BranchCount = (& git branch -a | Measure-Object).Count
        $TagCount    = (& git tag | Measure-Object).Count
        $CommitCount = & git rev-list --all --count
        Log "Gevonden: $BranchCount branches, $TagCount tags, $CommitCount commits"

        Log "Stap 2/3: Azure DevOps remote toevoegen..."
        & git remote add azure $Repo.AzureUrl 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git remote add mislukt voor: $RepoName" }
        Log "Remote 'azure' toegevoegd." -Level "SUCCESS"

        Log "Stap 3/3: Mirror push naar Azure DevOps..."
        & git push --mirror azure 2>&1 | ForEach-Object { Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "git push --mirror mislukt voor: $RepoName" }
        Log "Mirror push voltooid." -Level "SUCCESS"

        Pop-Location

        Remove-Item -Recurse -Force $CloneDir
        Log "Tijdelijke bestanden opgeruimd voor $RepoName."

        $Results += [PSCustomObject]@{
            Repo     = $RepoName
            Branches = $BranchCount
            Tags     = $TagCount
            Commits  = $CommitCount
        }

        Write-Host ""
    }

    $Duur = (Get-Date) - $StartTime
    Write-Host ""
    Log "=== ALLE $Total REPO('S) GEMIGREERD ===" -Level "SUCCESS"
    Log ""
    Log "Resultaten:"
    foreach ($R in $Results) {
        Log "  $($R.Repo): $($R.Branches) branches, $($R.Tags) tags, $($R.Commits) commits" -Level "SUCCESS"
    }
    Log ""
    Log "Totale duur: $($Duur.ToString('mm\:ss'))" -Level "SUCCESS"
    Log "Logbestand:  $LogFile" -Level "SUCCESS"
    Write-Host ""
}
catch {
    Log "FOUT: $($_.Exception.Message)" -Level "ERROR"
    Log "Stack: $($_.ScriptStackTrace)" -Level "ERROR"

    if ($Migrated -gt 0) {
        Log "$($Migrated - 1) van $Total repo('s) waren al gemigreerd voor de fout." -Level "ERROR"
    }

    if ((Get-Location).Path -ne $OriginalDir.Path) { Set-Location $OriginalDir }
    Log "Migratie AFGEBROKEN — zie $LogFile" -Level "ERROR"
    exit 1
}