# AWS Resource Cleanup Audit Script

A comprehensive bash script that analyzes AWS resources across all regions and generates detailed CSV reports to identify unused, idle, or underutilized resources for potential cleanup.

## 🎯 Purpose

This script helps you:
- **Identify unused AWS resources** costing you money
- **Generate detailed reports** with usage metrics and cost estimates
- **Make informed decisions** before deleting resources
- **Optimize AWS costs** by finding low-hanging fruit

## 📊 What It Analyzes

The script examines 9 major AWS resource types:

| # | Resource Type | Key Metrics | Potential Savings |
|---|---------------|-------------|-------------------|
| 1 | **EC2 Instances** | CPU usage, state, age | High |
| 2 | **EBS Volumes** | Attachment status, age | Medium-High |
| 3 | **EBS Snapshots** | Age, size | Medium |
| 4 | **Elastic IPs** | Association status | $3.60/IP/month |
| 5 | **Load Balancers** | Traffic, connections | $16-22/LB/month |
| 6 | **RDS Instances** | Connections, IOPS | High |
| 7 | **S3 Buckets** | Size, object count | Varies |
| 8 | **Lambda Functions** | Invocations | Low |
| 9 | **NAT Gateways** | Traffic | $32/NAT/month |

## ✨ Key Features

- ✅ **100% Read-Only** - No resources are modified or deleted
- ✅ **Multi-Region Support** - Scans all AWS regions or specific ones
- ✅ **CloudWatch Integration** - 30-day usage metrics for accurate analysis
- ✅ **Cost Estimates** - Approximate monthly costs per resource
- ✅ **Clear Recommendations** - Each resource tagged as DELETE/REVIEW/KEEP
- ✅ **CSV Output** - Easy to analyze in Excel/Google Sheets
- ✅ **Summary Report** - Executive summary with quick wins
- ✅ **Progress Indicators** - Real-time feedback during scan

## 🚀 Quick Start

### Prerequisites

- AWS CLI installed and configured
- `jq` installed (optional, for JSON parsing)
- `bc` installed (for calculations)
- AWS credentials with read permissions

### Installation

```bash
# Clone the repository
git clone https://github.com/rcdelacruz/aws-resource-cleanup-audit.git
cd aws-resource-cleanup-audit

# Make script executable
chmod +x aws_resource_cleanup_audit.sh
```

### Usage

```bash
# Scan all regions with default profile
./aws_resource_cleanup_audit.sh

# Scan specific regions with custom profile
./aws_resource_cleanup_audit.sh my-profile "us-east-1,us-west-2,eu-west-1"

# Scan with named profile
AWS_PROFILE=production ./aws_resource_cleanup_audit.sh
```

## 📁 Output Structure

The script creates a timestamped directory with the following files:

```
aws_cleanup_report_20250103_143022/
├── 00_SUMMARY_REPORT.txt          # Executive summary and recommendations
├── 01_ec2_instances.csv           # EC2 analysis with CPU metrics
├── 02_ebs_volumes.csv             # EBS volumes with attachment status
├── 03_ebs_snapshots.csv           # Snapshot analysis by age
├── 04_elastic_ips.csv             # Elastic IP association status
├── 05_load_balancers.csv          # Load balancer traffic analysis
├── 06_rds_instances.csv           # RDS connection metrics
├── 07_s3_buckets.csv              # S3 bucket size and objects
├── 08_lambda_functions.csv        # Lambda invocation counts
└── 09_nat_gateways.csv            # NAT Gateway traffic
```

## 📋 CSV Column Descriptions

### EC2 Instances
- **Region** - AWS region
- **InstanceId** - EC2 instance ID
- **Name** - Instance name tag
- **State** - Current state (running/stopped/terminated)
- **InstanceType** - Instance size
- **LaunchTime** - When instance was created
- **DaysSinceLaunch** - Age in days
- **AvgCPU_30d** - Average CPU utilization over 30 days
- **Platform** - Linux/Windows
- **Recommendation** - DELETE/REVIEW/KEEP
- **EstMonthlyCost** - Estimated monthly cost

