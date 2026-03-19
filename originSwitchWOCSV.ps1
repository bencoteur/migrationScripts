<#
.SYNOPSIS
    Schakelt je lokale Git-repo om van GitLab naar Azure DevOps.
    Voer dit uit vanuit je bestaande repo-map.

.DESCRIPTION
    Dit script vervangt de GitLab 'origin' remote door een Azure DevOps remote.
    Na uitvoering push en pull je automatisch naar Azure DevOps.
    Authenticatie verloopt via Git Credential Manager (popup bij eerste keer).

.PARAMETER AzureUrl
    De HTTPS-URL van de Azure DevOps-repository.

.EXAMPLE
    cd C:\MijnProjecten\my-app
    .\Switch-ToAzureDevOps.ps1 -AzureUrl "https://dev.azure.com/Organisation/ProjectA/_git/my-app"

.NOTES
    Author  : Ben Coteur
    Date    : 2026-03-19
    Requires: GIT CLI 
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AzureUrl
)

$ErrorActionPreference = "Stop"

function Log {
    param([string]$Msg, [string]$Level = "INFO")
    $Color = switch ($Level) {
        "INFO"    { "Cyan" }
        "SUCCESS" { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Msg" -ForegroundColor $Color
}

try {
    Write-Host ""
    Write-Host "=== Switch naar Azure DevOps ===" -ForegroundColor Cyan
    Write-Host ""
    
    if (-not (Test-Path ".git")) {
        throw "Dit is geen Git-repository. Navigeer naar je repo-map (cd C:\...\je-repo)."
    }
    Log "Git-repo gevonden: $(Get-Location)"

    $CurrentOrigin = & git remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Geen 'origin' remote gevonden."
    }
    Log "Huidige origin (GitLab): $CurrentOrigin"
    Log "Nieuwe origin (Azure):   $AzureUrl"

    Write-Host ""
    $Confirm = Read-Host "Origin omschakelen van GitLab naar Azure DevOps? (j/n)"
    if ($Confirm -notin @('j', 'J', 'y', 'Y')) {
        Log "Geannuleerd door gebruiker." -Level "WARN"
        exit 0
    }
    Write-Host ""

    Log "Origin wordt omgeschakeld..."
    & git remote set-url origin $AzureUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git remote set-url mislukt." }
    Log "Origin gewijzigd naar Azure DevOps." -Level "SUCCESS"

    $Remotes = & git remote 2>&1
    foreach ($Remote in $Remotes) {
        if ($Remote.Trim() -eq "origin") { continue }
        $RemoteUrl = & git remote get-url $Remote.Trim() 2>&1
        if ($RemoteUrl -match "gitlab") {
            Log "Oude GitLab remote '$($Remote.Trim())' verwijderen..." -Level "WARN"
            & git remote remove $Remote.Trim() 2>&1
        }
    }

    Log "Verbinding testen met Azure DevOps (git fetch)..."
    & git fetch origin 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "git fetch mislukt — controleer de URL en je toegang." }
    Log "Verbinding OK!" -Level "SUCCESS"

    $Branch = & git branch --show-current 2>&1
    Log "Actieve branch: $Branch"

    Write-Host ""
    Log "=== KLAAR ===" -Level "SUCCESS"
    Log "Je pusht en pullt nu naar Azure DevOps." -Level "SUCCESS"
    Log "Gewoon verder werken met git push / git pull zoals je gewend bent." -Level "SUCCESS"
    Write-Host ""
}
catch {
    Log "FOUT: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}