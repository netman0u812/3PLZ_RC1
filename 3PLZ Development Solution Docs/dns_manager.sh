#!/bin/bash

DOMAIN_INDEX_FILE="domain_index.txt"

log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "dns_change.log"
}

lookup_domain_info() {
    local domain_id="$1"
    local line
    line=$(grep "^$domain_id " "$DOMAIN_INDEX_FILE")
    if [[ -z "$line" ]]; then
        echo "❌ Domain ID '$domain_id' not found in index."
        return 1
    fi
    read -r _domain_id forward_path reverse_path rcs_user <<< "$line"
    echo "$forward_path|$reverse_path|$rcs_user"
}

apply_changes() {
    DOMAIN_ID="$1"
    CHANGE_FILE="$2"
    LOG_FILE="dns_change.log"

    domain_info=$(lookup_domain_info "$DOMAIN_ID") || return 1
    IFS='|' read -r FORWARD_FILE REVERSE_FILE RCS_USER <<< "$domain_info"

    for file in "$FORWARD_FILE" "$REVERSE_FILE" "$LOG_FILE"; do
        [ ! -f "$file,v" ] && ci -u "$file" >/dev/null 2>&1
    done

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        read -r change_type record_type hostname ip <<< "$line"
        IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
        reverse_ip="${o4}.${o3}.${o2}.${o1}.in-addr.arpa"
        forward_entry="${hostname} ${record_type} ${ip}"
        reverse_entry="${reverse_ip} PTR ${hostname}"

        case "$change_type" in
            add)
                if ! grep -qF "$forward_entry" "$FORWARD_FILE" && ! grep -qF "$reverse_entry" "$REVERSE_FILE"; then
                    echo "$forward_entry" >> "$FORWARD_FILE"
                    [[ "$record_type" == "A" ]] && echo "$reverse_entry" >> "$REVERSE_FILE"
                    log_action "ADD: $forward_entry and $reverse_entry added."
                else
                    log_action "ADD SKIPPED: Conflict detected."
                fi
                ;;
            del)
                if grep -qF "$forward_entry" "$FORWARD_FILE" && grep -qF "$reverse_entry" "$REVERSE_FILE"; then
                    sed -i "\|$forward_entry|d" "$FORWARD_FILE"
                    [[ "$record_type" == "A" ]] && sed -i "\|$reverse_entry|d" "$REVERSE_FILE"
                    log_action "DEL: $forward_entry and $reverse_entry deleted."
                else
                    log_action "DEL SKIPPED: No match found."
                fi
                ;;
            exc)
                if grep -qF "$forward_entry" "$FORWARD_FILE" && grep -qF "$reverse_entry" "$REVERSE_FILE"; then
                    sed -i "s|$forward_entry|# $forward_entry|" "$FORWARD_FILE"
                    [[ "$record_type" == "A" ]] && sed -i "s|$reverse_entry|# $reverse_entry|" "$REVERSE_FILE"
                    log_action "EXC: $forward_entry and $reverse_entry excluded."
                else
                    log_action "EXC SKIPPED: No match found."
                fi
                ;;
            mod)
                if [[ "$record_type" == "A" ]]; then
                    if grep -q "A $ip" "$FORWARD_FILE" && grep -q "$reverse_ip PTR" "$REVERSE_FILE"; then
                        sed -i "s|.* A $ip|$hostname A $ip|" "$FORWARD_FILE"
                        sed -i "s|$reverse_ip PTR .*|$reverse_ip PTR $hostname|" "$REVERSE_FILE"
                        log_action "MOD: Hostname for IP $ip modified to $hostname."
                    else
                        log_action "MOD SKIPPED: IP $ip not found."
                    fi
                fi
                ;;
            *)
                log_action "UNKNOWN CHANGE TYPE: $change_type"
                ;;
        esac
    done < "$CHANGE_FILE"

    for file in "$FORWARD_FILE" "$REVERSE_FILE" "$LOG_FILE"; do
        ci -u -m"Automated update via dns_manager.sh" "$file"
    done
}

rollback_file() {
    FILE="$1"
    VERSION="$2"
    echo "⚠️  Rollback '$FILE' to version '$VERSION'."
    read -p "Proceed? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && co -r"$VERSION" "$FILE" && echo "✅ Rolled back." || echo "❌ Cancelled."
}

diff_versions() {
    FILE="$1"
    V1="$2"
    V2="$3"
    echo "📊 Diff between '$FILE' versions '$V1' and '$V2'."
    read -p "Proceed? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && rcsdiff -r"$V1" -r"$V2" "$FILE" || echo "❌ Cancelled."
}

