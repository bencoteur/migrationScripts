<# 
.DESCRIPTION
Het script maakt het mogelijk om kubernetesclusters te restoren / migreren door gebruik te maken van 
een eerder gemaakte backup via Velero
.NOTES
Version: 0.1
Author: Ben Coteur
Creation Date: 14/01/2026
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Velero Restore Script"
Write-Host "---------------------"

###########################################
# CONFIG – PAS DIT AAN VOOR JE EIGEN USE CASE
###########################################

# ==== Velero / Object Storage ====
$VELERO_BUCKET      = ""
$VELERO_PROVIDER    = ""
$VELERO_SECRET_FILE = ""
$VELERO_S3_URL      = ""
$VELERO_REGION      = ""
$VELERO_FEATURES    = ""
$VELERO_PLUGINS     = ""

# Hoe vaak opnieuw proberen om backups te zien / valideren
$MAX_RETRIES = 20

# ==== MSSQL RESTORE (.bak) – optioneel na Velero-restore ====
$MSSQL_NAMESPACE      = ""
$MSSQL_PVC_NAME       = ""
$MSSQL_STORAGECLASS   = ""
$MSSQL_PVC_SIZE       = ""

$MSSQL_SECRET_NAME    = ""
$MSSQL_SECRET_KEY     = ""

$MSSQL_DB_POD_LABEL    = ""  # bv: "app=mssql"
$MSSQL_TOOLS_POD_LABEL = ""  # bv: "app=mssql-tools"

$MSSQL_SVC_FQDN        = ""
$MSSQL_DB_NAME         = ""
$MSSQL_BACKUP_DIR      = ""  # pad in container
$LOCAL_BAK_DIR         = ""  # lokaal pad naar .bak files

###########################################
# SCRIPT
###########################################

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

# 1. VELERO INSTALLEREN
Write-Host "Velero installeren..."

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

Write-Host "Wachten tot Velero klaar is..."
Invoke-External kubectl @("wait","--for=condition=available","deploy/velero","-n","velero","--timeout=300s")

# 2. BACKUPS OPHALEN MET RETRIES
Write-Host ""
Write-Host "Backups ophalen van Velero..."

$RETRY_COUNT = 0
$BACKUP_LIST = ""

while ($true) {
    $BACKUP_LIST = (& velero backup get 2>$null | Out-String).Trim()

    if (-not [string]::IsNullOrWhiteSpace($BACKUP_LIST)) {
        Write-Host ""
        Write-Host "Beschikbare backups:"
        $lines = $BACKUP_LIST -split "`n"
        # skip header
        $lines | Select-Object -Skip 1 | ForEach-Object {
            $cols = ($_ -split "\s+")
            if ($cols.Count -gt 0 -and $cols[0]) { Write-Host "- $($cols[0])" }
        }
        Write-Host ""
        break
    }

    $RETRY_COUNT++
    if ($RETRY_COUNT -ge $MAX_RETRIES) {
        throw "Kon geen backups ophalen na $MAX_RETRIES pogingen."
    }

    Write-Host "Backups nog niet zichtbaar... wachten (attempt $RETRY_COUNT/$MAX_RETRIES)"
    Start-Sleep -Seconds 10
}

# 3. BACKUPNAAM VRAGEN + VALIDEREN
$BACKUPNAME = (Read-Host "Welke backup wil je restoren?").Trim()
Write-Host ""
Write-Host "Controleren of backup '$BACKUPNAME' zichtbaar is in Velero..."

$RETRY_COUNT = 0
while ($true) {
    $names = (& velero backup get | Out-String) -split "`n" |
        Select-Object -Skip 1 |
        ForEach-Object { (($_ -split "\s+")[0]).Trim() } |
        Where-Object { $_ -ne "" }

    if ($names -contains $BACKUPNAME) {
        Write-Host "Backup '$BACKUPNAME' gevonden!"
        break
    }

    $RETRY_COUNT++
    if ($RETRY_COUNT -ge $MAX_RETRIES) {
        throw "Backup '$BACKUPNAME' bestaat niet of kon niet bevestigd worden."
    }

    Write-Host "Backup nog niet bevestigd... wachten (attempt $RETRY_COUNT/$MAX_RETRIES)"
    Start-Sleep -Seconds 5
}

# 4. VELERO RESTORE
Write-Host ""
Write-Host "Restore starten van backup: $BACKUPNAME ..."
Invoke-External velero @("restore","create","--from-backup",$BACKUPNAME,"--wait")

Write-Host ""
Write-Host " Restore voltooid door Velero."
Write-Host "---------------------------"

########################################
# 5. MSSQL: PVC + .BAK RESTORE (OPTIONEEL)
########################################

Write-Host ""
Write-Host "Controleren of er een MSSQL-omgeving is om een .bak terug te zetten..."

$nsOk = (Try-External kubectl @("get","ns",$MSSQL_NAMESPACE)) -eq 0
$depOk = (Try-External kubectl @("get","deploy","-n",$MSSQL_NAMESPACE)) -eq 0

