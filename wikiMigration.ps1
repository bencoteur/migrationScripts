<#
.SYNOPSIS
    Migreert een GitLab Wiki naar een Azure DevOps Project Wiki.
    Inclusief volledige historiek en afbeeldingen.

.DESCRIPTION
    Dit script:
    1. Bare clone van de GitLab wiki
    2. Mirror push naar Azure DevOps
    3. Branch hernoemen (master -> wikiMaster)
    4. Afbeeldingen verplaatsen (uploads/ -> .attachments/) en links aanpassen

    VEREISTE: De wiki moet eerst geïnitialiseerd zijn in Azure DevOps.
    Ga naar je project -> Overview -> Wiki -> maak een eerste pagina aan.

.PARAMETER GitLabProjectUrl
    De HTTPS-URL van het GitLab-project (ZONDER .wiki.git, dat voegt het script toe).

.PARAMETER AzureWikiUrl
    De HTTPS-URL van de Azure DevOps wiki-repo.

.EXAMPLE
    .\Migrate-Wiki.ps1 `
        -GitLabProjectUrl "https://gitlab.com/Organisation/my-project" `
        -AzureWikiUrl "https://dev.azure.com/Organisation/MyProject/_git/MyProject.wiki"

.NOTES
    Author  : Ben Coteur
    Date    : 2026-03-19
    Requires: GIT CLI 
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GitLabProjectUrl,
    [Parameter(Mandatory)][string]$AzureWikiUrl
)

$ErrorActionPreference = "Stop"
$StartTime = Get-Date

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir    = "C:\Users\benco\Desktop\Skorro\2025-2026\WPL4\gitlab_migration\logs"
$LogFile   = Join-Path $LogDir "wiki_migratie_${Timestamp}.log"

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

$GitLabWikiUrl = "$($GitLabProjectUrl.TrimEnd('/')).wiki.git"
$CloneDir = "wiki-migration.git"

