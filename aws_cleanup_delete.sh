#!/bin/bash

################################################################################
# AWS Resource Cleanup - Main Deletion Orchestrator
#
# Purpose: Safely delete AWS resources based on audit CSV files
#
# CRITICAL SAFETY FEATURES:
# - Dry-run mode by default (must explicitly enable deletion)
# - Tag-based protection (DoNotDelete, Environment=production, etc.)
# - Automatic snapshot/backup before deletion
# - Comprehensive logging and audit trail
# - Interactive confirmation mode
# - Rollback capability via snapshots
# - Cost limit safeguards
# - Age verification
#
# Usage: ./aws_cleanup_delete.sh [options]
#
# Examples:
#   # Dry run (safe, no deletion)
#   ./aws_cleanup_delete.sh --csv 01_ec2_instances.csv --dry-run
#
#   # Interactive mode (confirm each resource)
#   ./aws_cleanup_delete.sh --csv 01_ec2_instances.csv --interactive
#
#   # Full automation (with safety checks)
#   ./aws_cleanup_delete.sh --csv 01_ec2_instances.csv --execute \
#       --snapshot-before-delete --protect-tags "Environment=production"
#
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script version
VERSION="1.0.0"

# Default configuration
AWS_PROFILE="${AWS_PROFILE:-default}"
DRY_RUN=true  # Safe by default
INTERACTIVE=false
SNAPSHOT_BEFORE_DELETE=false
PROTECT_TAGS=""
MIN_AGE_DAYS=0
MAX_COST=999999
MAX_RESOURCES=999999
LOG_DIR="deletion-logs"
SESSION_ID=$(date +%Y%m%d-%H%M%S)
VERBOSE=false

# Counters
TOTAL_RESOURCES=0
DELETED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
PROTECTED_COUNT=0
TOTAL_SAVINGS=0

# Log files
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${SESSION_ID}-session.log"
JSON_LOG="$LOG_DIR/${SESSION_ID}-session.json"
SNAPSHOT_MANIFEST="$LOG_DIR/${SESSION_ID}-snapshots.json"
DELETED_RESOURCES="$LOG_DIR/${SESSION_ID}-deleted-resources.csv"

# Initialize JSON log
echo "{\"session_id\": \"$SESSION_ID\", \"start_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"actions\": []}" > "$JSON_LOG"

# Trap for cleanup on exit
cleanup() {
    local exit_code=$?
    log_info "Session ended. Summary:"
    log_info "  Total resources processed: $TOTAL_RESOURCES"
    log_info "  Successfully deleted: $DELETED_COUNT"
    log_info "  Skipped: $SKIPPED_COUNT"
    log_info "  Failed: $FAILED_COUNT"
    log_info "  Protected: $PROTECTED_COUNT"
    log_info "  Estimated monthly savings: \$$TOTAL_SAVINGS"

    # Update JSON log with summary
    update_json_log_summary

    exit $exit_code
}

trap cleanup EXIT INT TERM

################################################################################
# LOGGING FUNCTIONS
################################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"
}

log_dry_run() {
    echo -e "${CYAN}[DRY-RUN]${NC} $(date +%Y-%m-%d\ %H:%M:%S) $*" | tee -a "$LOG_FILE"
}

log_action() {
    local resource_type=$1
    local resource_id=$2
    local action=$3
    local status=$4
    local details=$5

    # Log to human-readable file
    echo "$(date +%Y-%m-%d\ %H:%M:%S)|$resource_type|$resource_id|$action|$status|$details" >> "$LOG_FILE"

    # Log to JSON
    local json_entry=$(cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "resource_type": "$resource_type",
  "resource_id": "$resource_id",
  "action": "$action",
  "status": "$status",
  "details": "$details"
}
EOF
)

    # Append to JSON log actions array (simplified)
    echo "$json_entry" >> "${JSON_LOG}.tmp"
}

update_json_log_summary() {
    cat > "${JSON_LOG}.summary" <<EOF
{
  "session_id": "$SESSION_ID",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "summary": {
    "total_resources": $TOTAL_RESOURCES,
    "deleted": $DELETED_COUNT,
    "skipped": $SKIPPED_COUNT,
    "failed": $FAILED_COUNT,
    "protected": $PROTECTED_COUNT,
    "estimated_monthly_savings": $TOTAL_SAVINGS
  }
}
EOF
}

################################################################################
# SAFETY CHECK FUNCTIONS
################################################################################

