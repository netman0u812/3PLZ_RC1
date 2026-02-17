#!/bin/bash

CHANGE_FILE="changes.txt"
FORWARD_FILE="forward.zone"
REVERSE_FILE="reverse.zone"
LOG_FILE="dns_changes.log"
DRY_RUN=false
ZONE_NAME="example.com"
REVERSE_ZONE="0.168.192.in-addr.arpa"

# Check for dry-run flag
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "Running in dry-run mode. No changes will be made."
fi

log_change() {
    echo "$(date) - $1" >> "$LOG_FILE"
}

validate_zone() {
    named-checkzone "$ZONE_NAME" "$FORWARD_FILE" &&     named-checkzone "$REVERSE_ZONE" "$REVERSE_FILE"
}

while read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    change_type=$(echo "$line" | awk '{print tolower($1)}')
    record_type=$(echo "$line" | awk '{print toupper($2)}')
    hostname=$(echo "$line" | awk '{print $3}')
    ip=$(echo "$line" | awk '{print $4}')
    ip_last_octet=$(echo "$ip" | awk -F. '{print $4}')
    ptr_record="${ip_last_octet}.in-addr.arpa. IN PTR ${hostname}."

    case "$record_type" in
        A) forward_record="${hostname}. IN A ${ip}" ;;
        CNAME) forward_record="${hostname}. IN CNAME ${ip}" ;;
        TXT) forward_record="${hostname}. IN TXT "${ip}"" ;;
        *) echo "Unknown record type: $record_type"; continue ;;
    esac

    case "$change_type" in
        add)
            if ! grep -qF "$forward_record" "$FORWARD_FILE" && ! grep -qF "$ip" "$FORWARD_FILE" &&                ! grep -qF "$ptr_record" "$REVERSE_FILE" && ! grep -qF "$ip_last_octet" "$REVERSE_FILE"; then
                $DRY_RUN || echo "$forward_record" >> "$FORWARD_FILE"
                [[ "$record_type" == "A" ]] && $DRY_RUN || echo "$ptr_record" >> "$REVERSE_FILE"
                log_change "Added record: $forward_record"
            else
                log_change "Add conflict for $hostname, skipped"
            fi
            ;;
        del)
            if grep -qF "$forward_record" "$FORWARD_FILE" && grep -qF "$ptr_record" "$REVERSE_FILE"; then
                $DRY_RUN || sed -i "/$forward_record/d" "$FORWARD_FILE"
                [[ "$record_type" == "A" ]] && $DRY_RUN || sed -i "/$ptr_record/d" "$REVERSE_FILE"
                log_change "Deleted record: $forward_record"
            else
                log_change "Delete conflict for $hostname, skipped"
            fi
            ;;
        exc)
            if grep -qF "$forward_record" "$FORWARD_FILE"; then
                $DRY_RUN || sed -i "s|$forward_record|# $forward_record|" "$FORWARD_FILE"
                [[ "$record_type" == "A" ]] && grep -qF "$ptr_record" "$REVERSE_FILE" &&                     $DRY_RUN || sed -i "s|$ptr_record|# $ptr_record|" "$REVERSE_FILE"
                log_change "Excluded record: $forward_record"
            else
                log_change "Exclude conflict for $hostname, skipped"
            fi
            ;;
        mod)
            if grep -q "$ip" "$FORWARD_FILE" && grep -q "$ip_last_octet" "$REVERSE_FILE"; then
                $DRY_RUN || sed -i "s|.* IN A $ip|${hostname}. IN A $ip|" "$FORWARD_FILE"
                $DRY_RUN || sed -i "s|.* IN PTR .*|$ptr_record|" "$REVERSE_FILE"
                log_change "Modified record for IP $ip to hostname $hostname"
            else
                log_change "Modify conflict for IP $ip, skipped"
            fi
            ;;
        *)
            log_change "Unknown change type: $change_type"
            ;;
    esac

done < "$CHANGE_FILE"

# Validate zone files after changes
validate_zone && log_change "Zone files validated successfully" || log_change "Zone file validation failed"