if ($nsOk -and $depOk) {
    Write-Host "MSSQL-componenten gevonden in namespace '$MSSQL_NAMESPACE'."

    # PVC controleren / aanmaken
    Write-Host ""
    Write-Host "MSSQL PVC controleren..."

    $pvcExists = (Try-External kubectl @("get","pvc",$MSSQL_PVC_NAME,"-n",$MSSQL_NAMESPACE)) -eq 0
    if (-not $pvcExists) {
        Write-Host "PVC '$MSSQL_PVC_NAME' niet gevonden, nieuwe PVC aanmaken..."

        $yaml = @"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $MSSQL_PVC_NAME
  namespace: $MSSQL_NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $MSSQL_PVC_SIZE
  storageClassName: $MSSQL_STORAGECLASS
"@

        $yaml | kubectl apply -f - | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "kubectl apply voor PVC faalde ($LASTEXITCODE)." }
    } else {
        Write-Host "PVC '$MSSQL_PVC_NAME' bestaat al."
    }

    Write-Host "Wachten tot PVC '$MSSQL_PVC_NAME' Bound is..."
    & kubectl wait "--for=jsonpath='{.status.phase}'=Bound" "pvc/$MSSQL_PVC_NAME" -n $MSSQL_NAMESPACE --timeout=60s
    if ($LASTEXITCODE -ne 0) {
        Write-Host "PVC nog niet Bound, MSSQL-pods kunnen nog even Pending blijven."
    }

    Write-Host ""
    Write-Host "Wachten tot MSSQL deployments ready zijn..."
    & kubectl rollout status deploy/mssql-deployment -n $MSSQL_NAMESPACE --timeout=180s
    if ($LASTEXITCODE -ne 0) { Write-Host "mssql-deployment niet volledig ready." }

    & kubectl rollout status deploy/mssql-tools -n $MSSQL_NAMESPACE --timeout=180s
    if ($LASTEXITCODE -ne 0) { Write-Host "mssql-tools deployment niet volledig ready." }

    # Optioneel .bak restore
    Write-Host ""
    $DO_BAK = (Read-Host "Wil je ook een MSSQL .bak file restoren? (y/n)").Trim()

    if ($DO_BAK -match '^[yY]$') {
        Write-Host ""
        Write-Host "Beschikbare .bak files in $LOCAL_BAK_DIR :"
        $baks = Get-ChildItem -Path $LOCAL_BAK_DIR -Filter *.bak -ErrorAction SilentlyContinue
        if (-not $baks) {
            Write-Host "Geen .bak files gevonden."
        } else {
            $baks | ForEach-Object { Write-Host $_.Name }
        }

        Write-Host ""
        $BAK_NAME = (Read-Host "Geef de exacte bestandsnaam van de .bak (zonder pad, enkel filename):").Trim()

        if ([string]::IsNullOrWhiteSpace($BAK_NAME)) {
            Write-Host "Geen .bak file opgegeven, sla MSSQL-restore over."
        } else {
            $FULL_LOCAL_BAK = Join-Path $LOCAL_BAK_DIR $BAK_NAME
            if (-not (Test-Path $FULL_LOCAL_BAK -PathType Leaf)) {
                Write-Host "Bestand '$FULL_LOCAL_BAK' bestaat niet. MSSQL-restore wordt overgeslagen."
            } else {
                Write-Host ""
                Write-Host "SA-wachtwoord ophalen uit secret '$MSSQL_SECRET_NAME'..."

                $SA_PASSWORD = Get-SecretDecoded -Name $MSSQL_SECRET_NAME -Namespace $MSSQL_NAMESPACE -Key $MSSQL_SECRET_KEY
                if ([string]::IsNullOrWhiteSpace($SA_PASSWORD)) {
                    Write-Host "Kon SA_PASSWORD niet ophalen. MSSQL-restore overslaan."
                } else {
                    Write-Host "Zoeken naar MSSQL pods..."

                    $MSSQL_POD = (& kubectl get pod -n $MSSQL_NAMESPACE -l $MSSQL_DB_POD_LABEL -o "jsonpath={.items[0].metadata.name}" 2>$null).ToString().Trim()
                    $TOOLS_POD = (& kubectl get pod -n $MSSQL_NAMESPACE -l $MSSQL_TOOLS_POD_LABEL -o "jsonpath={.items[0].metadata.name}" 2>$null).ToString().Trim()

                    if ([string]::IsNullOrWhiteSpace($MSSQL_POD) -or [string]::IsNullOrWhiteSpace($TOOLS_POD)) {
                        Write-Host "Kon MSSQL of mssql-tools pod niet vinden. MSSQL-restore wordt overgeslagen."
                    } else {
                        Write-Host ""
                        Write-Host "Kopieer .bak naar MSSQL pod: $MSSQL_POD ..."
                        Try { & kubectl exec -n $MSSQL_NAMESPACE $MSSQL_POD -- mkdir -p $MSSQL_BACKUP_DIR *> $null } Catch {}

                        Invoke-External kubectl @(
                            "cp",
                            $FULL_LOCAL_BAK,
                            "$MSSQL_NAMESPACE/${MSSQL_POD}:$MSSQL_BACKUP_DIR/$BAK_NAME"
                        )

                        Write-Host "Start RESTORE DATABASE vanuit .bak..."

                        & kubectl exec -n $MSSQL_NAMESPACE $TOOLS_POD -- /opt/mssql-tools/bin/sqlcmd `
                            -S $MSSQL_SVC_FQDN `
                            -U SA -P $SA_PASSWORD `
                            -Q "RESTORE DATABASE [$MSSQL_DB_NAME] FROM DISK = N'$MSSQL_BACKUP_DIR/$BAK_NAME' WITH REPLACE, RECOVERY, STATS=10;"

                        $rc = $LASTEXITCODE
                        if ($rc -ne 0) {
                            Write-Host "RESTORE DATABASE uit .bak is mislukt (exit code $rc). Check logs."
                        } else {
                            Write-Host "MSSQL-database succesvol teruggezet uit $BAK_NAME."
                        }
                    }
                }
            }
        }
    } else {
        Write-Host "MSSQL .bak restore overgeslagen op verzoek."
    }
} else {
    Write-Host "Geen MSSQL-omgeving gevonden (namespace $MSSQL_NAMESPACE + deployments). MSSQL .bak restore wordt overgeslagen."
}