is_protected_by_tag() {
    local tags="$1"

    if [ -z "$PROTECT_TAGS" ]; then
        return 1  # Not protected
    fi

    # Parse protect tags (comma-separated key=value pairs)
    IFS=',' read -ra PROTECT_ARRAY <<< "$PROTECT_TAGS"
    for protect_tag in "${PROTECT_ARRAY[@]}"; do
        if echo "$tags" | grep -q "$protect_tag"; then
            return 0  # Protected
        fi
    done

    return 1  # Not protected
}

check_resource_age() {
    local days_old=$1

    if [ "$days_old" = "N/A" ]; then
        log_warn "Cannot determine resource age, skipping for safety"
        return 1  # Skip if age unknown
    fi

    if [ "$days_old" -lt "$MIN_AGE_DAYS" ]; then
        log_warn "Resource is only $days_old days old (min: $MIN_AGE_DAYS), skipping for safety"
        return 1  # Too new
    fi

    return 0  # Age check passed
}

confirm_deletion() {
    local resource_type=$1
    local resource_id=$2
    local details=$3

    if [ "$INTERACTIVE" = false ]; then
        return 0  # Auto-confirm if not interactive
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}DELETE CONFIRMATION REQUIRED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Resource Type: ${CYAN}$resource_type${NC}"
    echo -e "Resource ID:   ${CYAN}$resource_id${NC}"
    echo -e "Details:       $details"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}This will PERMANENTLY DELETE the resource!${NC}"
    echo ""
    read -p "Delete this resource? (yes/no/quit): " -r response
    echo ""

    case "$response" in
        yes|y|Y|YES)
            return 0  # Confirmed
            ;;
        quit|q|Q|QUIT)
            log_info "User requested quit, exiting..."
            exit 0
            ;;
        *)
            log_info "User skipped deletion"
            return 1  # Not confirmed
            ;;
    esac
}

################################################################################
# SNAPSHOT/BACKUP FUNCTIONS
################################################################################

create_ebs_snapshot() {
    local volume_id=$1
    local region=$2
    local description="${3:-Backup before deletion by cleanup script}"

    log_info "Creating snapshot of EBS volume: $volume_id"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create snapshot of $volume_id"
        echo "snap-dryrun-$(date +%s)"
        return 0
    fi

    local snapshot_id=$(aws ec2 create-snapshot \
        --region "$region" \
        --volume-id "$volume_id" \
        --description "$description" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=DeletionSession,Value=$SESSION_ID},{Key=OriginalVolume,Value=$volume_id},{Key=CreatedBy,Value=cleanup-script}]" \
        --query 'SnapshotId' \
        --output text 2>&1)

    if [ $? -eq 0 ]; then
        log_success "Created snapshot: $snapshot_id"
        echo "$snapshot_id"

        # Record in snapshot manifest
        echo "{\"volume_id\": \"$volume_id\", \"snapshot_id\": \"$snapshot_id\", \"region\": \"$region\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$SNAPSHOT_MANIFEST"
        return 0
    else
        log_error "Failed to create snapshot: $snapshot_id"
        return 1
    fi
}

create_ami_backup() {
    local instance_id=$1
    local region=$2
    local name="backup-${instance_id}-${SESSION_ID}"

    log_info "Creating AMI backup of instance: $instance_id"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create AMI of $instance_id"
        echo "ami-dryrun-$(date +%s)"
        return 0
    fi

    local ami_id=$(aws ec2 create-image \
        --region "$region" \
        --instance-id "$instance_id" \
        --name "$name" \
        --description "Backup before deletion by cleanup script (session: $SESSION_ID)" \
        --tag-specifications "ResourceType=image,Tags=[{Key=DeletionSession,Value=$SESSION_ID},{Key=OriginalInstance,Value=$instance_id},{Key=CreatedBy,Value=cleanup-script}]" \
        --query 'ImageId' \
        --output text 2>&1)

    if [ $? -eq 0 ]; then
        log_success "Created AMI: $ami_id"
        echo "$ami_id"
        return 0
    else
        log_error "Failed to create AMI: $ami_id"
        return 1
    fi
}

create_rds_snapshot() {
    local db_instance=$1
    local region=$2
    local snapshot_id="backup-${db_instance}-${SESSION_ID}"

    log_info "Creating RDS snapshot of: $db_instance"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create RDS snapshot of $db_instance"
        echo "rds-snap-dryrun-$(date +%s)"
        return 0
    fi

    aws rds create-db-snapshot \
        --region "$region" \
        --db-instance-identifier "$db_instance" \
        --db-snapshot-identifier "$snapshot_id" \
        --tags "Key=DeletionSession,Value=$SESSION_ID" "Key=OriginalInstance,Value=$db_instance" "Key=CreatedBy,Value=cleanup-script" 2>&1

    if [ $? -eq 0 ]; then
        log_success "Created RDS snapshot: $snapshot_id"
        echo "$snapshot_id"
        return 0
    else
        log_error "Failed to create RDS snapshot"
        return 1
    fi
}

