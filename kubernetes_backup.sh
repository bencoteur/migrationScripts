#!/bin/bash
set -euo pipefail

###########################################
# CONFIG – PAS DIT AAN VOOR JE EIGEN USE CASE
###########################################

# ==== Velero / Object Storage ====
# S3-compatibele storage waar Velero zijn backups wegschrijft.
VELERO_BUCKET=" "
VELERO_PROVIDER=" "

# Locatie van je credentials-file (access_key/secret_key) voor S3/MinIO/Blob
VELERO_SECRET_FILE=" "

# S3 endpoint (bij MinIO is dit meestal http(s)://host:port)
VELERO_S3_URL=" "

# "Region" naam voor Velero (bij MinIO mag dit gewoon een fake string zijn)
VELERO_REGION=" "

# Extra flags voor Velero install
VELERO_FEATURES="EnableAPIGroupVersions"
VELERO_PLUGINS=" "


# ==== MSSQL FULL BACKUP (.bak) – optioneel ====
# Zet op "false" als je geen MSSQL native backup wil doen.
ENABLE_MSSQL_BAK=true

# Namespace waar MSSQL draait
MSSQL_NAMESPACE=" "

# Label selector om de MSSQL database-pod te vinden (voor kubectl cp)
MSSQL_APP_LABEL=" "

# Naam van de MSSQL tools deployment (container met sqlcmd)
MSSQL_TOOLS_DEPLOY=" "

# Secret die het SA-wachtwoord bevat
MSSQL_SECRET_NAME=" "
MSSQL_SECRET_KEY=" "

# Databasenaam die je wil back-uppen
MSSQL_DB_NAME=" "

# Pad in de container waar de .bak wordt geplaatst
MSSQL_BACKUP_SUBDIR=" "

# Waar de .bak file lokaal bewaard wordt
LOCAL_BACKUP_DIR=" "

# FQDN + poort om tegen MSSQL te connecteren vanuit mssql-tools
MSSQL_SVC_FQDN=" "

# Cluster used, vul hier de naam van je cluster in
CLUSTER = " "
##########
# SCRIPT #
##########

echo "Velero Backup Script (met optionele MSSQL .bak)"
echo "-----------------------------------------------"
# 2. VELERO CHECKEN / INSTALLEREN
echo ""
if ! kubectl get ns velero >/dev/null 2>&1; then
  echo "Velero niet gevonden in cluster. Installeren..."

  velero install \
    --provider "$VELERO_PROVIDER" \
    --plugins "$VELERO_PLUGINS" \
    --bucket "$VELERO_BUCKET" \
    --secret-file "$VELERO_SECRET_FILE" \
    --backup-location-config "region=$VELERO_REGION,s3ForcePathStyle=true,s3Url=$VELERO_S3_URL" \
    --use-node-agent \
    --features="$VELERO_FEATURES"

  echo "Wachten tot Velero klaar is..."
  kubectl wait --for=condition=available deploy/velero -n velero --timeout=300s

  echo "Wachten tot node-agent klaar is..."
  kubectl rollout status ds/node-agent -n velero --timeout=300s
else
  echo "Velero is al geïnstalleerd."
fi

# 3. BACKUP NAAM
echo ""
read -p "Welke naam wil je de backup geven? " BACKUPNAME

if [[ -z "$BACKUPNAME" ]]; then
  echo "Je moet een backupnaam ingeven."
  exit 1
fi

# 4. NAMESPACE SELECTIE
echo ""
echo "Beschikbare namespaces:"
kubectl get ns --no-headers | awk '{print "- " $1}'
echo ""

echo "Welke namespaces wil je backuppen?"
echo " * Meerdere scheiden met een spatie"
echo " * Gebruik '*' om ALLE namespaces mee te nemen"
read -p "   > " NAMESPACES

if [[ -z "$NAMESPACES" ]]; then
    echo "Je moet minstens één namespace kiezen."
    exit 1
fi

if [[ "$NAMESPACES" != "*" ]]; then
    NS_FORMATTED=$(echo "$NAMESPACES" | tr ' ' ',')
else
    NS_FORMATTED="*"
fi

# 5. (OPTIONEEL) MSSQL: EERST NATIVE .BAK MAKEN
BAK_CREATED=false
BAK_NAME=""

