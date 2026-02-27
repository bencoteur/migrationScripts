#!/bin/bash
set -euo pipefail

echo "Velero Restore Script"
echo "---------------------"

###########################################
# CONFIG – PAS DIT AAN VOOR JE EIGEN USE CASE
###########################################

# ==== Velero / Object Storage ====
VELERO_BUCKET=" "
VELERO_PROVIDER=" "
VELERO_SECRET_FILE=" "
VELERO_S3_URL=" "
VELERO_REGION=" "
VELERO_FEATURES=" "
VELERO_PLUGINS=" "

# Hoe vaak opnieuw proberen om backups te zien / valideren
MAX_RETRIES=15

# ==== MSSQL RESTORE (.bak) – optioneel na Velero-restore ====
MSSQL_NAMESPACE=" "
MSSQL_PVC_NAME=" "
MSSQL_STORAGECLASS=" "
MSSQL_PVC_SIZE=" "

# Secret met SA-password
MSSQL_SECRET_NAME=" "
MSSQL_SECRET_KEY=" "

# Labels om pods te zoeken
MSSQL_DB_POD_LABEL=" "
MSSQL_TOOLS_POD_LABEL=" "

# MSSQL service FQDN + poort voor sqlcmd
MSSQL_SVC_FQDN=" "

# Naam van de database die je restore’t
MSSQL_DB_NAME=" "

# Pad in de container waar de .bak ligt / zal liggen
MSSQL_BACKUP_DIR=" "

# Waar jouw .bak files lokaal staan
LOCAL_BAK_DIR=" "


###########################################
# SCRIPT – VANAF HIER NORMAAL NIET MEER AANPASSEN
###########################################

# 1. VELERO INSTALLEREN
echo "Velero installeren..."

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

# 2. BACKUPS OPHALEN MET RETRIES
echo ""
echo "Backups ophalen van Velero..."

RETRY_COUNT=0

while true; do
    BACKUP_LIST=$(velero backup get 2>/dev/null || true)

    if [[ -n "$BACKUP_LIST" ]]; then
        echo ""
        echo "Beschikbare backups:"
        echo "$BACKUP_LIST" | awk 'NR>1 {print "- " $1}'
        echo ""
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT+1))

    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        echo "Kon geen backups ophalen na $MAX_RETRIES pogingen."
        exit 1
    fi

    echo "Backups nog niet zichtbaar... wachten (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 10
done

# 3. BACKUPNAAM VRAGEN + VALIDEREN
read -p "Welke backup wil je restoren? " BACKUPNAME
echo ""

echo "Controleren of backup '$BACKUPNAME' zichtbaar is in Velero..."

RETRY_COUNT=0

while true; do
    if velero backup get | awk 'NR>1 {print $1}' | grep -qx "$BACKUPNAME"; then
        echo "Backup '$BACKUPNAME' gevonden!"
        break
    fi

    RETRY_COUNT=$((RETRY_COUNT+1))

    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        echo "Backup '$BACKUPNAME' bestaat niet of kon niet bevestigd worden."
        exit 1
    fi

    echo "Backup nog niet bevestigd... wachten (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 5
done

# 4. VELERO RESTORE
echo ""
echo "Restore starten van backup: $BACKUPNAME ..."
velero restore create --from-backup "$BACKUPNAME" --wait

echo ""
echo " Restore voltooid door Velero."
echo "---------------------------"

########################################
# 5. MSSQL: PVC + .BAK RESTORE (OPTIONEEL)
########################################

echo ""
echo "Controleren of er een MSSQL-omgeving is om een .bak terug te zetten..."

