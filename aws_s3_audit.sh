#!/bin/bash

################################################################################
# AWS S3 Bucket Cleanup Audit Script
#
# Purpose: Generates comprehensive CSV report of S3 buckets with usage metrics
#          to identify candidates for cleanup
#
# Output: CSV file with detailed S3 bucket information and recommendations
#
# Usage: ./aws_s3_audit.sh [profile]
#        ./aws_s3_audit.sh default
#        ./aws_s3_audit.sh production
#        ./aws_s3_audit.sh  (uses default profile)
#
# Note: S3 is a global service - this script analyzes all buckets regardless
#       of region, but bucket locations are included in the output.
#
# Thresholds:
#   - Empty buckets: 180 days
#   - Nearly empty: < 0.1 GB for 180 days
#
# Features:
# - macOS and Linux compatible
# - Uses CloudWatch metrics when available (faster)
# - Falls back to listing objects when metrics unavailable
# - Analyzes versioning, encryption, and public access settings
# - Provides cost estimates and cleanup recommendations
################################################################################

set -e

# Check for required dependencies
check_dependencies() {
    local missing_deps=()

    command -v aws >/dev/null 2>&1 || missing_deps+=("aws-cli")
    command -v bc >/dev/null 2>&1 || missing_deps+=("bc")
    command -v awk >/dev/null 2>&1 || missing_deps+=("awk")

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}"
        echo "Please install missing dependencies and try again."
        exit 1
    fi
}

check_dependencies

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_PROFILE="${1:-default}"
EMPTY_BUCKET_DAYS=180       # Days before flagging empty/nearly-empty buckets

# Set AWS profile
export AWS_PROFILE

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AWS S3 Bucket Cleanup Audit Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Profile: ${GREEN}${AWS_PROFILE}${NC}"

# Function to get account ID
get_account_id() {
    aws sts get-caller-identity --query Account --output text
}

# Function to calculate days since date (macOS and Linux compatible)
days_since() {
    local date_str="$1"
    if [ -z "$date_str" ] || [ "$date_str" = "None" ] || [ "$date_str" = "null" ]; then
        echo "N/A"
        return
    fi

    local date_epoch
    local now_epoch=$(date +%s)

    # Try macOS date format first, then Linux
    if date -j -f "%Y-%m-%dT%H:%M:%S" "$date_str" +%s >/dev/null 2>&1; then
        # macOS
        date_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${date_str:0:19}" +%s 2>/dev/null || echo "0")
    elif date -d "$date_str" +%s >/dev/null 2>&1; then
        # Linux
        date_epoch=$(date -d "$date_str" +%s 2>/dev/null || echo "0")
    else
        echo "N/A"
        return
    fi

    local days=$(( (now_epoch - date_epoch) / 86400 ))
    echo "$days"
}

# Function to retry AWS CLI commands with exponential backoff
aws_retry() {
    local max_attempts=5
    local timeout=1
    local attempt=1
    local exitCode=0

    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        else
            exitCode=$?
        fi

        if [ $attempt -lt $max_attempts ]; then
            echo "  Attempt $attempt failed. Retrying in ${timeout}s..." >&2
            sleep $timeout
            timeout=$((timeout * 2))
        fi
        attempt=$((attempt + 1))
    done

    echo "  Command failed after $max_attempts attempts" >&2
    return $exitCode
}

# Function to get CloudWatch metric statistics (macOS and Linux compatible)
get_metric_stats() {
    local namespace="$1"
    local metric_name="$2"
    local dimensions="$3"
    local region="$4"
    local days="${5:-30}"

    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%S")
    local start_time

    # Calculate start time (macOS and Linux compatible)
    if date -j >/dev/null 2>&1; then
        # macOS
        start_time=$(date -u -v-${days}d +"%Y-%m-%dT%H:%M:%S")
    else
        # Linux
        start_time=$(date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%S")
    fi

    aws_retry aws cloudwatch get-metric-statistics \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --dimensions "$dimensions" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period 86400 \
        --statistics Average \
        --region "$region" \
        --query 'Datapoints[].Average' \
        --output text 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) printf "%.2f", sum/count; else print "0"}'
}

