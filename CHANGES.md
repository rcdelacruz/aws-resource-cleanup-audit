# AWS Resource Cleanup Audit Script - Recent Updates

## Summary of Changes

### 1. Realistic Organizational Thresholds ✓

Changed from aggressive defaults to production-friendly thresholds:

| Resource Type | Old Threshold | New Threshold | Rationale |
|---------------|---------------|---------------|-----------|
| **Stopped EC2** | 30 days | **90 days** | Organizations often stop instances for extended periods (dev/test environments) |
| **EC2 Low CPU** | <5% | **<10%** | Reduced false positives; 5% was too aggressive for bursty workloads |
| **Unattached EBS** | 30 days | **60 days** | Give teams time to reattach volumes after incidents/migrations |
| **Old Snapshots (Review)** | 90 days | **180 days (6 months)** | More reasonable retention for compliance |
| **Old Snapshots (Delete)** | 365 days (1 year) | **730 days (2 years)** | Conservative approach for disaster recovery |
| **Idle RDS/Lambda/LB** | N/A | **60 days** | Consistent threshold for zero-activity resources |
| **Empty S3 Buckets** | 180 days | **180 days** | Kept the same (was already reasonable) |

### 2. Improved Folder Naming ✓

**Old Format:**
```
aws_cleanup_report_20250115_143022
```

**New Format:**
```
aws-cleanup-audit-{PROFILE}-{REGIONS}-{TIMESTAMP}
```

**Examples:**
- `aws-cleanup-audit-default-all-regions-20250115-143022`
- `aws-cleanup-audit-production-us-east-1-20250115-143022`
- `aws-cleanup-audit-staging-us-east-1-us-west-2-20250115-143022`
- `aws-cleanup-audit-dev-3-regions-20250115-143022` (when >3 regions specified)

**Benefits:**
- Immediately see which AWS profile was used
- Understand the scope (specific regions or all regions)
- Better organization when running audits across multiple accounts
- Easier to sort and archive reports

### 3. Enhanced Recommendations

All recommendations now include the threshold value for transparency:

**Before:**
```
DELETE - Stopped for 120 days
REVIEW - Low CPU usage (8%)
```

**After:**
```
DELETE - Stopped for 120 days (>90d threshold)
REVIEW - Low CPU usage (8% avg, <10% threshold)
```

### 4. Updated Documentation

- Added threshold information to script header
- Enhanced summary report with "THRESHOLDS USED IN THIS AUDIT" section
- Added notes about why resources cost money even when idle
- More detailed quick wins section with specific savings estimates

## How to Customize Thresholds

Edit these variables at the top of the script (lines 54-60):

```bash
STOPPED_INSTANCE_DAYS=90    # Flag EC2 instances stopped for this many days
UNATTACHED_VOLUME_DAYS=60   # Flag unattached EBS volumes older than this
SNAPSHOT_OLD_DAYS=180       # Review snapshots older than 6 months
SNAPSHOT_DELETE_DAYS=730    # Delete snapshots older than 2 years
CPU_THRESHOLD=10            # CPU percentage threshold for idle EC2
IDLE_DAYS=60                # Days of zero activity before flagging resources
EMPTY_BUCKET_DAYS=180       # Days before flagging empty/nearly-empty buckets
```

## Previous Improvements (from earlier fix)

1. ✓ macOS and Linux compatibility
2. ✓ Parallel region processing (5 concurrent by default)
3. ✓ API retry logic with exponential backoff
4. ✓ CloudWatch metrics for S3 (much faster)
5. ✓ AWS credentials validation
6. ✓ Automatic cleanup of temporary files
7. ✓ Dependency checking (aws-cli, bc, awk)

## Usage Examples

```bash
# Audit all regions with default profile
./aws_resource_cleanup_audit.sh

# Audit specific profile and all regions
./aws_resource_cleanup_audit.sh production

# Audit specific profile and specific regions
./aws_resource_cleanup_audit.sh production "us-east-1,us-west-2"

# Audit with custom profile and single region
./aws_resource_cleanup_audit.sh dev-account "eu-west-1"
```

## Output Example

```
aws-cleanup-audit-production-us-east-1-20250115-143022/
├── 00_SUMMARY_REPORT.txt
├── 01_ec2_instances.csv
├── 02_ebs_volumes.csv
├── 03_ebs_snapshots.csv
├── 04_elastic_ips.csv
├── 05_load_balancers.csv
├── 06_rds_instances.csv
├── 07_s3_buckets.csv (DEPRECATED - now use aws_s3_audit.sh)
├── 08_lambda_functions.csv
└── 09_nat_gateways.csv
```

---

## Bug Fixes and Code Quality Improvements - 2025-11-05

### Critical Bug Fixes

#### 1. Fixed Excessive Escaping in Lambda Section (Lines 779-816)
**Problem:**
- Used double backslashes (`\\`) in AWS CLI command continuation
- Used double backslashes in IFS declaration (`IFS=$'\\t'`)
- Used excessive escaping in tr/sed commands and CSV output

