#!/bin/bash

################################################################################
# Delete Unattached EBS Volumes - High Value Script
#
# Purpose: Delete unattached EBS volumes to reduce storage costs
#
# Savings: Varies by size and type (typically $0.08-0.125/GB-month)
# Risk Level: MEDIUM (creates snapshot first for safety)
# Recovery: Restore from automatic snapshots
#
# Usage:
#   ./delete_unattached_ebs.sh --csv 02_ebs_volumes.csv --dry-run
#   ./delete_unattached_ebs.sh --csv 02_ebs_volumes.csv --min-unattached-days 90 --execute
#
################################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Configuration
AWS_PROFILE="${AWS_PROFILE:-default}"
CSV_FILE=""
DRY_RUN=true
INTERACTIVE=false
SNAPSHOT_FIRST=true  # Always snapshot by default for safety
MIN_UNATTACHED_DAYS=60
PROTECT_TAGS=""
LOG_FILE="ebs-deletion-$(date +%Y%m%d-%H%M%S).log"
SNAPSHOT_LOG="ebs-snapshots-$(date +%Y%m%d-%H%M%S).json"

# Counters
TOTAL_VOLUMES=0
DELETED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
PROTECTED_COUNT=0
SNAPSHOT_COUNT=0
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

    if [ -z "$PROTECT_TAGS" ]; then
        return 1  # Not protected
    fi

    IFS=',' read -ra PROTECT_ARRAY <<< "$PROTECT_TAGS"
    for protect_tag in "${PROTECT_ARRAY[@]}"; do
        if echo "$tags" | grep -qi "$protect_tag"; then
            return 0  # Protected
        fi
    done

    return 1
}

create_snapshot() {
    local volume_id=$1
    local region=$2
    local size=$3
    local volume_type=$4

    log_info "Creating snapshot of $volume_id ($size GB, $volume_type)..."

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create snapshot of $volume_id"
        echo "snap-dryrun-$(date +%s)"
        return 0
    fi

    local snapshot_id=$(aws ec2 create-snapshot \
        --region "$region" \
        --volume-id "$volume_id" \
        --description "Backup before deletion - $(date +%Y-%m-%d)" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=AutoBackup,Value=true},{Key=OriginalVolume,Value=$volume_id},{Key=BackupDate,Value=$(date +%Y-%m-%d)},{Key=CreatedBy,Value=ebs-cleanup-script}]" \
        --query 'SnapshotId' \
        --output text 2>&1)

    if [ $? -eq 0 ]; then
        log_success "Created snapshot: $snapshot_id"
        SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))

        # Log snapshot info
        echo "{\"volume_id\": \"$volume_id\", \"snapshot_id\": \"$snapshot_id\", \"region\": \"$region\", \"size_gb\": \"$size\", \"volume_type\": \"$volume_type\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$SNAPSHOT_LOG"

        echo "$snapshot_id"
        return 0
    else
        log_error "Failed to create snapshot: $snapshot_id"
        return 1
    fi
}

calculate_monthly_cost() {
    local size=$1
    local volume_type=$2

    local cost=0
    case "$volume_type" in
        gp2) cost=$(echo "$size * 0.10" | bc 2>/dev/null || echo "0") ;;
        gp3) cost=$(echo "$size * 0.08" | bc 2>/dev/null || echo "0") ;;
        io1|io2) cost=$(echo "$size * 0.125" | bc 2>/dev/null || echo "0") ;;
        st1) cost=$(echo "$size * 0.045" | bc 2>/dev/null || echo "0") ;;
        sc1) cost=$(echo "$size * 0.025" | bc 2>/dev/null || echo "0") ;;
        *) cost=$(echo "$size * 0.10" | bc 2>/dev/null || echo "0") ;;
    esac

    echo "$cost"
}