### EBS Volumes
- **State** - available (unattached) or in-use
- **Size(GB)** - Volume size
- **VolumeType** - gp2, gp3, io1, etc.
- **AttachedTo** - Instance ID or "Unattached"
- **AvgReadOps/AvgWriteOps** - IOPS metrics
- **Recommendation** - Action to take

### And similar detailed columns for all other resource types...

## 🎯 Quick Wins Identification

The script automatically identifies high-priority cleanup opportunities:

### 1. Unassociated Elastic IPs 💰
- **Impact**: $3.60/month per IP
- **Action**: Release immediately
- **CSV**: `04_elastic_ips.csv`
- **Filter**: Recommendation = "DELETE - Unassociated"

### 2. Unattached EBS Volumes 💰💰
- **Impact**: Varies by size/type (e.g., $10/month for 100GB gp3)
- **Action**: Create snapshot, then delete
- **CSV**: `02_ebs_volumes.csv`
- **Filter**: State = "available"

### 3. Stopped EC2 Instances 💰💰
- **Impact**: Still paying for attached EBS storage
- **Action**: Terminate after verification
- **CSV**: `01_ec2_instances.csv`
- **Filter**: State = "stopped" AND DaysSinceLaunch > 30

### 4. Idle RDS Databases 💰💰💰
- **Impact**: $15-$300+/month depending on size
- **Action**: Final snapshot, then delete
- **CSV**: `06_rds_instances.csv`
- **Filter**: AvgConnections < 1

### 5. Idle Load Balancers 💰💰
- **Impact**: $16-22/month per LB
- **Action**: Delete
- **CSV**: `05_load_balancers.csv`
- **Filter**: AvgRequestCount < 1

### 6. Old Snapshots 💰
- **Impact**: $0.05/GB-month
- **Action**: Delete snapshots > 1 year old
- **CSV**: `03_ebs_snapshots.csv`
- **Filter**: DaysSinceCreation > 365

## 📊 Example Workflow

### Step 1: Run the script
```bash
./aws_resource_cleanup_audit.sh
# Wait 10-30 minutes depending on account size
```

### Step 2: Review summary
```bash
cat aws_cleanup_report_*/00_SUMMARY_REPORT.txt
```

### Step 3: Open CSVs in spreadsheet
- Import CSVs into Excel/Google Sheets
- Sort by "Recommendation" column
- Filter for "DELETE" recommendations first

### Step 4: Verify and act
For each resource marked "DELETE":
1. Verify in AWS Console
2. Check CloudWatch metrics
3. Create backup/snapshot if needed
4. Delete resource
5. Document the deletion

### Step 5: Monitor savings
- Check AWS Cost Explorer after 1 week
- Compare costs before/after cleanup

## ⚙️ Configuration

You can modify these variables at the top of the script:

```bash
DAYS_THRESHOLD=30      # Resources older than this are flagged
CPU_THRESHOLD=5        # CPU percentage for idle EC2 detection
```

## 🔒 Required AWS Permissions

The script requires read-only permissions. Minimum IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "rds:Describe*",
        "elasticloadbalancing:Describe*",
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "lambda:List*",
        "lambda:Get*",
        "cloudwatch:GetMetricStatistics",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

## ⏱️ Runtime Expectations

| Account Size | Resources | Estimated Time |
|--------------|-----------|----------------|
| Small | < 100 | 5-10 minutes |
| Medium | 100-500 | 15-30 minutes |
| Large | 500-2000 | 30-60 minutes |
| Enterprise | 2000+ | 1-2 hours |

## 🛡️ Safety Features

- **Read-only operations** - Nothing is modified or deleted
- **Detailed logging** - All actions are logged
- **Backup reminders** - Summary includes backup recommendations
- **Staged approach** - Recommends gradual cleanup
- **Metric validation** - 30-day averages reduce false positives

