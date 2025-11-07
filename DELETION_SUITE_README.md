# AWS Resource Cleanup Deletion Suite

## 🎯 Overview

A comprehensive, fault-proof deletion toolkit for safely removing AWS resources identified by the audit scripts.

## ⚠️ CRITICAL SAFETY NOTICE

**THESE SCRIPTS DELETE AWS RESOURCES PERMANENTLY**

- Always start with `--dry-run` mode
- Review all logs before actual deletion
- Ensure you have proper backups
- Test in non-production environments first
- Understand what you're deleting

## 📦 Suite Components

### 1. Main Orchestrator
- `aws_cleanup_delete.sh` - Master deletion script (reads CSV files)

### 2. Resource-Specific Scripts
- `delete_stopped_ec2.sh` - Terminate stopped EC2 instances
- `delete_unattached_ebs.sh` - Remove unattached EBS volumes
- `delete_old_snapshots.sh` - Clean up old snapshots
- `release_unused_eips.sh` - Release unassociated Elastic IPs
- `delete_idle_rds.sh` - Remove idle RDS instances
- `delete_idle_lambda.sh` - Clean up unused Lambda functions
- `delete_idle_loadbalancers.sh` - Remove idle load balancers
- `delete_idle_natgateways.sh` - Remove idle NAT gateways

### 3. Interactive Tools
- `aws_cleanup_wizard.sh` - Interactive wizard for guided cleanup

### 4. Safety & Recovery
- `aws_cleanup_snapshot.sh` - Create backups before deletion
- `aws_cleanup_undo.sh` - Rollback/restore deleted resources
- `aws_cleanup_validate.sh` - Pre-deletion validation

### 5. Utilities
- `aws_cleanup_logs.sh` - View deletion logs and audit trail
- `aws_cleanup_cost_calculator.sh` - Calculate savings

## 🛡️ Safety Features

### Multi-Layer Protection

#### 1. Dry-Run Mode (Default)
```bash
# Preview what would be deleted (NO actual deletion)
./aws_cleanup_delete.sh --csv 01_ec2_instances.csv --dry-run
```

#### 2. Interactive Confirmation
```bash
# Confirm each resource before deletion
./aws_cleanup_delete.sh --csv 01_ec2_instances.csv --interactive
```

#### 3. Tag-Based Protection
```bash
# Never delete resources with these tags
./aws_cleanup_delete.sh --protect-tags "Environment=production,DoNotDelete=true"
```

#### 4. Automatic Backups
```bash
# Create snapshots before deletion
./aws_cleanup_delete.sh --snapshot-before-delete
```

#### 5. Age Verification
```bash
# Only delete resources older than X days
./aws_cleanup_delete.sh --min-age-days 90
```

#### 6. Cost Limits
```bash
# Stop if estimated monthly savings exceed limit
./aws_cleanup_delete.sh --max-cost 1000
```

#### 7. Whitelist/Blacklist
```bash
# Protect specific resources by ID
./aws_cleanup_delete.sh --whitelist whitelist.txt

# Or only delete specific resources
./aws_cleanup_delete.sh --only-delete these-instances.txt
```

#### 8. Rollback Capability
```bash
# Undo recent deletions (restore from snapshots)
./aws_cleanup_undo.sh --restore-session 20251107-143022
```

## 📋 Quick Start Guide

### Step 1: Run the Audit
```bash
./aws_resource_cleanup_audit.sh production
```

### Step 2: Review Results
```bash
cd aws-cleanup-audit-production-all-regions-20251107-143022/
cat 00_SUMMARY_REPORT.txt
```

### Step 3: Use the Wizard (Recommended for First Time)
```bash
./aws_cleanup_wizard.sh --audit-dir aws-cleanup-audit-production-all-regions-20251107-143022/
```

### Step 4: Or Use Specific Scripts

#### Delete Unattached Elastic IPs (Quickest Wins)
```bash
# Dry run first
./release_unused_eips.sh \
    --csv aws-cleanup-audit-*/04_elastic_ips.csv \
    --dry-run

# Review output, then execute
./release_unused_eips.sh \
    --csv aws-cleanup-audit-*/04_elastic_ips.csv \
    --interactive
```

#### Delete Stopped EC2 Instances
```bash
./delete_stopped_ec2.sh \
    --csv aws-cleanup-audit-*/01_ec2_instances.csv \
    --min-stopped-days 90 \
    --snapshot-before-delete \
    --dry-run
```