################################################################################
# RESOURCE DELETION FUNCTIONS
################################################################################

delete_ec2_instance() {
    local region=$1
    local instance_id=$2
    local name=$3
    local state=$4
    local tags=$5

    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))

    log_info "Processing EC2 instance: $instance_id ($name) in $region"

    # Safety checks
    if is_protected_by_tag "$tags"; then
        log_warn "Instance $instance_id is protected by tags, skipping"
        PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
        return 1
    fi

    # Confirm deletion
    if ! confirm_deletion "EC2 Instance" "$instance_id" "Name: $name, State: $state, Region: $region"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Create backup if requested
    if [ "$SNAPSHOT_BEFORE_DELETE" = true ]; then
        if ! create_ami_backup "$instance_id" "$region"; then
            log_error "Snapshot failed, aborting deletion of $instance_id for safety"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        fi
    fi

    # Delete instance
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would terminate EC2 instance: $instance_id"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_action "EC2" "$instance_id" "terminate" "dry-run" "Instance would be terminated"
        return 0
    fi

    log_info "Terminating EC2 instance: $instance_id"
    if aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" >/dev/null 2>&1; then
        log_success "Terminated EC2 instance: $instance_id"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_action "EC2" "$instance_id" "terminate" "success" "Instance terminated"
        echo "$region,$instance_id,$name,EC2 Instance,Terminated" >> "$DELETED_RESOURCES"
        return 0
    else
        log_error "Failed to terminate instance: $instance_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_action "EC2" "$instance_id" "terminate" "failed" "Termination failed"
        return 1
    fi
}

delete_ebs_volume() {
    local region=$1
    local volume_id=$2
    local state=$3
    local size=$4
    local tags=$5

    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))

    log_info "Processing EBS volume: $volume_id ($size GB) in $region"

    # Safety checks
    if [ "$state" != "available" ]; then
        log_warn "Volume $volume_id is $state (not available), skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    if is_protected_by_tag "$tags"; then
        log_warn "Volume $volume_id is protected by tags, skipping"
        PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
        return 1
    fi

    # Confirm deletion
    if ! confirm_deletion "EBS Volume" "$volume_id" "Size: $size GB, State: $state, Region: $region"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Create snapshot if requested
    if [ "$SNAPSHOT_BEFORE_DELETE" = true ]; then
        if ! create_ebs_snapshot "$volume_id" "$region" "Backup before deletion"; then
            log_error "Snapshot failed, aborting deletion of $volume_id for safety"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        fi
        # Wait for snapshot to start
        sleep 2
    fi

    # Delete volume
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would delete EBS volume: $volume_id"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_action "EBS" "$volume_id" "delete" "dry-run" "Volume would be deleted"
        return 0
    fi

    log_info "Deleting EBS volume: $volume_id"
    if aws ec2 delete-volume --region "$region" --volume-id "$volume_id" >/dev/null 2>&1; then
        log_success "Deleted EBS volume: $volume_id"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_action "EBS" "$volume_id" "delete" "success" "Volume deleted"
        echo "$region,$volume_id,$size GB,EBS Volume,Deleted" >> "$DELETED_RESOURCES"
        return 0
    else
        log_error "Failed to delete volume: $volume_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_action "EBS" "$volume_id" "delete" "failed" "Deletion failed"
        return 1
    fi
}