delete_volume() {
    local region=$1
    local volume_id=$2
    local state=$3
    local size=$4
    local volume_type=$5
    local days_old=$6
    local tags=$7

    TOTAL_VOLUMES=$((TOTAL_VOLUMES + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Processing EBS volume: $volume_id"
    log_info "  Region: $region"
    log_info "  Size: $size GB"
    log_info "  Type: $volume_type"
    log_info "  State: $state"
    log_info "  Days old: $days_old"

    # Safety check: Must be unattached
    if [ "$state" != "available" ]; then
        log_warn "Volume $volume_id is $state (not available), skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Check age requirement
    if [ "$days_old" != "N/A" ] && [ "$days_old" -lt "$MIN_UNATTACHED_DAYS" ]; then
        log_warn "Volume $volume_id is only $days_old days old (min: $MIN_UNATTACHED_DAYS), skipping"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Check protected tags
    if is_protected_by_tag "$tags"; then
        log_warn "Volume $volume_id is protected by tags, skipping"
        PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
        return 1
    fi

    # Calculate cost savings
    local monthly_cost=$(calculate_monthly_cost "$size" "$volume_type")

    # Interactive confirmation
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}DELETE CONFIRMATION REQUIRED${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Volume ID:    ${CYAN}$volume_id${NC}"
        echo -e "Region:       ${CYAN}$region${NC}"
        echo -e "Size:         ${CYAN}$size GB${NC}"
        echo -e "Type:         ${CYAN}$volume_type${NC}"
        echo -e "Days old:     ${CYAN}$days_old days${NC}"
        echo -e "Monthly cost: ${RED}\$$monthly_cost${NC}"
        echo -e ""
        if [ "$SNAPSHOT_FIRST" = true ]; then
            echo -e "${GREEN}A snapshot will be created before deletion${NC}"
        fi
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Delete this volume? (y/n/q): " -r response
        echo ""

        case "$response" in
            y|Y|yes|YES) ;;
            q|Q|quit|QUIT) log_info "User quit"; exit 0 ;;
            *) log_info "Skipped $volume_id"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); return 1 ;;
        esac
    fi

    # Create snapshot first (if enabled)
    if [ "$SNAPSHOT_FIRST" = true ]; then
        if ! create_snapshot "$volume_id" "$region" "$size" "$volume_type"; then
            log_error "Snapshot creation failed, aborting deletion of $volume_id for safety"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        fi

        # Wait a moment for snapshot to start
        if [ "$DRY_RUN" = false ]; then
            sleep 3
        fi
    fi

    # Delete volume
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would delete volume: $volume_id ($size GB $volume_type) - saves \$$monthly_cost/month"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    fi

    log_info "Deleting volume: $volume_id..."
    if aws ec2 delete-volume --region "$region" --volume-id "$volume_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Deleted volume: $volume_id - saves \$$monthly_cost/month (\$$(echo "$monthly_cost * 12" | bc)/year)"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    else
        log_error "Failed to delete volume: $volume_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