# Validate AWS credentials and access
echo -e "${YELLOW}Validating AWS credentials...${NC}"
if ! aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Unable to authenticate with AWS using profile '${AWS_PROFILE}'${NC}"
    echo -e "${RED}Please check your AWS credentials and profile configuration${NC}"
    exit 1
fi

echo -e "${YELLOW}Getting account information...${NC}"
ACCOUNT_ID=$(get_account_id)
if [ -z "$ACCOUNT_ID" ]; then
    echo -e "${RED}ERROR: Unable to retrieve AWS account ID${NC}"
    exit 1
fi
echo -e "Account ID: ${GREEN}${ACCOUNT_ID}${NC}"
echo ""

# Create output directory
OUTPUT_DIR="aws-s3-audit-${AWS_PROFILE}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT_DIR"

echo -e "Output Directory: ${GREEN}${OUTPUT_DIR}${NC}"
echo ""

################################################################################
# S3 BUCKETS ANALYSIS
################################################################################
echo -e "${BLUE}Analyzing S3 Buckets...${NC}"
echo -e "  ${YELLOW}Note: S3 is global, analyzing all buckets${NC}"

S3_FILE="$OUTPUT_DIR/s3_buckets.csv"
echo "BucketName,CreationDate,DaysSinceCreation,Region,NumberOfObjects,TotalSize(GB),Versioning,Encryption,PublicAccess,Tags,Recommendation,EstMonthlyCost" > "$S3_FILE"

buckets=$(aws s3api list-buckets --query 'Buckets[].[Name,CreationDate]' --output text 2>/dev/null || echo "")