#### Delete Unattached EBS Volumes
```bash
./delete_unattached_ebs.sh \
    --csv aws-cleanup-audit-*/02_ebs_volumes.csv \
    --min-unattached-days 60 \
    --snapshot-before-delete \
    --dry-run
```

#### Delete Old Snapshots
```bash
./delete_old_snapshots.sh \
    --csv aws-cleanup-audit-*/03_ebs_snapshots.csv \
    --min-age-days 730 \
    --keep-tagged \
    --dry-run
```

## 🔧 Advanced Usage

### Batch Deletion with Safety Limits
```bash
./aws_cleanup_delete.sh \
    --csv-dir aws-cleanup-audit-production-all-regions-20251107-143022/ \
    --recommendation DELETE \
    --max-cost 5000 \
    --max-resources-per-run 50 \
    --snapshot-before-delete \
    --protect-tags "Environment=production,Critical=true" \
    --log-file deletion-log-$(date +%Y%m%d).json \
    --dry-run
```

### Phased Approach (Recommended)
```bash
# Phase 1: Quick wins (low risk)
./release_unused_eips.sh --csv 04_elastic_ips.csv --execute
./delete_old_snapshots.sh --csv 03_ebs_snapshots.csv --min-age-days 730 --execute

# Phase 2: Medium risk (with backups)
./delete_unattached_ebs.sh --csv 02_ebs_volumes.csv --snapshot-first --execute

# Phase 3: Higher risk (stopped instances)
./delete_stopped_ec2.sh --csv 01_ec2_instances.csv --min-stopped-days 180 --execute

# Phase 4: Review before deleting running resources
./delete_idle_rds.sh --csv 06_rds_instances.csv --interactive
```

## 📊 Logging & Audit Trail

Every deletion operation creates detailed logs:

### Log Files
```
deletion-logs/
├── 20251107-143022-session.log          # Human-readable log
├── 20251107-143022-session.json         # Machine-readable log
├── 20251107-143022-snapshots.json       # Backup manifest
└── 20251107-143022-deleted-resources.csv # Deleted resources list
```

### Log Contents
- Timestamp of each operation
- Resource ID and details
- Deletion success/failure
- Snapshot IDs (for rollback)
- Estimated cost savings
- User who executed the deletion
- AWS account and region

### View Logs
```bash
# View recent deletions
./aws_cleanup_logs.sh --recent 10

# Search logs
./aws_cleanup_logs.sh --search "i-1234567890abcdef0"

# Calculate total savings
./aws_cleanup_logs.sh --calculate-savings
```

## 🔄 Rollback & Recovery

### Automatic Snapshot Creation
When `--snapshot-before-delete` is enabled:
- EBS volumes → EBS snapshots
- EC2 instances → AMI + EBS snapshots
- RDS instances → RDS snapshots
- All snapshots tagged with deletion session ID

### Restore Process
```bash
# List available restore points
./aws_cleanup_undo.sh --list-sessions

# Restore entire session
./aws_cleanup_undo.sh --restore-session 20251107-143022

# Restore specific resource
./aws_cleanup_undo.sh --restore-resource vol-1234567890abcdef0

# Restore by time window
./aws_cleanup_undo.sh --restore-after "2025-11-07 09:00" --restore-before "2025-11-07 17:00"
```

## 🎯 Recommended Deletion Order (Safest to Riskiest)

### Priority 1: Zero-Risk Deletions
1. **Unassociated Elastic IPs** - Immediate cost savings, zero impact
2. **Very Old Snapshots (2+ years)** - Low risk, free up storage
3. **Idle NAT Gateways** - High cost, easy to recreate

### Priority 2: Low-Risk Deletions
4. **Long-term Unattached EBS Volumes (90+ days)** - Create snapshot first
5. **Idle Classic Load Balancers** - Easy to recreate

### Priority 3: Medium-Risk Deletions
6. **Long-term Stopped EC2 Instances (180+ days)** - Create AMI first
7. **Idle Application/Network Load Balancers**
8. **Unused Lambda Functions (6+ months idle)**

### Priority 4: High-Risk Deletions (Careful Review Required)
9. **Idle RDS Instances** - Always snapshot first, verify no connections
10. **Recently Stopped EC2 (90-180 days)** - May be seasonal/temporary

## ⚙️ Configuration Files