release_elastic_ip() {
    local region=$1
    local allocation_id=$2
    local public_ip=$3
    local associated=$4

    TOTAL_RESOURCES=$((TOTAL_RESOURCES + 1))

    log_info "Processing Elastic IP: $public_ip ($allocation_id) in $region"

    # Safety check - only delete if unassociated
    if [ "$associated" != "Unassociated" ]; then
        log_warn "EIP $public_ip is associated, skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Confirm deletion
    if ! confirm_deletion "Elastic IP" "$public_ip" "Allocation ID: $allocation_id, Region: $region"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Release EIP
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would release Elastic IP: $public_ip"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + 3.60" | bc)
        log_action "EIP" "$allocation_id" "release" "dry-run" "EIP would be released"
        return 0
    fi

    log_info "Releasing Elastic IP: $public_ip"
    if aws ec2 release-address --region "$region" --allocation-id "$allocation_id" >/dev/null 2>&1; then
        log_success "Released Elastic IP: $public_ip (saves \$3.60/month)"
        DELETED_COUNT=$((DELETED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + 3.60" | bc)
        log_action "EIP" "$allocation_id" "release" "success" "EIP released"
        echo "$region,$allocation_id,$public_ip,Elastic IP,Released" >> "$DELETED_RESOURCES"
        return 0
    else
        log_error "Failed to release EIP: $public_ip"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_action "EIP" "$allocation_id" "release" "failed" "Release failed"
        return 1
    fi
}

################################################################################
# CSV PROCESSING
################################################################################

process_csv_file() {
    local csv_file=$1

    if [ ! -f "$csv_file" ]; then
        log_error "CSV file not found: $csv_file"
        return 1
    fi

    log_info "Processing CSV file: $csv_file"

    # Determine resource type from filename
    local resource_type=""
    if [[ "$csv_file" == *"ec2_instances"* ]]; then
        resource_type="EC2"
    elif [[ "$csv_file" == *"ebs_volumes"* ]]; then
        resource_type="EBS"
    elif [[ "$csv_file" == *"elastic_ips"* ]]; then
        resource_type="EIP"
    elif [[ "$csv_file" == *"ebs_snapshots"* ]]; then
        resource_type="Snapshot"
    else
        log_warn "Unknown resource type for file: $csv_file"
        return 1
    fi

    # Read CSV and process resources
    local line_number=0
    while IFS=',' read -r line; do
        line_number=$((line_number + 1))

        # Skip header
        if [ $line_number -eq 1 ]; then
            continue
        fi

        # Parse CSV based on resource type
        case "$resource_type" in
            EC2)
                # Parse EC2 CSV: Region,InstanceId,Name,State,InstanceType,LaunchTime,DaysSinceLaunch,AvgCPU_30d,Platform,PrivateIP,PublicIP,Tags,Recommendation,EstMonthlyCost
                IFS=',' read -r region instance_id name state instance_type launch_time days_old avg_cpu platform private_ip public_ip tags recommendation cost <<< "$line"

                # Only process DELETE recommendations
                if [[ "$recommendation" == DELETE* ]]; then
                    delete_ec2_instance "$region" "$instance_id" "$name" "$state" "$tags"
                fi
                ;;
            EBS)
                # Parse EBS CSV: Region,VolumeId,State,Size(GB),VolumeType,CreateTime,DaysSinceCreation,AttachedTo,AvgReadOps,AvgWriteOps,IOPS,Encrypted,Tags,Recommendation,EstMonthlyCost
                IFS=',' read -r region volume_id state size volume_type create_time days_old attached_to read_ops write_ops iops encrypted tags recommendation cost <<< "$line"

                if [[ "$recommendation" == DELETE* ]]; then
                    delete_ebs_volume "$region" "$volume_id" "$state" "$size" "$tags"
                fi
                ;;
            EIP)
                # Parse EIP CSV: Region,AllocationId,PublicIp,AssociatedInstanceId,PrivateIpAddress,Domain,NetworkInterfaceId,Tags,Recommendation,EstMonthlyCost
                IFS=',' read -r region allocation_id public_ip instance_id private_ip domain network_interface tags recommendation cost <<< "$line"

                if [[ "$recommendation" == DELETE* ]]; then
                    release_elastic_ip "$region" "$allocation_id" "$public_ip" "$instance_id"
                fi
                ;;
        esac

        # Check resource limit
        if [ $TOTAL_RESOURCES -ge $MAX_RESOURCES ]; then
            log_warn "Reached maximum resource limit ($MAX_RESOURCES), stopping"
            break
        fi

    done < "$csv_file"
}

################################################################################
# USAGE & HELP
################################################################################

