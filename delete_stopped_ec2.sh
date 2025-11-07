#!/bin/bash

################################################################################
# Delete Stopped EC2 Instances - High Savings Script
#
# Purpose: Terminate EC2 instances that have been stopped for a long time
#
# Savings: Varies by instance type (typically $30-500/month per instance)
# Risk Level: MEDIUM (creates AMI backup first)
# Recovery: Restore from automatic AMI backup
#
# Note: Stopped instances still incur EBS storage costs!
#
# Usage:
#   ./delete_stopped_ec2.sh --csv 01_ec2_instances.csv --dry-run
#   ./delete_stopped_ec2.sh --csv 01_ec2_instances.csv --min-stopped-days 180 --execute
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
CREATE_AMI=true  # Always create AMI by default for safety
MIN_STOPPED_DAYS=90
PROTECT_TAGS=""
DELETE_VOLUMES=false  # Ask before deleting attached volumes
LOG_FILE="ec2-termination-$(date +%Y%m%d-%H%M%S).log"
AMI_LOG="ec2-amis-$(date +%Y%m%d-%H%M%S).json"

# Counters
TOTAL_INSTANCES=0
TERMINATED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
PROTECTED_COUNT=0
AMI_COUNT=0
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
        return 1
    fi

    IFS=',' read -ra PROTECT_ARRAY <<< "$PROTECT_TAGS"
    for protect_tag in "${PROTECT_ARRAY[@]}"; do
        if echo "$tags" | grep -qi "$protect_tag"; then
            return 0
        fi
    done

    return 1
}

create_ami_backup() {
    local instance_id=$1
    local region=$2
    local name=$3

    local ami_name="backup-${instance_id}-$(date +%Y%m%d-%H%M%S)"

    log_info "Creating AMI backup of instance: $instance_id"

    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would create AMI: $ami_name"
        echo "ami-dryrun-$(date +%s)"
        return 0
    fi

    local ami_id=$(aws ec2 create-image \
        --region "$region" \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "Backup before termination - $name - $(date +%Y-%m-%d)" \
        --tag-specifications "ResourceType=image,Tags=[{Key=AutoBackup,Value=true},{Key=OriginalInstance,Value=$instance_id},{Key=BackupDate,Value=$(date +%Y-%m-%d)},{Key=CreatedBy,Value=ec2-cleanup-script}]" \
        --query 'ImageId' \
        --output text 2>&1)

    if [ $? -eq 0 ]; then
        log_success "Created AMI: $ami_id"
        AMI_COUNT=$((AMI_COUNT + 1))

        # Log AMI info
        echo "{\"instance_id\": \"$instance_id\", \"ami_id\": \"$ami_id\", \"region\": \"$region\", \"name\": \"$name\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$AMI_LOG"

        echo "$ami_id"
        return 0
    else
        log_error "Failed to create AMI: $ami_id"
        return 1
    fi
}

estimate_monthly_cost() {
    local instance_type=$1

    # Rough estimates (on-demand pricing for common types)
    case "$instance_type" in
        t2.micro) echo "8.50" ;;
        t2.small) echo "17.00" ;;
        t2.medium) echo "34.00" ;;
        t2.large) echo "68.00" ;;
        t3.micro) echo "7.50" ;;
        t3.small) echo "15.00" ;;
        t3.medium) echo "30.00" ;;
        t3.large) echo "60.00" ;;
        t3.xlarge) echo "120.00" ;;
        m5.large) echo "70.00" ;;
        m5.xlarge) echo "140.00" ;;
        m5.2xlarge) echo "280.00" ;;
        m5.4xlarge) echo "560.00" ;;
        c5.large) echo "62.00" ;;
        c5.xlarge) echo "124.00" ;;
        r5.large) echo "91.00" ;;
        r5.xlarge) echo "182.00" ;;
        *) echo "50.00" ;;  # Default estimate
    esac
}