if kubectl get ns "$MSSQL_NAMESPACE" >/dev/null 2>&1 && \
   kubectl get deploy -n "$MSSQL_NAMESPACE" >/dev/null 2>&1; then

    echo "MSSQL-componenten gevonden in namespace '$MSSQL_NAMESPACE'."

    # PVC controleren / aanmaken
    echo ""
    echo "MSSQL PVC controleren..."

    if ! kubectl get pvc "$MSSQL_PVC_NAME" -n "$MSSQL_NAMESPACE" >/dev/null 2>&1; then
        echo "PVC '$MSSQL_PVC_NAME' niet gevonden, nieuwe PVC aanmaken..."

        kubectl apply -f - <<EOF
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
EOF

    else
        echo "PVC '$MSSQL_PVC_NAME' bestaat al."
    fi

    echo "Wachten tot PVC '$MSSQL_PVC_NAME' Bound is..."
    kubectl wait \
      --for=jsonpath='{.status.phase}'=Bound pvc/"$MSSQL_PVC_NAME" \
      -n "$MSSQL_NAMESPACE" --timeout=60s || echo "PVC nog niet Bound, MSSQL-pods kunnen nog even Pending blijven."

    echo ""
    echo "Wachten tot MSSQL deployments ready zijn..."
    kubectl rollout status deploy/mssql-deployment -n "$MSSQL_NAMESPACE" --timeout=180s || echo "mssql-deployment niet volledig ready."
    kubectl rollout status deploy/mssql-tools -n "$MSSQL_NAMESPACE" --timeout=180s || echo "mssql-tools deployment niet volledig ready."

    # Optioneel vragen of we een .bak willen restoren
    echo ""
    read -p "Wil je ook een MSSQL .bak file restoren? (y/n) " DO_BAK

    if [[ "$DO_BAK" == "y" || "$DO_BAK" == "Y" ]]; then
        echo ""
        echo "Beschikbare .bak files in $LOCAL_BAK_DIR:"
        ls -1 "$LOCAL_BAK_DIR"/*.bak 2>/dev/null || echo "Geen .bak files gevonden."

        echo ""
        read -p "Geef de exacte bestandsnaam van de .bak (zonder pad, enkel filename): " BAK_NAME

        if [[ -z "$BAK_NAME" ]]; then
            echo "Geen .bak file opgegeven, sla MSSQL-restore over."
        else
            FULL_LOCAL_BAK="$LOCAL_BAK_DIR/$BAK_NAME"
            if [[ ! -f "$FULL_LOCAL_BAK" ]]; then
                echo "Bestand '$FULL_LOCAL_BAK' bestaat niet. MSSQL-restore wordt overgeslagen."
            else
                echo ""
                echo "SA-wachtwoord ophalen uit secret '$MSSQL_SECRET_NAME'..."

                SA_PASSWORD=$(kubectl get secret "$MSSQL_SECRET_NAME" -n "$MSSQL_NAMESPACE" \
                    -o jsonpath="{.data.$MSSQL_SECRET_KEY}" 2>/dev/null | base64 -d || true)

                if [[ -z "$SA_PASSWORD" ]]; then
                    echo "Kon SA_PASSWORD niet ophalen. MSSQL-restore overslaan."
                else
                    echo "Zoeken naar MSSQL pods..."

                    MSSQL_POD=$(kubectl get pod -n "$MSSQL_NAMESPACE" -l "$MSSQL_DB_POD_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
                    TOOLS_POD=$(kubectl get pod -n "$MSSQL_NAMESPACE" -l "$MSSQL_TOOLS_POD_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

                    if [[ -z "$MSSQL_POD" || -z "$TOOLS_POD" ]]; then
                        echo "Kon MSSQL of mssql-tools pod niet vinden. MSSQL-restore wordt overgeslagen."
                    else
                        echo ""
                        echo "Kopieer .bak naar MSSQL pod: $MSSQL_POD ..."
                        kubectl exec -n "$MSSQL_NAMESPACE" "$MSSQL_POD" -- mkdir -p "$MSSQL_BACKUP_DIR" || true

                        kubectl cp "$FULL_LOCAL_BAK" "$MSSQL_NAMESPACE/$MSSQL_POD:$MSSQL_BACKUP_DIR/$BAK_NAME"

                        echo "Start RESTORE DATABASE vanuit .bak..."

                        set +e
                        kubectl exec -n "$MSSQL_NAMESPACE" "$TOOLS_POD" -- /opt/mssql-tools/bin/sqlcmd \
                          -S "$MSSQL_SVC_FQDN" \
                          -U SA -P "$SA_PASSWORD" \
                          -Q "RESTORE DATABASE [$MSSQL_DB_NAME]
                              FROM DISK = N'$MSSQL_BACKUP_DIR/$BAK_NAME'
                              WITH REPLACE, RECOVERY, STATS=10;"
                        RC=$?
                        set -e

                        if [[ $RC -ne 0 ]]; then
                            echo "RESTORE DATABASE uit .bak is mislukt (exit code $RC). Check logs."
                        else
                            echo "MSSQL-database succesvol teruggezet uit $BAK_NAME."
                        fi
                    fi
                fi
            fi
        fi
    else
        echo "MSSQL .bak restore overgeslagen op verzoek."
    fi

else
    echo "Geen MSSQL-omgeving gevonden (namespace $MSSQL_NAMESPACE + deployments). MSSQL .bak restore wordt overgeslagen."
fi
