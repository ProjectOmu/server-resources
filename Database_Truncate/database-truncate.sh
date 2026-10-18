#!/bin/bash

# Set CPU affinity. You should adjust the CPU cores based on your system's configuration.
taskset -cp 14-15 $$ 2>/dev/null || true

DB_HOST="127.0.0.1" # Leave as this if running this script on your database server.
DB_PORT="5432"
DB_USER="<user>"
DB_PASS="<password>"

DATABASES=(
    "database1",
    "database2",
    "database3"
)

RETENTION="1 month" # 1 month, 1 week, 1 year, etc. Retention period and others are truncated.
BATCH_SIZE=250000 # Number of rows to delete in each batch. Adjust based on your system's performance and load.
TIMESTAMP_COL="date"
ADMIN_LOG_TABLE="admin_log"
ADMIN_LOG_PLAYER_TABLE="admin_log_player"

export PGPASSWORD="$DB_PASS"

CUTOFF_DATE=$(date -d "$RETENTION ago" "+%Y-%m-%d %H:%M:%S")

echo "Retention Period (after this long we kill logs): $RETENTION"
echo "Cutoff Date: $CUTOFF_DATE"

format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

format_time() {
    local seconds=$1
    if [ $seconds -lt 60 ]; then
        echo "${seconds}s"
    elif [ $seconds -lt 3600 ]; then
        echo "$((seconds/60))m $((seconds%60))s"
    else
        echo "$((seconds/3600))h $((seconds%3600/60))m"
    fi
}

prune_table() {
    local CURRENT_DB=$1
    local TABLE=$2
    local CONDITION_SQL=$3

    local TOTAL_DELETED=0
    local START_TIME=$(date +%s)
    local BATCH_NUM=0
    local LAST_LOG_TIME=0

    echo ""
    echo "Database: $CURRENT_DB | Table: $TABLE | Batch Size: $(format_number $BATCH_SIZE)"

    while true; do
        CMD="DELETE FROM $TABLE WHERE (round_id, admin_log_id) IN (
            SELECT round_id, admin_log_id FROM $TABLE
            WHERE $CONDITION_SQL
            LIMIT $BATCH_SIZE
        );"

        BATCH_START=$(date +%s)
        OUTPUT=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$CURRENT_DB" -c "$CMD" 2>&1)
        BATCH_DURATION=$(($(date +%s) - BATCH_START))

        if [ $? -ne 0 ]; then
            echo "[$CURRENT_DB] ERROR: Failed query on $TABLE"
            echo "[$CURRENT_DB] Details: $OUTPUT"
            return 1
        fi

        DELETED_COUNT=$(echo "$OUTPUT" | grep "DELETE" | awk '{print $2}')
        if [[ -z "$DELETED_COUNT" ]]; then DELETED_COUNT=0; fi

        if [[ "$DELETED_COUNT" -eq 0 ]]; then
            echo "[$CURRENT_DB] No more rows to delete."
            break
        fi

        TOTAL_DELETED=$((TOTAL_DELETED + DELETED_COUNT))
        BATCH_NUM=$((BATCH_NUM + 1))
        ELAPSED=$(($(date +%s) - START_TIME))
        CURRENT_TIME=$(date +%s)

        if [ $ELAPSED -gt 0 ] && [ $TOTAL_DELETED -gt 0 ]; then
            RATE=$((TOTAL_DELETED / ELAPSED))

            if [ $((CURRENT_TIME - LAST_LOG_TIME)) -ge 30 ] || [ $BATCH_NUM -eq 1 ]; then
                echo "[$CURRENT_DB] Progress: Deleted $(format_number $TOTAL_DELETED) rows | Rate: $(format_number $RATE)/s | Elapsed: $(format_time $ELAPSED) | Batches: $BATCH_NUM"
                LAST_LOG_TIME=$CURRENT_TIME
            fi
        fi
    done

    echo "[$CURRENT_DB] Vacuuming $TABLE..."
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$CURRENT_DB" -c "VACUUM ANALYZE $TABLE;" 2>&1 | grep -v "could not resize shared memory" > /dev/null
    echo "[$CURRENT_DB] Vacuum completed for $TABLE"
}


echo "[$(date)] Starting Batch Prune"

for DB in "${DATABASES[@]}"; do
    (
        echo "------------------------------------------------"
        echo "Processing Database: $DB"
        echo "------------------------------------------------"

        PARENT_CONDITION="$TIMESTAMP_COL < '$CUTOFF_DATE'"

        prune_table "$DB" "$ADMIN_LOG_TABLE" "$PARENT_CONDITION"

        echo "[$(date)] Finished: $DB"
    ) &
done

wait
echo "[$(date)] All operations finished."
