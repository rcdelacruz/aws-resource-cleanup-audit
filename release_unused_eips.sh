#!/bin/bash

################################################################################
# Release Unused Elastic IPs - Quick Win Script
#
# Purpose: Release unassociated Elastic IPs to save costs
#
# Savings: $3.60/month per EIP ($43.20/year)
# Risk Level: LOW (unassociated IPs have no dependencies)
# Recovery: None needed (can allocate new IPs anytime)
#
# Usage:
#   ./release_unused_eips.sh --csv 04_elastic_ips.csv --dry-run
#   ./release_unused_eips.sh --csv 04_elastic_ips.csv --execute
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
LOG_FILE="eip-release-$(date +%Y%m%d-%H%M%S).log"

# Counters
TOTAL_EIPS=0
RELEASED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
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

show_usage() {
    cat << EOF
Release Unused Elastic IPs - Quick Win Script

PURPOSE:
  Release unassociated Elastic IPs to save \$3.60/month per IP.
  This is one of the safest and quickest cost optimizations.

USAGE:
  $0 --csv FILE [OPTIONS]

OPTIONS:
  --csv FILE           Path to 04_elastic_ips.csv from audit
  --profile PROFILE    AWS profile to use (default: $AWS_PROFILE)
  --dry-run            Preview releases without executing (DEFAULT)
  --interactive        Confirm each release
  --execute            Execute releases automatically
  --help               Show this help

EXAMPLES:
  # Preview what would be released (safe)
  $0 --csv 04_elastic_ips.csv --dry-run

  # Interactive mode
  $0 --csv 04_elastic_ips.csv --interactive

  # Automatic release
  $0 --csv 04_elastic_ips.csv --execute

SAFETY:
  - Only releases UNASSOCIATED Elastic IPs
  - Associated IPs are automatically skipped
  - No data loss risk (IPs can be re-allocated)
  - Immediate cost savings

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --csv) CSV_FILE="$2"; shift 2 ;;
        --profile) AWS_PROFILE="$2"; export AWS_PROFILE; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --interactive) INTERACTIVE=true; DRY_RUN=false; shift ;;
        --execute) DRY_RUN=false; shift ;;
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
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}Release Unused Elastic IPs - Quick Win Script${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
log_info "AWS Profile: $AWS_PROFILE"
log_info "CSV File: $CSV_FILE"
log_info "Mode: $([ "$DRY_RUN" = true ] && echo "DRY-RUN" || echo "EXECUTE")"
echo ""

# Process CSV
line_number=0
while IFS=',' read -r region allocation_id public_ip instance_id private_ip domain network_interface tags recommendation cost; do
    line_number=$((line_number + 1))

    # Skip header
    if [ $line_number -eq 1 ]; then
        continue
    fi

    TOTAL_EIPS=$((TOTAL_EIPS + 1))

    # Only process DELETE recommendations
    if [[ ! "$recommendation" =~ DELETE ]]; then
        log_warn "EIP $public_ip: Not marked for deletion, skipping"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Verify it's unassociated
    if [ "$instance_id" != "Unassociated" ] && [ -n "$instance_id" ]; then
        log_warn "EIP $public_ip: Still associated with $instance_id, skipping for safety"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Interactive confirmation
    if [ "$INTERACTIVE" = true ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Public IP:      ${CYAN}$public_ip${NC}"
        echo -e "Allocation ID:  ${CYAN}$allocation_id${NC}"
        echo -e "Region:         ${CYAN}$region${NC}"
        echo -e "Monthly Cost:   ${RED}\$3.60${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Release this EIP? (y/n/q): " -r response
        case "$response" in
            y|Y|yes|YES) ;;
            q|Q|quit|QUIT) log_info "User quit"; break ;;
            *) log_info "Skipped $public_ip"; SKIPPED_COUNT=$((SKIPPED_COUNT + 1)); continue ;;
        esac
    fi

    # Release EIP
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Would release EIP: $public_ip ($allocation_id) in $region - saves \$3.60/month"
        RELEASED_COUNT=$((RELEASED_COUNT + 1))
        TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + 3.60" | bc)
    else
        log_info "Releasing EIP: $public_ip in $region..."
        if aws ec2 release-address --region "$region" --allocation-id "$allocation_id" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Released EIP: $public_ip - saves \$3.60/month"
            RELEASED_COUNT=$((RELEASED_COUNT + 1))
            TOTAL_SAVINGS=$(echo "$TOTAL_SAVINGS + 3.60" | bc)
        else
            log_error "Failed to release EIP: $public_ip"
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    fi

done < "$CSV_FILE"

# Summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Total EIPs processed:     $TOTAL_EIPS"
echo -e "Released:                 ${GREEN}$RELEASED_COUNT${NC}"
echo -e "Skipped:                  ${YELLOW}$SKIPPED_COUNT${NC}"
echo -e "Failed:                   ${RED}$FAILED_COUNT${NC}"
echo -e ""
echo -e "Monthly savings:          ${GREEN}\$$TOTAL_SAVINGS${NC}"
echo -e "Annual savings:           ${GREEN}\$$(echo "$TOTAL_SAVINGS * 12" | bc)${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}This was a DRY-RUN. No EIPs were actually released.${NC}"
    echo -e "${CYAN}Run with --execute to perform the releases.${NC}"
    echo ""
fi

log_info "Log file: $LOG_FILE"
echo ""