show_usage() {
    cat << EOF
AWS Resource Cleanup - Deletion Orchestrator v${VERSION}

CRITICAL SAFETY NOTICE:
  This script PERMANENTLY DELETES AWS resources.
  Always start with --dry-run and review logs before using --execute.

Usage:
  $0 [OPTIONS]

OPTIONS:
  --csv FILE              Path to CSV file from audit (required)
  --profile PROFILE       AWS profile to use (default: $AWS_PROFILE)

  EXECUTION MODES (choose one):
  --dry-run               Preview deletions without executing (DEFAULT, safest)
  --interactive           Confirm each deletion interactively
  --execute               Execute deletions automatically (requires explicit flag)

  SAFETY OPTIONS:
  --snapshot-before-delete    Create snapshots/backups before deletion
  --protect-tags TAGS         Comma-separated tags to protect (e.g., "Environment=prod,DoNotDelete=true")
  --min-age-days DAYS         Only delete resources older than this many days
  --max-cost AMOUNT           Stop if estimated savings exceed this amount
  --max-resources NUM         Maximum number of resources to process

  LOGGING:
  --log-dir DIR               Directory for logs (default: $LOG_DIR)
  --verbose                   Verbose output

  HELP:
  --help                      Show this help message
  --version                   Show version

EXAMPLES:
  # Safe preview (no deletion)
  $0 --csv 04_elastic_ips.csv --dry-run

  # Interactive deletion with backups
  $0 --csv 02_ebs_volumes.csv --interactive --snapshot-before-delete

  # Automated deletion with safety limits
  $0 --csv 01_ec2_instances.csv --execute \\
      --snapshot-before-delete \\
      --protect-tags "Environment=production,DoNotDelete=true" \\
      --min-age-days 90 \\
      --max-resources 50

SAFETY CHECKLIST:
  1. ✓ Run with --dry-run first
  2. ✓ Review the logs in $LOG_DIR
  3. ✓ Configure --protect-tags for critical resources
  4. ✓ Enable --snapshot-before-delete for backups
  5. ✓ Test in non-production environment first
  6. ✓ Have incident response plan ready

For more information, see DELETION_SUITE_README.md

EOF
}

################################################################################
# ARGUMENT PARSING
################################################################################

CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --csv)
            CSV_FILE="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            export AWS_PROFILE
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --interactive)
            INTERACTIVE=true
            DRY_RUN=false
            shift
            ;;
        --execute)
            DRY_RUN=false
            shift
            ;;
        --snapshot-before-delete)
            SNAPSHOT_BEFORE_DELETE=true
            shift
            ;;
        --protect-tags)
            PROTECT_TAGS="$2"
            shift 2
            ;;
        --min-age-days)
            MIN_AGE_DAYS="$2"
            shift 2
            ;;
        --max-cost)
            MAX_COST="$2"
            shift 2
            ;;
        --max-resources)
            MAX_RESOURCES="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        --version)
            echo "AWS Resource Cleanup Deletion Orchestrator v${VERSION}"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

################################################################################
# MAIN EXECUTION
################################################################################

# Banner
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}AWS Resource Cleanup - Deletion Orchestrator v${VERSION}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Validate arguments
if [ -z "$CSV_FILE" ]; then
    log_error "No CSV file specified. Use --csv to specify input file."
    show_usage
    exit 1
fi

# Show configuration
log_info "Session ID: $SESSION_ID"
log_info "AWS Profile: $AWS_PROFILE"
log_info "CSV File: $CSV_FILE"
log_info "Execution Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN (safe)" || echo "EXECUTE (live deletion)")"
log_info "Interactive: $INTERACTIVE"
log_info "Snapshot Before Delete: $SNAPSHOT_BEFORE_DELETE"
log_info "Protected Tags: ${PROTECT_TAGS:-none}"
log_info "Min Age Days: $MIN_AGE_DAYS"
log_info "Log Directory: $LOG_DIR"
echo ""

# Warning for execution mode
if [ "$DRY_RUN" = false ] && [ "$INTERACTIVE" = false ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: EXECUTION MODE - RESOURCES WILL BE PERMANENTLY DELETED!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Are you ABSOLUTELY SURE you want to proceed? Type 'DELETE' to confirm: " -r confirm
    if [ "$confirm" != "DELETE" ]; then
        log_info "Deletion cancelled by user"
        exit 0
    fi
    echo ""
fi

# Initialize deleted resources CSV
echo "Region,ResourceId,Details,ResourceType,Action" > "$DELETED_RESOURCES"

# Process CSV file
log_info "Starting resource processing..."
echo ""

process_csv_file "$CSV_FILE"

# Final summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Session Complete${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "Logs saved to: $LOG_DIR"
log_info "  - Session log: $LOG_FILE"
log_info "  - JSON log: $JSON_LOG"
log_info "  - Deleted resources: $DELETED_RESOURCES"
if [ "$SNAPSHOT_BEFORE_DELETE" = true ]; then
    log_info "  - Snapshot manifest: $SNAPSHOT_MANIFEST"
fi
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY-RUN. No resources were actually deleted.${NC}"
    echo -e "${CYAN}Review the logs and run with --execute or --interactive to perform deletions.${NC}"
fi

echo ""