list_domain_index() {
    echo "📋 Domain Index Entries:"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        read -r domain_id forward_path reverse_path rcs_user <<< "$line"
        echo "Domain ID: $domain_id"
        echo "  Forward File: $forward_path"
        echo "  Reverse File: $reverse_path"
        echo "  RCS User: $rcs_user"
        echo ""
    done < "$DOMAIN_INDEX_FILE"
}

add_domain_to_index() {
    read -p "Enter Domain ID (0000–9999): " domain_id
    if ! [[ "$domain_id" =~ ^[0-9]{4}$ ]]; then
        echo "❌ Invalid Domain ID format."
        return 1
    fi
    if grep -q "^$domain_id " "$DOMAIN_INDEX_FILE"; then
        echo "❌ Domain ID already exists."
        return 1
    fi
    read -p "Enter Forward Record Path: " forward_path
    read -p "Enter Reverse Record Path: " reverse_path
    read -p "Enter RCS User ID: " rcs_user
    echo "$domain_id $forward_path $reverse_path $rcs_user" >> "$DOMAIN_INDEX_FILE"
    echo "✅ Domain ID '$domain_id' added to index."
}

edit_domain_entry() {
    read -p "Enter Domain ID to edit: " domain_id
    line=$(grep "^$domain_id " "$DOMAIN_INDEX_FILE")
    if [[ -z "$line" ]]; then
        echo "❌ Domain ID not found."
        return 1
    fi
    read -r _id old_forward old_reverse old_rcs <<< "$line"
    echo "Current Forward Path: $old_forward"
    read -p "New Forward Path (or press Enter to keep): " new_forward
    new_forward=${new_forward:-$old_forward}
    echo "Current Reverse Path: $old_reverse"
    read -p "New Reverse Path (or press Enter to keep): " new_reverse
    new_reverse=${new_reverse:-$old_reverse}
    echo "Current RCS User ID: $old_rcs"
    read -p "New RCS User ID (or press Enter to keep): " new_rcs
    new_rcs=${new_rcs:-$old_rcs}
    sed -i "\|^$domain_id |d" "$DOMAIN_INDEX_FILE"
    echo "$domain_id $new_forward $new_reverse $new_rcs" >> "$DOMAIN_INDEX_FILE"
    echo "✅ Domain ID '$domain_id' updated."
}

delete_domain_entry() {
    read -p "Enter Domain ID to delete: " domain_id
    if ! grep -q "^$domain_id " "$DOMAIN_INDEX_FILE"; then
        echo "❌ Domain ID not found."
        return 1
    fi
    read -p "Are you sure you want to delete Domain ID '$domain_id'? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sed -i "\|^$domain_id |d" "$DOMAIN_INDEX_FILE"
        echo "✅ Domain ID '$domain_id' deleted."
    else
        echo "❌ Deletion cancelled."
    fi
}

menu_cli() {
    echo "🧭 DNS Record Management Menu"
    while true; do
        echo ""
        echo "1) Apply changes"
        echo "2) Rollback file"
        echo "3) View diff between versions"
        echo "4) List domain index"
        echo "5) Add new domain to index"
        echo "6) Edit domain entry"
        echo "7) Delete domain entry"
        echo "8) Exit"
        read -p "Choose an option [1-8]: " choice
        case "$choice" in
            1) read -p "Enter Domain ID: " domain_id
               read -p "Change file: " cf
               apply_changes "$domain_id" "$cf" ;;
            2) read -p "File to rollback: " file
               read -p "Version to rollback to: " version
               rollback_file "$file" "$version" ;;
            3) read -p "File to diff: " file
               read -p "Version 1: " v1
               read -p "Version 2: " v2
               diff_versions "$file" "$v1" "$v2" ;;
            4) list_domain_index ;;
            5) add_domain_to_index ;;
            6) edit_domain_entry ;;
            7) delete_domain_entry ;;
            8) echo "👋 Exiting."; break ;;
            *) echo "❌ Invalid option." ;;
        esac
    done
}

if [[ "$1" == "--menu" ]]; then
    menu_cli
else
    case "$1" in
        apply) apply_changes "$2" "$3" ;;
        rollback) rollback_file "$2" "$3" ;;
        diff) diff_versions "$2" "$3" "$4" ;;
        list-index) list_domain_index ;;
        add-domain) add_domain_to_index ;;
        edit-domain) edit_domain_entry ;;
        delete-domain) delete_domain_entry ;;
        *) echo "Usage:"
           echo "  $0 apply <domain_id> <change_file>"
           echo "  $0 rollback <file> <version>"
           echo "  $0 diff <file> <version1> <version2>"
           echo "  $0 list-index"
           echo "  $0 add-domain"
           echo "  $0 edit-domain"
           echo "  $0 delete-domain"
           echo "  $0 --menu  # Launch interactive menu" ;;
    esac
}