terminate_instance() {
    local region=$1
    local instance_id=$2
    local name=$3
    local state=$4
    local instance_type=$5
    local days_old=$6
    local tags=$7

    TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Processing EC2 instance: $instance_id"
    log_info "  Name: $name"
    log_info "  Region: $region"
    log_info "  Type: $instance_type"
    log_info "  State: $state"
    log_info "  Days old: $days_old"

    # Safety check: Must be stopped
    if [ "$state" != "stopped" ]; then
        log_warn "Instance $instance_id is $state (not stopped), skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Check age requirement
    if [ "$days_old" = "N/A" ]; then
        log_warn "Cannot determine instance age, skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    if [ "$days_old" -lt "$MIN_STOPPED_DAYS" ]; then
        log_warn "Instance stopped for only $days_old days (min: $MIN_STOPPED_DAYS), skipping"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        return 1
    fi

    # Check protected tags
    if is_protected_by_tag "$tags"; then
        log_warn "Instance $instance_id is protected by tags, skipping"
        PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
        return 1
    fi

    # Calculate cost savings
    local monthly_cost=$(estimate_monthly_cost "$instance_type")

    # Interactive confirmation
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}TERMINATION CONFIRMATION REQUIRED${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Instance ID:   ${CYAN}$instance_id${NC}"
        echo -e "Name:          ${CYAN}$name${NC}"
        echo -e "Region:        ${CYAN}$region${NC}"
        echo -e "Type:          ${CYAN}$instance_type${NC}"
        echo -e "State:         ${CYAN}$state${NC}"
        echo -e "Days stopped:  ${CYAN}$days_old days${NC}"
        echo -e "Monthly cost:  ${RED}\$$monthly_cost${NC} (when running)"
        echo ""
        if [ "$CREATE_AMI" = true ]; then
            echo -e "${GREEN}An AMI backup will be created before termination${NC}"
        fi
        echo -e "${RED}WARNING: EBS volumes will be deleted per DeleteOnTermination setting${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Terminate this instance? (y/n/q): " -r response
        echo ""

        case "$response" in
            y|Y|yes|YES) ;;
            q|Q|quit|QUIT) log_info "User quit"; exit 0 ;;
            *) log_info "Skipped $instance_id"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); return 1 ;;
        esac
    fi

    # Create AMI backup first (if enabled)
    if [ "$CREATE_AMI" = true ]; then
        if ! create_ami_backup "$instance_id" "$region" "$name"; then
            log_error "AMI creation failed, aborting termination of $instance_id for safety"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            return 1
        fi

        # Wait for AMI to start creating
        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting 5 seconds for AMI creation to start..."
            sleep 5
        fi
    fi

    # Terminate instance
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would terminate instance: $instance_id ($name, $instance_type) - saves ~\$$monthly_cost/month if it was running"
        TERMINATED_COUNT=$((TERMINATED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    fi

    log_info "Terminating instance: $instance_id..."
    if aws ec2 terminate-instances --region "$region" --instance-ids "$instance_id" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "Terminated instance: $instance_id - potential savings: \$$monthly_cost/month if it was to be restarted"
        TERMINATED_COUNT=$((TERMINATED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + $monthly_cost" | bc)
        return 0
    else
        log_error "Failed to terminate instance: $instance_id"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        return 1
    fi
}

show_usage() {
    cat << EOF
Delete Stopped EC2 Instances - High Savings Script

PURPOSE:
  Terminate EC2 instances that have been stopped for a long time.
  Creates AMI backups before termination for recovery.

  IMPORTANT: Stopped instances still incur EBS storage costs!
             Terminating them saves both compute AND storage costs.

USAGE:
  $0 --csv FILE [OPTIONS]

OPTIONS:
  --csv FILE                    Path to 01_ec2_instances.csv from audit
  --profile PROFILE             AWS profile to use (default: $AWS_PROFILE)
  --min-stopped-days DAYS       Only terminate instances stopped for X days (default: $MIN_STOPPED_DAYS)
  --protect-tags TAGS           Comma-separated tags to protect (e.g., "Environment=prod,DoNotDelete=true")

  EXECUTION MODES:
  --dry-run                     Preview terminations without executing (DEFAULT)
  --interactive                 Confirm each termination
  --execute                     Execute terminations automatically

  SAFETY OPTIONS:
  --create-ami                  Create AMI backup before termination (DEFAULT: enabled)
  --no-ami                      Skip AMI creation (NOT RECOMMENDED)
  --help                        Show this help

EXAMPLES:
  # Preview what would be terminated (safe)
  $0 --csv 01_ec2_instances.csv --dry-run

  # Terminate instances stopped for 180+ days (interactive)
  $0 --csv 01_ec2_instances.csv --min-stopped-days 180 --interactive

  # Automated termination with AMI backups
  $0 --csv 01_ec2_instances.csv --execute --create-ami

  # Protect production instances
  $0 --csv 01_ec2_instances.csv --protect-tags "Environment=production" --execute

SAFETY:
  - Only terminates instances in "stopped" state
  - Creates AMI backups before termination (can be restored)
  - Respects tag-based protection
  - Age verification (default: 90 days)
  - Interactive mode available
  - Full logging and audit trail

COST SAVINGS (Per Instance When Running):
  - t2/t3.micro:  ~\$8-10/month
  - t2/t3.small:  ~\$15-20/month
  - t2/t3.medium: ~\$30-35/month
  - m5.large:     ~\$70/month
  - m5.xlarge:    ~\$140/month

  PLUS: EBS storage savings (volumes are deleted on termination)

IMPORTANT NOTES:
  - Stopped instances still cost money (EBS volumes)
  - Termination deletes instances permanently
  - EBS volumes deleted per DeleteOnTermination setting
  - AMI backups allow full recovery
  - Consider starting instances instead of terminating if temporary

RECOVERY:
  If you need to restore an instance:
  1. Find the AMI in EC2 Console > AMIs
  2. Filter by tag "AutoBackup=true" or "OriginalInstance"
  3. Launch new instance from AMI
  4. Reconfigure as needed (IP, security groups, etc.)

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --csv) CSV_FILE="$2"; shift 2 ;;
        --profile) AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
        --min-stopped-days) MIN_STOPPED_DAYS="$2"; shift 2 ;;
        --protect-tags) PROTECT_TAGS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --interactive) INTERACTIVE=true; DRY_RUN=false; shift ;;
        --execute) DRY_RUN=false; shift ;;
        --create-ami) CREATE_AMI=true; shift ;;
        --no-ami) CREATE_AMI=false; shift ;;
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
echo -e "${BLUE}Delete Stopped EC2 Instances - High Savings Script${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "AWS Profile: $AWS_PROFILE"
log_info "CSV File: $CSV_FILE"
log_info "Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "EXECUTE")"
log_info "Create AMI Backup: $CREATE_AMI"
log_info "Min Stopped Days: $MIN_STOPPED_DAYS"
log_info "Protected Tags: ${PROTECT_TAGS:-none}"
log_info "Log File: $LOG_FILE"
if [ "$CREATE_AMI" = true ]; then
    log_info "AMI Log: $AMI_LOG"