show_usage() {
    cat << EOF
Delete Unattached EBS Volumes - High Value Script

PURPOSE:
  Delete unattached EBS volumes to reduce storage costs.
  Automatically creates snapshots before deletion for safety.

USAGE:
  $0 --csv FILE [OPTIONS]

OPTIONS:
  --csv FILE                    Path to 02_ebs_volumes.csv from audit
  --profile PROFILE             AWS profile to use (default: $AWS_PROFILE)
  --min-unattached-days DAYS    Only delete volumes unattached for X days (default: $MIN_UNATTACHED_DAYS)
  --protect-tags TAGS           Comma-separated tags to protect (e.g., "Backup=true,Keep=yes")

  EXECUTION MODES:
  --dry-run                     Preview deletions without executing (DEFAULT)
  --interactive                 Confirm each deletion
  --execute                     Execute deletions automatically

  SAFETY OPTIONS:
  --snapshot-first              Create snapshot before deletion (DEFAULT: enabled)
  --no-snapshot                 Skip snapshot creation (NOT RECOMMENDED)
  --help                        Show this help

EXAMPLES:
  # Preview what would be deleted (safe)
  $0 --csv 02_ebs_volumes.csv --dry-run

  # Delete volumes unattached for 90+ days (interactive)
  $0 --csv 02_ebs_volumes.csv --min-unattached-days 90 --interactive

  # Automated deletion with snapshots
  $0 --csv 02_ebs_volumes.csv --execute --snapshot-first

  # Protect specific volumes
  $0 --csv 02_ebs_volumes.csv --protect-tags "Backup=required,DoNotDelete=true" --execute

SAFETY:
  - Only deletes volumes in "available" state (unattached)
  - Creates snapshots before deletion (can be restored)
  - Respects tag-based protection
  - Age verification (default: 60 days)
  - Interactive mode available
  - Full logging and audit trail

COST SAVINGS:
  - gp2: \$0.10/GB-month
  - gp3: \$0.08/GB-month
  - io1/io2: \$0.125/GB-month + IOPS costs
  - st1: \$0.045/GB-month
  - sc1: \$0.025/GB-month

  Example: A 100 GB gp3 volume costs \$8/month (\$96/year)

RECOVERY:
  If you need to restore a volume:
  1. Find the snapshot in EC2 Console > Snapshots
  2. Filter by tag "OriginalVolume" or "AutoBackup=true"
  3. Create new volume from snapshot
  4. Attach to instance

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --csv) CSV_FILE="$2"; shift 2 ;;
        --profile) AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
        --min-unattached-days) MIN_UNATTACHED_DAYS="$2"; shift 2 ;;
        --protect-tags) PROTECT_TAGS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --interactive) INTERACTIVE=true; DRY_RUN=false; shift ;;
        --execute) DRY_RUN=false; shift ;;
        --snapshot-first) SNAPSHOT_FIRST=true; shift ;;
        --no-snapshot) SNAPSHOT_FIRST=false; shift ;;
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
echo -e "${BLUE}Delete Unattached EBS Volumes - High Value Script${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "AWS Profile: $AWS_PROFILE"
log_info "CSV File: $CSV_FILE"
log_info "Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "EXECUTE")"
log_info "Snapshot Before Delete: $SNAPSHOT_FIRST"
log_info "Min Unattached Days: $MIN_UNATTACHED_DAYS"
log_info "Protected Tags: ${PROTECT_TAGS:-none}"
log_info "Log File: $LOG_FILE"
if [ "$SNAPSHOT_FIRST" = true ]; then
    log_info "Snapshot Log: $SNAPSHOT_LOG"
fi
echo ""

# Warning for no-snapshot mode
if [ "$SNAPSHOT_FIRST" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: Snapshot creation is DISABLED!${NC}"
    echo -e "${RED}Deleted volumes cannot be recovered without snapshots!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Are you SURE you want to proceed without snapshots? Type 'YES' to confirm: " -r confirm
    if [ "$confirm" != "YES" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""
fi

# Process CSV
line_number=0
while IFS=',' read -r region volume_id state size volume_type create_time days_old attached_to read_ops write_ops iops encrypted tags recommendation cost; do
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
    tags=$(echo "$tags" | tr -d '"')

    # Delete volume
    delete_volume "$region" "$volume_id" "$state" "$size" "$volume_type" "$days_old" "$tags"

done < "$CSV_FILE"

# Summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Total volumes processed:  $TOTAL_VOLUMES"
echo -e "Deleted:                  ${GREEN}$DELETED_COUNT${NC}"
echo -e "Snapshots created:        ${GREEN}$SNAPSHOT_COUNT${NC}"
echo -e "Skipped:                  ${YELLOW}$SKIPPED_COUNT${NC}"
echo -e "Protected:                ${YELLOW}$PROTECTED_COUNT${NC}"
echo -e "Failed:                   ${RED}$FAILED_COUNT${NC}"
echo ""
echo -e "Monthly savings:          ${GREEN}\$$TOTAL_SAVINGS${NC}"
echo -e "Annual savings:           ${GREEN}\$$(echo "$TOTAL_SAVINGS * 12" | bc)${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY-RUN. No volumes were actually deleted.${NC}"
    echo -e "${CYAN}Run with --execute to perform the deletions.${NC}"
    echo ""
fi

log_info "Logs saved:"
log_info "  - Deletion log: $LOG_FILE"
if [ "$SNAPSHOT_FIRST" = true ]; then
    log_info "  - Snapshot manifest: $SNAPSHOT_LOG"
    echo ""
    echo -e "${GREEN}Snapshots can be used to restore volumes if needed.${NC}"
    echo -e "${GREEN}Find them in EC2 Console > Snapshots, filter by 'AutoBackup=true'${NC}"
fi
echo ""
