#!/bin/bash

################################################################################
# Delete Old EBS Snapshots - Storage Cleanup Script
#
# Purpose: Delete very old EBS snapshots to reduce storage costs
#
# Savings: $0.05/GB-month per snapshot
# Risk Level: LOW (only deletes very old snapshots, keeps tagged ones)
# Recovery: None (snapshots are deleted permanently)
#
# Usage:
#   ./delete_old_snapshots.sh --csv 03_ebs_snapshots.csv --dry-run
#   ./delete_old_snapshots.sh --csv 03_ebs_snapshots.csv --min-age-days 730 --execute
#
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
AWS_PROFILE="${AWS_PROFILE:-default}"
CSV_FILE=""
DRY_RUN=true
INTERACTIVE=false
MIN_AGE_DAYS=730  # 2 years default
KEEP_TAGGED=true  # Keep snapshots with retention tags
PROTECT_TAGS="Retention,Keep,DoNotDelete,Backup"
LOG_FILE="snapshot-deletion-$(date +%Y%m%d-%H%M%S).log"

# Counters
TOTAL_SNAPSHOTS=0
DELETED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
PROTECTED_COUNT=0
TOTAL_SIZE_GB=0
TOTAL_SAVINGS=0

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $*" | tee -a "$LOG_FILE"
}

is_protected_by_tag() {
    local tags="$1"

    if [ "$KEEP_TAGGED" = false ]; then
        return 1  # Not protected
    fi

    if [ -z "$tags" ] || [ "$tags" = "N/A" ]; then
        return 1  # Not protected (no tags)
    fi

    # Check for retention/keep tags
    IFS=',' read -ra PROTECT_ARRAY <<< "$PROTECT_TAGS"
    for protect_tag in "${PROTECT_ARRAY[@]}"; do
        if echo "$tags" | grep -qi "$protect_tag"; then
            return 0  # Protected
        fi
    done

    return 1
}

delete_snapshot() {
    local region=$1
    local snapshot_id=$2
    local volume_id=$3
    local days_old=$4
    local size=$5
    local description=$6
    local tags=$7

    TOTAL_SNAPSHOTS=$((TOTAL_SNAPSHOTS + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Processing snapshot: $snapshot_id"
    log_info "  Region: $region"
    log_info "  Volume: $volume_id"
    log_info "  Age: $days_old days"
    log_info "  Size: $size GB"

    # Check age requirement
    if [ "$days_old" = "N/A" ]; then
        log_warn "Cannot determine snapshot age, skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    if [ "$days_old" -lt "$MIN_AGE_DAYS" ]; then
        log_warn "Snapshot is only $days_old days old (min: $MIN_AGE_DAYS), skipping"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Check for retention tags
    if is_protected_by_tag "$tags"; then
        log_warn "Snapshot has retention/keep tag, skipping for safety"
        log_info "  Tags: $tags"
        PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
        return 1
    fi

    # Calculate savings
    local monthly_cost=$(echo "$size * 0.05" | bc 2>/dev/null || echo "0")

    # Interactive confirmation
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}DELETE CONFIRMATION REQUIRED${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Snapshot ID:  ${CYAN}$snapshot_id${NC}"
        echo -e "Region:       ${CYAN}$region${NC}"
        echo -e "Age:          ${CYAN}$days_old days${NC} ($(echo "$days_old / 365" | bc) years)"
        echo -e "Size:         ${CYAN}$size GB${NC}"
        echo -e "Volume:       ${CYAN}$volume_id${NC}"
        echo -e "Description:  $description"
        echo -e "Monthly cost: ${RED}\$$monthly_cost${NC}"
        echo -e "${RED}WARNING: Snapshots cannot be recovered after deletion!${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Delete this snapshot? (y/n/q): " -r response
        echo ""

        case "$response" in
            y|Y|yes|YES) ;;
            q|Q|quit|QUIT) log_info "User quit"; exit 0 ;;
            *) log_info "Skipped $snapshot_id"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); return 1 ;;
        esac
    fi

    # Delete snapshot
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would delete snapshot: $snapshot_id ($size GB, $days_old days old) - saves \$$monthly_cost/month"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SIZE_GB=$((TOTAL_SIZE_GB + size))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    fi

    log_info "Deleting snapshot: $snapshot_id..."
    if aws ec2 delete-snapshot --region "$region" --snapshot-id "$snapshot_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Deleted snapshot: $snapshot_id ($size GB) - saves \$$monthly_cost/month"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SIZE_GB=$((TOTAL_SIZE_GB + size))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    else
        log_error "Failed to delete snapshot: $snapshot_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