fi
echo ""

# Warning for no-AMI mode
if [ "$CREATE_AMI" = false ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: AMI backup creation is DISABLED!${NC}"
    echo -e "${RED}Terminated instances cannot be easily recovered without AMIs!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Are you SURE you want to proceed without AMI backups? Type 'YES' to confirm: " -r confirm
    if [ "$confirm" != "YES" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""
fi

# Warning for execute mode
if [ "$DRY_RUN" = false ] && [ "$INTERACTIVE" = false ]; then
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}WARNING: INSTANCES WILL BE PERMANENTLY TERMINATED!${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Are you ABSOLUTELY SURE? Type 'TERMINATE' to confirm: " -r confirm
    if [ "$confirm" != "TERMINATE" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
    echo ""
fi

# Process CSV
line_number=0
while IFS=',' read -r region instance_id name state instance_type launch_time days_old avg_cpu platform private_ip public_ip tags recommendation cost; do
    line_number=$((line_number + 1))

    # Skip header
    if [ $line_number -eq 1 ]; then
        continue
    fi

    # Only process DELETE recommendations for stopped instances
    if [[ ! "$recommendation" =~ DELETE ]]; then
        continue
    fi

    # Clean up quoted fields
    tags=$(echo "$tags" | tr -d '"')

    # Terminate instance
    terminate_instance "$region" "$instance_id" "$name" "$state" "$instance_type" "$days_old" "$tags"

done < "$CSV_FILE"

# Summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Total instances processed: $TOTAL_INSTANCES"
echo -e "Terminated:                ${GREEN}$TERMINATED_COUNT${NC}"
echo -e "AMIs created:              ${GREEN}$AMI_COUNT${NC}"
echo -e "Skipped:                   ${YELLOW}$SKIPPED_COUNT${NC}"
echo -e "Protected:                 ${YELLOW}$PROTECTED_COUNT${NC}"
echo -e "Failed:                    ${RED}$FAILED_COUNT${NC}"
echo ""
echo -e "Potential monthly savings: ${GREEN}\$$TOTAL_SAVINGS${NC} (if instances were running)"
echo -e "Potential annual savings:  ${GREEN}\$$(echo "$TOTAL_SAVINGS * 12" | bc)${NC}"
echo -e ""
echo -e "${YELLOW}NOTE: Savings shown assume instances would be restarted.${NC}"
echo -e "${YELLOW}      Also saves EBS storage costs from attached volumes.${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY-RUN. No instances were actually terminated.${NC}"
    echo -e "${CYAN}Run with --execute to perform the terminations.${NC}"
    echo ""
fi

log_info "Logs saved:"
log_info "  - Termination log: $LOG_FILE"
if [ "$CREATE_AMI" = true ]; then
    log_info "  - AMI manifest: $AMI_LOG"
    echo ""
    echo -e "${GREEN}AMIs can be used to restore instances if needed.${NC}"
    echo -e "${GREEN}Find them in EC2 Console > AMIs, filter by 'AutoBackup=true'${NC}"
fi
echo ""