try {
    Write-Host ""
    Write-Host "=== GitLab Wiki Migratie ===" -ForegroundColor Cyan
    Write-Host ""

    Log "Migratie gestart"
    Log "Bron (GitLab wiki):  $GitLabWikiUrl"
    Log "Doel (Azure wiki):   $AzureWikiUrl"
    Log "Log: $LogFile"

    # Git check
    $GitVer = & git --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git niet gevonden in PATH." }
    Log "Git gevonden: $GitVer"

    Log "--- Stap 1/5: Mirror clone van GitLab wiki ---"
    if (Test-Path $CloneDir) { Remove-Item -Recurse -Force $CloneDir }

    & git clone --mirror $GitLabWikiUrl $CloneDir 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "git clone --mirror mislukt. Heeft het project een wiki?" }
    Log "Mirror clone voltooid." -Level "SUCCESS"

    Push-Location $CloneDir

    $CommitCount = & git rev-list --all --count
    $FileCount   = (& git ls-tree -r HEAD --name-only 2>&1 | Measure-Object).Count
    Log "Gevonden: $CommitCount commits, $FileCount wiki-pagina's/bestanden"

    Log "--- Stap 2/5: Azure DevOps wiki remote toevoegen ---"
    & git remote add azure $AzureWikiUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git remote add mislukt." }
    Log "Remote 'azure' toegevoegd." -Level "SUCCESS"

    Log "--- Stap 3/5: Force push naar Azure DevOps wiki ---"
    Log "Force push omdat Azure wiki mogelijk al een init-commit heeft." -Level "WARN"

    & git push azure --mirror --force 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "git push --mirror --force mislukt." }
    Log "Push voltooid." -Level "SUCCESS"

    Pop-Location

    Log "--- Stap 4/5: Branch hernoemen (master -> wikiMaster) ---"

    $WikiCloneDir = "wiki-branch-fix"
    & git clone $AzureWikiUrl $WikiCloneDir 2>&1 | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "git clone van Azure wiki mislukt." }

    Push-Location $WikiCloneDir

    $Branches = & git branch -a 2>&1
    if ($Branches -match "wikiMaster") {
        Log "Branch 'wikiMaster' bestaat al — overgeslagen." -Level "SUCCESS"
    }
    else {
        & git checkout master 2>&1
        & git checkout -b wikiMaster 2>&1
        & git push origin wikiMaster 2>&1 | ForEach-Object { Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "Push van wikiMaster branch mislukt." }
        Log "Branch 'wikiMaster' aangemaakt en gepusht." -Level "SUCCESS"
    }

    Pop-Location
    Remove-Item -Recurse -Force $WikiCloneDir

    Log "--- Stap 5/5: Afbeeldingen omzetten (uploads/ -> .attachments/) ---"

    $AttachDir = "wiki-attachments-fix"
    & git clone $AzureWikiUrl $AttachDir 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git clone voor attachments-fix mislukt." }

    Push-Location $AttachDir
    & git checkout wikiMaster 2>&1 | Out-Null

    if (Test-Path "uploads") {
        Log "Map 'uploads/' gevonden, wordt omgezet naar '.attachments/'..."

        if (-not (Test-Path ".attachments")) {
            New-Item -ItemType Directory -Path ".attachments" | Out-Null
        }

        $FileMapping = @{}

        $UploadFiles = Get-ChildItem -Path "uploads" -Recurse -File
        $AttachCount = 0

        foreach ($File in $UploadFiles) {
            $Uuid      = [guid]::NewGuid().ToString()
            $BaseName  = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
            $Extension = $File.Extension
            $NewName   = "${BaseName}-${Uuid}${Extension}"

            $OldRelPath = $File.FullName.Replace((Get-Location).Path, "").TrimStart("\", "/").Replace("\", "/")

            $NewRelPath = ".attachments/$NewName"

            Copy-Item -Path $File.FullName -Destination ".attachments/$NewName"
            $FileMapping[$OldRelPath] = $NewRelPath
            $AttachCount++

            Log "  $OldRelPath -> $NewRelPath"
        }

        Log "$AttachCount afbeelding(en) verplaatst naar .attachments/." -Level "SUCCESS"

        $MdFiles = Get-ChildItem -Recurse -Filter "*.md"
        $FixedFiles = 0

        foreach ($MdFile in $MdFiles) {
            $Content  = Get-Content -Path $MdFile.FullName -Raw -Encoding UTF8
            $Original = $Content

            foreach ($OldPath in $FileMapping.Keys) {
                $NewPath = $FileMapping[$OldPath]
                $EscapedOld = [regex]::Escape($OldPath)
                $Content = [regex]::Replace($Content,
                    "!\[([^\]]*)\]\($EscapedOld\)(\{[^}]*\})?",
                    "![\`$1](/$NewPath)"
                )
            }

            if ($Content -ne $Original) {
                Set-Content -Path $MdFile.FullName -Value $Content -NoNewline -Encoding UTF8
                $FixedFiles++
                Log "  Links aangepast in: $($MdFile.Name)"
            }
        }

        Remove-Item -Recurse -Force "uploads"
        Log "Map 'uploads/' verwijderd."

        if ($FixedFiles -gt 0) {
            Log "$FixedFiles markdown-bestand(en) aangepast." -Level "SUCCESS"
        }

        & git add -A 2>&1
        & git commit -m "Afbeeldingen omgezet: uploads/ -> .attachments/ (Azure DevOps formaat)" 2>&1 | ForEach-Object { Log "  $_" }
        & git push origin wikiMaster 2>&1 | ForEach-Object { Log "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "Push van attachments-fix mislukt." }
        Log "Attachments-fix gepusht naar Azure DevOps." -Level "SUCCESS"
    }
    else {
        Log "Geen 'uploads/' map gevonden — geen afbeeldingen om te converteren." -Level "SUCCESS"
    }

    Pop-Location
    Remove-Item -Recurse -Force $AttachDir

    $Duur = (Get-Date) - $StartTime
    Write-Host ""
    Log "=== WIKI MIGRATIE VOLTOOID ===" -Level "SUCCESS"
    Log "  Wiki-pagina's:  $FileCount" -Level "SUCCESS"
    Log "  Commits:        $CommitCount" -Level "SUCCESS"
    Log "  Afbeeldingen:   $AttachCount" -Level "SUCCESS"
    Log "  Duur:           $($Duur.ToString('mm\:ss'))" -Level "SUCCESS"
    Log "  Logbestand:     $LogFile" -Level "SUCCESS"
    Write-Host ""

    Remove-Item -Recurse -Force $CloneDir
    Log "Tijdelijke bestanden opgeruimd."
}
catch {
    Log "FOUT: $($_.Exception.Message)" -Level "ERROR"
    Log "Stack: $($_.ScriptStackTrace)" -Level "ERROR"
    if ((Get-Location).Path -like "*$CloneDir*") { Pop-Location }
    Log "Wiki migratie AFGEBROKEN — zie $LogFile" -Level "ERROR"
    exit 1
}