show_usage() {
    cat << EOF
Delete Old EBS Snapshots - Storage Cleanup Script

PURPOSE:
  Delete very old EBS snapshots to reduce storage costs.
  Default: Only deletes snapshots older than 2 years.
  Keeps snapshots with retention tags for safety.

USAGE:
  $0 --csv FILE [OPTIONS]

OPTIONS:
  --csv FILE                Path to 03_ebs_snapshots.csv from audit
  --profile PROFILE         AWS profile to use (default: $AWS_PROFILE)
  --min-age-days DAYS       Only delete snapshots older than X days (default: $MIN_AGE_DAYS)
  --protect-tags TAGS       Comma-separated tags to protect (default: $PROTECT_TAGS)

  EXECUTION MODES:
  --dry-run                 Preview deletions without executing (DEFAULT)
  --interactive             Confirm each deletion
  --execute                 Execute deletions automatically

  SAFETY OPTIONS:
  --keep-tagged             Keep snapshots with retention tags (DEFAULT: enabled)
  --no-keep-tagged          Delete all old snapshots regardless of tags
  --help                    Show this help

EXAMPLES:
  # Preview deletion of snapshots older than 2 years (safe)
  $0 --csv 03_ebs_snapshots.csv --dry-run

  # Delete snapshots older than 3 years (interactive)
  $0 --csv 03_ebs_snapshots.csv --min-age-days 1095 --interactive

  # Delete very old snapshots (automated)
  $0 --csv 03_ebs_snapshots.csv --min-age-days 730 --execute

  # Delete old snapshots but keep ones tagged for backup
  $0 --csv 03_ebs_snapshots.csv --keep-tagged --execute

SAFETY:
  - Only deletes snapshots older than specified age (default: 730 days/2 years)
  - Keeps snapshots with retention/backup tags by default
  - Interactive mode available for manual review
  - Full logging and audit trail
  - Age verification before deletion

WARNING:
  Deleted snapshots CANNOT be recovered!
  Always use --dry-run first to preview changes.
  Consider using --keep-tagged to protect important backups.

COST SAVINGS:
  - Snapshots cost \$0.05/GB-month
  - A 100 GB snapshot = \$5/month = \$60/year
  - Deleting 1 TB of old snapshots = \$50/month = \$600/year

PROTECTED TAGS (Default):
  Snapshots with these tags are kept (when --keep-tagged is enabled):
  - Retention, Keep, DoNotDelete, Backup

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --csv) CSV_FILE="$2"; shift 2 ;;
        --profile) AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
        --min-age-days) MIN_AGE_DAYS="$2"; shift 2 ;;
        --protect-tags) PROTECT_TAGS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --interactive) INTERACTIVE=true; DRY_RUN=false; shift ;;
        --execute) DRY_RUN=false; shift ;;
        --keep-tagged) KEEP_TAGGED=true; shift ;;
        --no-keep-tagged) KEEP_TAGGED=false; shift ;;
        --help) show_usage; exit 0 ;;
        *) echo "Unknown option: $1"; show_usage; exit 1 ;;
    esac
done

# Validate
if [ -z "$CSV_FILE" ]; then
    echo -e "${RED}ERROR: No CSV file specified${NC}"
    show_usage
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo -e "${RED}ERROR: CSV file not found: $CSV_FILE${NC}"
    exit 1
fi

# Banner
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Delete Old EBS Snapshots - Storage Cleanup Script${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "AWS Profile: $AWS_PROFILE"
log_info "CSV File: $CSV_FILE"
log_info "Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "EXECUTE")"
log_info "Min Age Days: $MIN_AGE_DAYS ($(echo "$MIN_AGE_DAYS / 365" | bc) years)"
log_info "Keep Tagged: $KEEP_TAGGED"
if [ "$KEEP_TAGGED" = true ]; then
    log_info "Protected Tags: $PROTECT_TAGS"
fi
log_info "Log File: $LOG_FILE"
echo ""

# Warning for execute mode
if [ "$DRY_RUN" = false ] && [ "$INTERACTIVE" = false ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: SNAPSHOTS WILL BE PERMANENTLY DELETED!${NC}"
    echo -e "${RED}DELETED SNAPSHOTS CANNOT BE RECOVERED!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "You are about to delete snapshots older than $MIN_AGE_DAYS days."
    echo ""
    read -p "Are you ABSOLUTELY SURE? Type 'DELETE SNAPSHOTS' to confirm: " -r confirm
    if [ "$confirm" != "DELETE SNAPSHOTS" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""
fi

# Process CSV
line_number=0
while IFS=',' read -r region snapshot_id volume_id start_time days_old size state description encrypted tags recommendation cost; do
    line_number=$((line_number + 1))

    # Skip header
    if [ $line_number -eq 1 ]; then
        continue
    fi

    # Only process DELETE recommendations
    if [[ ! "$recommendation" =~ DELETE ]]; then
        continue
    fi

    # Clean up quoted fields
    description=$(echo "$description" | tr -d '"')
    tags=$(echo "$tags" | tr -d '"')

    # Delete snapshot
    delete_snapshot "$region" "$snapshot_id" "$volume_id" "$days_old" "$size" "$description" "$tags"

done < "$CSV_FILE"

# Summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Total snapshots processed: $TOTAL_SNAPSHOTS"
echo -e "Deleted:                   ${GREEN}$DELETED_COUNT${NC}"
echo -e "Skipped (too new):         ${YELLOW}$SKIPPED_COUNT${NC}"
echo -e "Protected (tagged):        ${YELLOW}$PROTECTED_COUNT${NC}"
echo -e "Failed:                    ${RED}$FAILED_COUNT${NC}"
echo ""
echo -e "Total storage freed:       ${GREEN}$TOTAL_SIZE_GB GB${NC}"
echo -e "Monthly savings:           ${GREEN}\$$TOTAL_SAVINGS${NC}"
echo -e "Annual savings:            ${GREEN}\$$(echo "$TOTAL_SAVINGS * 12" | bc)${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY-RUN. No snapshots were actually deleted.${NC}"
    echo -e "${CYAN}Run with --execute to perform the deletions.${NC}"
    echo ""
fi

log_info "Log file: $LOG_FILE"
echo ""