**Fix:**
- Changed AWS CLI backslashes from `\\` to `\` (lines 779-782)
- Changed IFS from `IFS=$'\\t'` to `IFS=$'\t'` (line 788)
- Changed tag cleaning from `tr '\\n'` to `tr '\n'` (line 801)
- Changed CSV output from `\\"$clean_tags\\"` to `"$clean_tags"` (line 816)
- Changed cost from `"<\\$1"` to `"<\$1"` (line 804)

#### 2. Fixed Excessive Escaping in NAT Gateway Section (Lines 834-867)
**Problem:**
- Same escaping issues as Lambda section

**Fix:**
- Changed AWS CLI backslashes from `\\` to `\` (lines 834-837)
- Changed IFS from `IFS=$'\\t'` to `IFS=$'\t'` (line 843)
- Changed tag cleaning from `tr '\\n'` to `tr '\n'` (line 854)
- Changed CSV output from `\\"$clean_tags\\"` to `"$clean_tags"` (line 867)
- Changed cost from `"\\$32.40"` to `"\$32.40"` (line 857)

#### 3. Fixed S3 Section Escaping and Separated to Dedicated Script
**Problem:**
- Excessive backslash escaping in S3 analysis section
- S3 being global made the main script run much longer
- S3 analysis could take 10-30 minutes for large accounts

**Fix:**
- Commented out S3 section in main script (lines 675-766)
- Created separate `aws_s3_audit.sh` script with proper escaping
- Fixed all tag cleaning and CSV output escaping in new script
- Added clear note directing users to use dedicated S3 script

**To Re-enable S3 in Main Script:**
- Remove the here-doc comment markers around lines 688-766

### Input Validation Improvements

#### 4. Added Input Validation for bc Comparisons
**Problem:**
- `bc` commands would fail if variables contained "N/A", empty strings, or non-numeric values
- No error handling for bc failures

**Locations Fixed:**
- Line 305: EC2 CPU threshold comparison
- Lines 560, 562: Load Balancer traffic/connection comparisons
- Line 593: Classic Load Balancer traffic comparison
- Line 660: RDS connection comparison
- Line 752: S3 size comparison (in commented section)
- Lines 808, 810: Lambda invocation comparisons
- Line 861: NAT Gateway traffic comparison

**Fix Pattern:**
```bash
# Before:
[ "$(echo "$avg_cpu < $CPU_THRESHOLD" | bc -l)" = "1" ]

# After:
[ -n "$avg_cpu" ] && [ "$(echo "$avg_cpu < $CPU_THRESHOLD" | bc -l 2>/dev/null || echo 0)" = "1" ]
```

Changes:
- Added `-n` check to ensure variable is not empty
- Added `2>/dev/null` to suppress bc error messages
- Added `|| echo 0` fallback to return safe value on failure

#### 5. Added days_old Validation
**Problem:**
- Some comparisons used `$days_old` without checking if it's "N/A"

**Locations Fixed:**
- Line 656: RDS stopped instance check
- Line 660: RDS idle connections check
- Line 748: S3 empty bucket check (in commented section)
- Line 752: S3 nearly empty check (in commented section)
- Line 808: Lambda idle check

**Fix:**
- Added `[ "$days_old" != "N/A" ]` before numeric comparisons

### Architectural Changes

#### 6. S3 Section Separation
**Reason:**
- S3 is a global service (not region-specific)
- S3 analysis can take 10-30 minutes for accounts with many buckets
- Users may want to audit regional resources separately from S3

**Changes:**
- Commented out S3 section (lines 675-766) using here-doc syntax
- Added clear messaging that S3 is skipped
- Created dedicated `aws_s3_audit.sh` script
- S3 script has same functionality but focused on S3 only
- Easier to run S3 audits independently

### Files Modified

1. **aws_resource_cleanup_audit.sh**
   - Fixed Lambda section escaping
   - Fixed NAT Gateway section escaping
   - Added input validation for all bc comparisons
   - Added days_old validation
   - Commented out S3 section with instructions

2. **aws_s3_audit.sh** (NEW)
   - Dedicated S3 bucket analysis script
   - Proper escaping throughout
   - Input validation for bc comparisons
   - Comprehensive S3-specific documentation
   - Best practices and cost optimization tips

3. **CHANGES.md** (THIS FILE)
   - Updated to document bug fixes

### Testing Recommendations

Before running in production:

1. **Syntax Check:**
   ```bash
   bash -n aws_resource_cleanup_audit.sh
   bash -n aws_s3_audit.sh
   ```

2. **Test with Limited Scope:**
   ```bash
   # Test single region
   ./aws_resource_cleanup_audit.sh your-profile us-east-1

   # Test S3 separately
   ./aws_s3_audit.sh your-profile
   ```

3. **Verify CSV Output:**
   - Check that tags are properly quoted
   - Verify no extra backslashes in output
   - Confirm recommendations are generated correctly

### Backward Compatibility

**Breaking Changes:**
- S3 analysis no longer runs by default in main script
- Users must run `aws_s3_audit.sh` separately for S3 analysis

**Non-Breaking Changes:**
- All other functionality remains the same
- Output format unchanged (except fixed escaping)
- Command-line arguments unchanged

### Performance Impact

**Main Script:**
- ✅ Faster execution (no S3 analysis delay)
- ✅ Regional resources analyzed in parallel as before

**S3 Script:**
- Same performance as before
- Uses CloudWatch metrics when available (fast)
- Falls back to listing objects when needed (slow)

### Summary of Bug Fixes

**Total Issues Fixed:** 6 major issues
- 3 critical escaping bugs
- 2 input validation gaps
- 1 architectural improvement

**Files Changed:** 1 modified, 1 created
**Lines Changed:** ~100+ fixes across multiple functions

All critical bugs that would cause script failures have been resolved. The script should now run reliably across different AWS environments and handle edge cases gracefully.