### Protection Configuration (.aws-cleanup-protect.yaml)
```yaml
# Resources that should never be deleted
protected_tags:
  - Environment: production
  - DoNotDelete: true
  - Backup: required

protected_resource_ids:
  - i-prod-web-server-001
  - vol-prod-data-storage
  - db-prod-main-database

protected_name_patterns:
  - "^prod-.*"
  - ".*-production-.*"
  - "^critical-.*"

# Cost limits
max_monthly_savings: 10000
max_resources_per_run: 100

# Age requirements
min_stopped_days: 90
min_unattached_days: 60
min_snapshot_age_days: 730
```

### Deletion Policy (.aws-cleanup-policy.yaml)
```yaml
# Auto-delete criteria (used by wizard)
auto_delete_if:
  elastic_ips:
    - unassociated: true
      min_age_days: 1

  ebs_snapshots:
    - age_days: ">730"
      tags_missing: ["Keep", "Retention"]

  ebs_volumes:
    - state: available
      min_unattached_days: 90
      size_gb: "<100"

  ec2_instances:
    - state: stopped
      min_stopped_days: 180
      tag_missing: "DoNotDelete"
```

## 🧪 Testing & Validation

### Pre-Deletion Validation
```bash
# Validate CSV files and deletion plan
./aws_cleanup_validate.sh \
    --csv-dir aws-cleanup-audit-production-all-regions-20251107-143022/ \
    --check-dependencies \
    --check-tags \
    --check-policies
```

### Test in Non-Production First
```bash
# Run against dev/test account first
./aws_cleanup_delete.sh \
    --profile dev-account \
    --csv-dir aws-cleanup-audit-dev-* \
    --execute
```

### Verify Deletions
```bash
# Check if resources are actually deleted
./aws_cleanup_validate.sh \
    --verify-deletion \
    --session 20251107-143022
```

## 📈 Cost Tracking

### Calculate Potential Savings
```bash
./aws_cleanup_cost_calculator.sh \
    --csv-dir aws-cleanup-audit-production-all-regions-20251107-143022/ \
    --recommendation DELETE

# Output:
# Estimated Monthly Savings: $1,234.56
# Estimated Annual Savings: $14,814.72
# One-time Cleanup Cost: $0.00 (snapshots only)
```

### Track Actual Savings
```bash
# Compare AWS bills before/after
./aws_cleanup_cost_calculator.sh \
    --compare-bills \
    --before-date 2025-10-01 \
    --after-date 2025-12-01
```

## 🚨 Error Handling

### What Happens if Something Goes Wrong?

1. **API Failures**: Automatic retry with exponential backoff
2. **Permission Denied**: Skip resource, log error, continue
3. **Resource in Use**: Skip, log warning, continue
4. **Snapshot Failure**: Abort deletion of that resource
5. **Network Issues**: Pause, retry, log

### Emergency Stop
```bash
# Stop all running deletion jobs
./aws_cleanup_delete.sh --emergency-stop

# Or use Ctrl+C (gracefully stops, preserves logs)
```

## 📚 Additional Resources

- [AWS Backup Best Practices](https://docs.aws.amazon.com/aws-backup/)
- [AWS Cost Optimization](https://aws.amazon.com/pricing/cost-optimization/)
- [Deletion Protection Tags](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Using_Tags.html)

## 🤝 Support & Safety

### Before Running in Production:
1. ✅ Test in dev/test environment
2. ✅ Review all CSV files manually
3. ✅ Configure protection tags
4. ✅ Set up AWS Config for tracking
5. ✅ Enable CloudTrail logging
6. ✅ Have incident response plan
7. ✅ Schedule during maintenance window
8. ✅ Have team available for verification

### Need Help?
- Review logs in `deletion-logs/`
- Check AWS CloudTrail for API activity
- Verify backups were created
- Use `--dry-run` to preview changes

## 📄 License & Disclaimer

**USE AT YOUR OWN RISK**

These scripts permanently delete AWS resources. While they include multiple safety mechanisms, you are responsible for:
- Verifying what will be deleted
- Having proper backups
- Testing in non-production first
- Understanding the impact
- Complying with your organization's policies

Always start with `--dry-run` and gradually increase automation as you gain confidence.

---

**Version**: 1.0.0
**Last Updated**: 2025-11-07
**Author**: AWS Resource Cleanup Audit Suite