## 📈 Sample Output

```
========================================
AWS Resource Cleanup Audit Script
========================================

Profile: production
Output Directory: aws_cleanup_report_20250103_143022
Days Threshold: 30 days

Getting account information...
Account ID: 123456789012

Scanning 4 region(s)...

[1/9] Analyzing EC2 Instances...
  Scanning region: us-east-1
  Scanning region: us-west-2
  ✓ EC2 analysis complete

[2/9] Analyzing EBS Volumes...
  Scanning region: us-east-1
  Scanning region: us-west-2
  ✓ EBS analysis complete

...

========================================
AUDIT COMPLETE!
========================================

Report location: aws_cleanup_report_20250103_143022

Generated files:
-rw-r--r-- 1 user user 2.4K Jan  3 14:32 00_SUMMARY_REPORT.txt
-rw-r--r-- 1 user user  15K Jan  3 14:32 01_ec2_instances.csv
-rw-r--r-- 1 user user 8.2K Jan  3 14:32 02_ebs_volumes.csv
...
```

## 🔧 Troubleshooting

### Issue: "Command not found: bc"
```bash
# Install bc for calculations
sudo apt-get install bc       # Debian/Ubuntu
sudo yum install bc           # RHEL/CentOS
brew install bc               # macOS
```

### Issue: "Unable to locate credentials"
```bash
# Configure AWS CLI
aws configure

# Or set profile
export AWS_PROFILE=your-profile-name
```

### Issue: "Rate limit exceeded"
- The script includes built-in delays
- For large accounts, consider running on specific regions
- Or run during off-peak hours

### Issue: "Permission denied"
```bash
# Make script executable
chmod +x aws_resource_cleanup_audit.sh
```

## 🎓 Best Practices

### Before Running
1. Ensure AWS CLI is properly configured
2. Test with a single region first
3. Run during a maintenance window if possible

### After Running
1. Review summary report first
2. Sort CSVs by recommendation column
3. Verify "DELETE" items in AWS Console
4. Take snapshots before deleting
5. Delete in stages (weekly batches)
6. Monitor for complaints
7. Track savings in Cost Explorer

### Ongoing Management
1. Run monthly or quarterly
2. Tag resources properly going forward
3. Set up AWS Config for continuous monitoring
4. Enable AWS Cost Anomaly Detection
5. Use AWS Budgets for alerts

## 📝 Recommended Tags

For better resource management, implement these tags:

```
Environment: production|staging|development|test
Owner: team-name or email
Project: project-name
CostCenter: department or cost allocation
AutoDelete: yes|no (for automation)
ExpiryDate: YYYY-MM-DD (for temporary resources)
```

## 🤝 Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

MIT License - feel free to use and modify as needed.

## ⚠️ Disclaimer

- This script provides recommendations only
- Always verify before deleting resources
- Cost estimates are approximate
- Test in a non-production account first
- The author is not responsible for any resource deletion or data loss

## 🙋 Support

For issues or questions:
- Open a GitHub issue
- Review the troubleshooting section
- Check AWS CLI documentation

## 🎉 Success Stories

After running this script, typical findings include:
- 10-20 unassociated Elastic IPs ($36-72/month savings)
- 50-100 old snapshots ($50-500/month savings)
- 5-10 stopped instances with attached EBS ($50-200/month savings)
- 2-3 idle RDS instances ($50-600/month savings)
- **Total potential savings: $200-1500/month for medium-sized accounts**

## 📚 Additional Resources

- [AWS Cost Optimization](https://aws.amazon.com/pricing/cost-optimization/)
- [AWS Well-Architected Framework - Cost Optimization](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html)
- [AWS Trusted Advisor](https://aws.amazon.com/premiumsupport/technology/trusted-advisor/)
- [AWS Cost Explorer](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/)

---

**Happy Cost Optimizing! 💰**