if $ENABLE_MSSQL_BAK; then
  echo ""
  echo "[MSSQL] Controleren of MSSQL in scope zit..."

  MSSQL_IN_SCOPE=false
  if [[ "$NS_FORMATTED" == "*" ]] || echo "$NS_FORMATTED" | grep -q "$MSSQL_NAMESPACE"; then
    if kubectl get deploy -n "$MSSQL_NAMESPACE" >/dev/null 2>&1; then
      MSSQL_IN_SCOPE=true
    fi
  fi

  if $MSSQL_IN_SCOPE; then
    echo "[MSSQL] Namespace '$MSSQL_NAMESPACE' zit in backup scope."

    # Check of zowel database- als tools-deployment bestaan
    if kubectl get deploy -n "$MSSQL_NAMESPACE" | grep -q "$MSSQL_TOOLS_DEPLOY"; then
      echo "[MSSQL] MSSQL tools gevonden. Native BACKUP DATABASE wordt uitgevoerd..."

      # SA password uit secret halen
      SA_PASSWORD=$(kubectl get secret "$MSSQL_SECRET_NAME" -n "$MSSQL_NAMESPACE" \
        -o jsonpath="{.data.$MSSQL_SECRET_KEY}" 2>/dev/null | base64 -d || true)

      if [[ -z "$SA_PASSWORD" ]]; then
        echo "[MSSQL] Kon SA_PASSWORD niet uit secret halen. Sla .bak stap over."
      else
        # Zorg dat backups-map bestaat
        kubectl exec deploy/"$MSSQL_APP_LABEL" -n "$MSSQL_NAMESPACE" -- \
          mkdir -p "$MSSQL_BACKUP_SUBDIR" || true

        TS=$(date +%Y%m%d-%H%M%S)
        BAK_NAME="${MSSQL_DB_NAME}-full-$TS.bak"

        echo "[MSSQL] Schrijf .bak naar $MSSQL_BACKUP_SUBDIR/$BAK_NAME ..."
        set +e
        kubectl exec deploy/"$MSSQL_TOOLS_DEPLOY" -n "$MSSQL_NAMESPACE" -- /opt/mssql-tools/bin/sqlcmd \
          -S "$MSSQL_SVC_FQDN" \
          -U SA -P "$SA_PASSWORD" \
          -Q "BACKUP DATABASE [$MSSQL_DB_NAME]
              TO DISK = N'$MSSQL_BACKUP_SUBDIR/$BAK_NAME'
              WITH INIT, STATS=10;"
        RC=$?
        set -e

        if [[ $RC -ne 0 ]]; then
          echo "[MSSQL] WAARSCHUWING: native .bak backup faalde. Velero backup gaat wel door."
        else
          echo "[MSSQL] Native .bak backup klaar: $BAK_NAME"
          BAK_CREATED=true

          # Lokaal pad aanmaken
          mkdir -p "$LOCAL_BACKUP_DIR"

          # MSSQL database-pod zoeken voor kubectl cp
          MSSQL_POD=$(kubectl get pod -n "$MSSQL_NAMESPACE" -l "$MSSQL_APP_LABEL" -o jsonpath='{.items[0].metadata.name}')

          echo "[MSSQL] Kopieer .bak naar lokale machine ($LOCAL_BACKUP_DIR)..."
          kubectl cp \
            "$MSSQL_NAMESPACE/$MSSQL_POD:$MSSQL_BACKUP_SUBDIR/$BAK_NAME" \
            "$LOCAL_BACKUP_DIR/$BAK_NAME"

          echo "[MSSQL] Backup gedownload naar: $LOCAL_BACKUP_DIR/$BAK_NAME"
        fi
      fi
    else
      echo "[MSSQL] MSSQL tools deployment '$MSSQL_TOOLS_DEPLOY' niet gevonden. Sla .bak stap over."
    fi
  else
    echo "[MSSQL] Namespace '$MSSQL_NAMESPACE' zit NIET in de geselecteerde backup scope. .bak wordt niet gemaakt."
  fi
else
  echo ""
  echo "[MSSQL] MSSQL .bak backup is uitgeschakeld (ENABLE_MSSQL_BAK=false)."
fi

# 6. VELERO BACKUP (ZONDER PV/PVC RESOURCES)
echo ""
echo "Velero backup wordt aangemaakt (PV/PVC resources uitgesloten)..."

velero backup create "$BACKUPNAME" \
    --include-namespaces "$NS_FORMATTED" \
    --exclude-resources persistentvolumes,persistentvolumeclaims \
    --snapshot-volumes=false \
    --wait

echo ""
echo "Backup voltooid!"
echo "----------------------------"
velero backup describe "$BACKUPNAME" --details
echo "----------------------------"

if $BAK_CREATED; then
  echo "[MSSQL] Let op: naast de Velero backup bestaat er ook een .bak file:"
  echo "        $LOCAL_BACKUP_DIR/$BAK_NAME"
fi

echo "Klaar! Backup '$BACKUPNAME' staat nu in Velero."
