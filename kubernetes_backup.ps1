<# 
.DESCRIPTION
Script makes it possible to backup kubernetes clusters
.NOTES
Version: 0.1
Author: Ben Coteur
Creation Date: 14/01/2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

###########################################
# CONFIG – PAS DIT AAN VOOR JE EIGEN USE CASE
###########################################

# ==== Velero / Object Storage ====
$VELERO_BUCKET      = ""
$VELERO_PROVIDER    = ""
$VELERO_SECRET_FILE = ""  
$VELERO_S3_URL      = ""   
$VELERO_REGION      = ""   
$VELERO_FEATURES    = "EnableAPIGroupVersions"
$VELERO_PLUGINS     = ""

# ==== MSSQL FULL BACKUP (.bak) – optioneel ====
$ENABLE_MSSQL_BAK = $true

$MSSQL_NAMESPACE     = ""
$MSSQL_APP_LABEL     = ""   
$MSSQL_TOOLS_DEPLOY  = ""   

$MSSQL_SECRET_NAME   = ""
$MSSQL_SECRET_KEY    = ""

$MSSQL_DB_NAME          = ""
$MSSQL_BACKUP_SUBDIR    = "" 
$LOCAL_BACKUP_DIR       = ""  
$MSSQL_SVC_FQDN         = ""  


##########
# SCRIPT #
##########

function Invoke-External {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$false)][string[]]$Arguments = @()
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

function Test-External {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$false)][string[]]$Arguments = @()
    )
    & $FilePath @Arguments
    return $LASTEXITCODE
}


function Get-SecretDecoded {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Namespace,
        [Parameter(Mandatory=$true)][string]$Key
    )

    $jsonPath = "jsonpath={.data.$Key}"
    $b64 = (& kubectl get secret $Name -n $Namespace -o $jsonPath 2>$null).ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($b64)) { return "" }

    try {
        $bytes = [Convert]::FromBase64String($b64)
        return [Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return ""
    }
}

Write-Host "Velero Backup Script (with optional MSSQL .bak)"
Write-Host "-----------------------------------------------"
Write-Host ""

# 2. VELERO CHECKEN / INSTALLEREN
$veleroInstalled = $true
try {
    & kubectl get ns velero *> $null
} catch {
    $veleroInstalled = $false
}

if (-not $veleroInstalled) {
    Write-Host "Velero not found in cluster. installing..."

    Invoke-External velero @(
        "install",
        "--provider", $VELERO_PROVIDER,
        "--plugins", $VELERO_PLUGINS,
        "--bucket", $VELERO_BUCKET,
        "--secret-file", $VELERO_SECRET_FILE,
        "--backup-location-config", "region=$VELERO_REGION,s3ForcePathStyle=true,s3Url=$VELERO_S3_URL",
        "--use-node-agent",
        "--features=$VELERO_FEATURES"
    )

    Write-Host "Waiting until velero is ready..."
    Invoke-External kubectl @("wait","--for=condition=available","deploy/velero","-n","velero","--timeout=300s")

    Write-Host "Waiting until note-agent is ready"
    Invoke-External kubectl @("rollout","status","ds/node-agent","-n","velero","--timeout=300s")
} else {
    Write-Host "Velero already installed."
}

# 3. BACKUP NAAM
Write-Host ""
$BACKUPNAME = (Read-Host "Backup name: ").Trim()
if ([string]::IsNullOrWhiteSpace($BACKUPNAME)) {
    throw "backup name is required"
}

# 4. NAMESPACE SELECTIE
Write-Host ""
Write-Host "available namespaces:"
$namespaces = & kubectl get ns --no-headers
$namespaces -split "`n" | ForEach-Object {
    $n = ($_ -split "\s+")[0].Trim()
    if ($n) { Write-Host "- $n" }
}
Write-Host ""

Write-Host "Select namespaces"
Write-Host " * Separate with a space"
Write-Host " * use "*" to select all"
$NAMESPACES = (Read-Host "   > ").Trim()

if ([string]::IsNullOrWhiteSpace($NAMESPACES)) {
    throw "Choose at least one"
}

if ($NAMESPACES -ne "*") {
    $NS_FORMATTED = ($NAMESPACES -split "\s+" | Where-Object { $_ -ne "" }) -join ","
} else {
    $NS_FORMATTED = "*"
}

# 5. (OPTIONEEL) MSSQL: EERST NATIVE .BAK MAKEN
$BAK_CREATED = $false
$BAK_NAME = ""