if [ -n "$buckets" ]; then
    total_buckets=$(echo "$buckets" | wc -l)
    current=0

    while IFS=$'\t' read -r bucket_name creation_date; do
        [ -z "$bucket_name" ] && continue

        current=$((current + 1))
        echo -e "  Analyzing bucket ${current}/${total_buckets}: ${bucket_name}"

        days_old=$(days_since "$creation_date")

        # Get bucket region
        bucket_region=$(aws s3api get-bucket-location --bucket "$bucket_name" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
        [ "$bucket_region" = "None" ] && bucket_region="us-east-1"

        # Get bucket size and object count from CloudWatch (much faster than listing objects)
        # CloudWatch metrics are updated daily
        object_count=$(get_metric_stats "AWS/S3" "NumberOfObjects" "Name=BucketName,Value=$bucket_name Name=StorageType,Value=AllStorageTypes" "$bucket_region" 1)
        total_size_bytes=$(get_metric_stats "AWS/S3" "BucketSizeBytes" "Name=BucketName,Value=$bucket_name Name=StorageType,Value=StandardStorage" "$bucket_region" 1)

        # If CloudWatch metrics are not available, fall back to listing (with warning)
        if [ "$object_count" = "0" ] || [ "$object_count" = "N/A" ]; then
            echo -e "    ${YELLOW}Warning: CloudWatch metrics not available, using slower listing method${NC}"
            size_info=$(aws s3 ls s3://"$bucket_name" --recursive --summarize 2>/dev/null | tail -2)
            object_count=$(echo "$size_info" | grep "Total Objects:" | awk '{print $3}')
            total_size_bytes=$(echo "$size_info" | grep "Total Size:" | awk '{print $3}')
        fi

        object_count="${object_count:-0}"
        total_size_bytes="${total_size_bytes:-0}"
        size_gb=$(echo "scale=2; $total_size_bytes / 1073741824" | bc 2>/dev/null || echo "0")

        # Get versioning status
        versioning=$(aws s3api get-bucket-versioning --bucket "$bucket_name" --query 'Status' --output text 2>/dev/null || echo "Disabled")

        # Get encryption
        encryption=$(aws s3api get-bucket-encryption --bucket "$bucket_name" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>/dev/null || echo "None")

        # Get public access block
        public_access=$(aws s3api get-public-access-block --bucket "$bucket_name" --query 'PublicAccessBlockConfiguration.BlockPublicAcls' --output text 2>/dev/null || echo "Unknown")

        # Get tags
        tags=$(aws s3api get-bucket-tagging --bucket "$bucket_name" --query 'TagSet' --output text 2>/dev/null || echo "")
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')

        # Cost estimate
        cost="\$$(echo "scale=2; $size_gb * 0.023" | bc 2>/dev/null || echo "0")"  # Standard S3 pricing

        # Recommendation
        recommendation=""
        if [ "$object_count" -eq 0 ] && [ "$days_old" != "N/A" ] && [ "$days_old" -gt "$EMPTY_BUCKET_DAYS" ]; then
            recommendation="DELETE - Empty bucket for $days_old days (>${EMPTY_BUCKET_DAYS}d)"
        elif [ "$object_count" -eq 0 ]; then
            recommendation="REVIEW - Empty bucket (<${EMPTY_BUCKET_DAYS}d)"
        elif [ -n "$size_gb" ] && [ "$(echo "$size_gb < 0.1" | bc -l 2>/dev/null || echo 0)" = "1" ] && [ "$days_old" != "N/A" ] && [ "$days_old" -gt "$EMPTY_BUCKET_DAYS" ]; then
            recommendation="REVIEW - Nearly empty (<0.1GB) and old (>${EMPTY_BUCKET_DAYS}d)"
        else
            recommendation="KEEP"
        fi

        echo "$bucket_name,$creation_date,$days_old,$bucket_region,$object_count,$size_gb,$versioning,$encryption,$public_access,\"$clean_tags\",$recommendation,$cost" >> "$S3_FILE"
    done <<< "$buckets"
else
    echo -e "  ${YELLOW}No S3 buckets found${NC}"
fi

echo -e "${GREEN}  ✓ S3 analysis complete (${total_buckets:-0} buckets analyzed)${NC}"
echo ""

################################################################################
# GENERATE SUMMARY REPORT
################################################################################
echo -e "${BLUE}Generating Summary Report...${NC}"

SUMMARY_FILE="$OUTPUT_DIR/S3_SUMMARY_REPORT.txt"

cat > "$SUMMARY_FILE" << 'SUMMARY_EOF'
================================================================================
AWS S3 BUCKET CLEANUP AUDIT REPORT
================================================================================

Generated: $(date)
AWS Account: ${ACCOUNT_ID}
AWS Profile: ${AWS_PROFILE}

================================================================================
EXECUTIVE SUMMARY
================================================================================

This report contains a detailed CSV file for S3 buckets:
- s3_buckets.csv

================================================================================
KEY FINDINGS
================================================================================

SUMMARY_EOF

# Count recommendations by type
total_resources=$(tail -n +2 "$S3_FILE" | wc -l)
delete_count=$(tail -n +2 "$S3_FILE" | grep -c "DELETE" || echo "0")
review_count=$(tail -n +2 "$S3_FILE" | grep -c "REVIEW" || echo "0")

echo "Total S3 Buckets: $total_resources" >> "$SUMMARY_FILE"
echo "  Recommended for DELETE: $delete_count" >> "$SUMMARY_FILE"
echo "  Recommended for REVIEW: $review_count" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

cat >> "$SUMMARY_FILE" << 'SUMMARY_EOF2'

================================================================================
THRESHOLDS USED IN THIS AUDIT
================================================================================

- Empty S3 Buckets: ${EMPTY_BUCKET_DAYS} days
- Nearly Empty Buckets: < 0.1 GB for ${EMPTY_BUCKET_DAYS} days

These thresholds are conservative to minimize false positives in production
environments. Adjust in the script if your organization has different policies.

================================================================================
QUICK WINS (HIGH PRIORITY)
================================================================================

1. EMPTY S3 BUCKETS
   - Check: s3_buckets.csv
   - Look for: Recommendation = "DELETE - Empty bucket"
   - Action: Delete empty buckets (no data loss risk)
   - Savings: Minimal storage cost but reduces complexity

2. NEARLY EMPTY OLD BUCKETS
   - Check: s3_buckets.csv
   - Look for: Recommendation = "REVIEW - Nearly empty"
   - Action: Review contents and consider consolidation
   - Savings: Reduces management overhead

3. UNENCRYPTED BUCKETS
   - Check: s3_buckets.csv
   - Look for: Encryption = "None"
   - Action: Enable encryption for security compliance
   - Cost: Minimal to no additional cost

4. PUBLICLY ACCESSIBLE BUCKETS
   - Check: s3_buckets.csv
   - Look for: PublicAccess = "false" or "Unknown"
   - Action: Review and enable public access blocks if appropriate
   - Security: Prevents accidental data exposure

================================================================================
NEXT STEPS
================================================================================

1. Open s3_buckets.csv in a spreadsheet application
2. Sort by "Recommendation" column to prioritize actions
3. Start with "DELETE" recommendations (empty buckets)
4. Review "REVIEW" recommendations carefully
5. Check versioning settings - versioned buckets may have hidden data
6. Verify encryption and public access settings
7. Delete in stages and monitor for any issues
8. Consider lifecycle policies for automated cleanup

================================================================================
IMPORTANT NOTES
================================================================================

- All cost estimates are approximate
- CloudWatch metrics may take 24-48 hours to appear for new buckets
- Some metrics may show "N/A" if CloudWatch data is unavailable
- Empty buckets may still have versioned objects - check versioning
- Consider S3 Lifecycle policies for automated cleanup
- Cross-region replication may affect actual storage costs

================================================================================
S3 BEST PRACTICES
================================================================================

1. Enable versioning for important data buckets
2. Use lifecycle policies to automatically transition to cheaper storage
3. Enable encryption by default (SSE-S3 or SSE-KMS)
4. Block all public access unless explicitly needed
5. Use bucket policies and IAM for access control
6. Enable logging for compliance and auditing
7. Tag buckets with: Environment, Owner, Project, CostCenter
8. Set up CloudWatch alarms for unexpected storage growth

================================================================================
COST OPTIMIZATION TIPS
================================================================================

1. Use S3 Intelligent-Tiering for unpredictable access patterns
2. Transition old data to S3 Glacier or Deep Archive
3. Delete incomplete multipart uploads (use lifecycle policy)
4. Enable S3 Storage Lens for comprehensive analytics
5. Review and delete old versions if versioning is enabled
6. Use S3 Inventory to identify large objects
7. Consider requester pays for buckets with external access

================================================================================
END OF REPORT
================================================================================
SUMMARY_EOF2

echo -e "${GREEN}  ✓ Summary report generated${NC}"
echo ""

################################################################################
# FINAL OUTPUT
################################################################################

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}S3 AUDIT COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Report location: ${BLUE}${OUTPUT_DIR}${NC}"
echo ""
echo -e "Generated files:"
ls -lh "$OUTPUT_DIR"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Review ${BLUE}S3_SUMMARY_REPORT.txt${NC} for overview"
echo -e "2. Open ${BLUE}s3_buckets.csv${NC} in spreadsheet application"
echo -e "3. Sort by 'Recommendation' column"
echo -e "4. Start with 'DELETE' recommendations for empty buckets"
echo -e "5. Verify buckets don't have versioned objects before deletion"
echo ""
echo -e "${RED}WARNING: Always verify bucket contents before deletion!${NC}"
echo ""