if ($ENABLE_MSSQL_BAK) {
    Write-Host ""
    Write-Host "[MSSQL] check if MSSQL is added in scope"

    $MSSQL_IN_SCOPE = $false
    if ($NS_FORMATTED -eq "*" -or ($NS_FORMATTED -split ",") -contains $MSSQL_NAMESPACE) {
        $rc = Try-External kubectl @("get","deploy","-n",$MSSQL_NAMESPACE)
        if ($rc -eq 0) { $MSSQL_IN_SCOPE = $true }
    }

    if ($MSSQL_IN_SCOPE) {
        Write-Host "[MSSQL] Namespace '$MSSQL_NAMESPACE' in backup scope."

        $deployList = & kubectl get deploy -n $MSSQL_NAMESPACE 2>$null
        if ($deployList -match [Regex]::Escape($MSSQL_TOOLS_DEPLOY)) {
            Write-Host "[MSSQL] MSSQL tools fount. Native BACKUP DATABASE deployed"

            $SA_PASSWORD = Get-SecretDecoded -Name $MSSQL_SECRET_NAME -Namespace $MSSQL_NAMESPACE -Key $MSSQL_SECRET_KEY

            if ([string]::IsNullOrWhiteSpace($SA_PASSWORD)) {
                Write-Host "[MSSQL] Kon SA_PASSWORD niet uit secret halen. Sla .bak stap over."
            } else {
                # MSSQL database-pod zoeken (label selector)
                $MSSQL_POD = (& kubectl get pod -n $MSSQL_NAMESPACE -l $MSSQL_APP_LABEL -o "jsonpath={.items[0].metadata.name}" 2>$null).ToString().Trim()

                if ([string]::IsNullOrWhiteSpace($MSSQL_POD)) {
                    Write-Host "[MSSQL] Kon MSSQL pod niet vinden met label '$MSSQL_APP_LABEL'. Sla .bak stap over."
                } else {
                    # Zorg dat backups-map bestaat in db pod
                    Try { & kubectl exec -n $MSSQL_NAMESPACE $MSSQL_POD -- mkdir -p $MSSQL_BACKUP_SUBDIR *> $null } Catch {}

                    $TS = Get-Date -Format "yyyyMMdd-HHmmss"
                    $BAK_NAME = "$MSSQL_DB_NAME-full-$TS.bak"

                    Write-Host "[MSSQL] Schrijf .bak naar $MSSQL_BACKUP_SUBDIR/$BAK_NAME ..."

                    & kubectl exec deploy/$MSSQL_TOOLS_DEPLOY -n $MSSQL_NAMESPACE -- /opt/mssql-tools/bin/sqlcmd `
                        -S $MSSQL_SVC_FQDN `
                        -U SA -P $SA_PASSWORD `
                        -Q "BACKUP DATABASE [$MSSQL_DB_NAME] TO DISK = N'$MSSQL_BACKUP_SUBDIR/$BAK_NAME' WITH INIT, STATS=10;"

                    $rc = $LASTEXITCODE
                    if ($rc -ne 0) {
                        Write-Host "[MSSQL] WAARSCHUWING: native .bak backup faalde. Velero backup gaat wel door."
                    } else {
                        Write-Host "[MSSQL] Native .bak backup klaar: $BAK_NAME"
                        $BAK_CREATED = $true

                        New-Item -ItemType Directory -Force -Path $LOCAL_BACKUP_DIR | Out-Null

                        Write-Host "[MSSQL] Kopieer .bak naar lokale machine ($LOCAL_BACKUP_DIR)..."
                        Invoke-External kubectl @(
                            "cp",
                            "$MSSQL_NAMESPACE/${MSSQL_POD}:$MSSQL_BACKUP_SUBDIR/$BAK_NAME",
                            (Join-Path $LOCAL_BACKUP_DIR $BAK_NAME)
                        )

                        Write-Host "[MSSQL] Backup gedownload naar: $(Join-Path $LOCAL_BACKUP_DIR $BAK_NAME)"
                    }
                }
            }
        } else {
            Write-Host "[MSSQL] MSSQL tools deployment '$MSSQL_TOOLS_DEPLOY' niet gevonden. Sla .bak stap over."
        }
    } else {
        Write-Host "[MSSQL] Namespace '$MSSQL_NAMESPACE' zit NIET in de geselecteerde backup scope. .bak wordt niet gemaakt."
    }
} else {
    Write-Host ""
    Write-Host "[MSSQL] MSSQL .bak backup is uitgeschakeld (ENABLE_MSSQL_BAK=false)."
}

# 6. VELERO BACKUP (ZONDER PV/PVC RESOURCES)
Write-Host ""
Write-Host "Velero backup wordt aangemaakt (PV/PVC resources uitgesloten)..."

Invoke-External velero @(
    "backup","create",$BACKUPNAME,
    "--include-namespaces",$NS_FORMATTED,
    "--exclude-resources","persistentvolumes,persistentvolumeclaims",
    "--snapshot-volumes=false",
    "--wait"
)

Write-Host ""
Write-Host "Backup voltooid!"
Write-Host "----------------------------"
& velero backup describe $BACKUPNAME --details
Write-Host "----------------------------"

if ($BAK_CREATED) {
    Write-Host "[MSSQL] Let op: naast de Velero backup bestaat er ook een .bak file:"
    Write-Host "        $(Join-Path $LOCAL_BACKUP_DIR $BAK_NAME)"
}

Write-Host "Klaar! Backup '$BACKUPNAME' staat nu in Velero."

