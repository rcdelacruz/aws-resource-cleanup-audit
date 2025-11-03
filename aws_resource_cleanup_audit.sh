#!/bin/bash

################################################################################
# AWS Resource Cleanup Audit Script
# 
# Purpose: Generates comprehensive CSV reports of AWS resources with usage
#          metrics to identify candidates for cleanup
#
# Output: Multiple CSV files with detailed resource information and recommendations
#
# Usage: ./aws_resource_cleanup_audit.sh [profile] [regions]
#        ./aws_resource_cleanup_audit.sh default "us-east-1,us-west-2"
#        ./aws_resource_cleanup_audit.sh  (uses default profile and all regions)
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
AWS_PROFILE="${1:-default}"
SPECIFIED_REGIONS="$2"
OUTPUT_DIR="aws_cleanup_report_$(date +%Y%m%d_%H%M%S)"
DAYS_THRESHOLD=30  # Resources older than this are flagged
CPU_THRESHOLD=5    # CPU percentage threshold for idle EC2

# Set AWS profile
export AWS_PROFILE

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}AWS Resource Cleanup Audit Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Profile: ${GREEN}${AWS_PROFILE}${NC}"
echo -e "Output Directory: ${GREEN}${OUTPUT_DIR}${NC}"
echo -e "Days Threshold: ${GREEN}${DAYS_THRESHOLD} days${NC}"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to get all regions or use specified ones
get_regions() {
    if [ -n "$SPECIFIED_REGIONS" ]; then
        echo "$SPECIFIED_REGIONS" | tr ',' '\n'
    else
        aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n'
    fi
}

# Function to get account ID
get_account_id() {
    aws sts get-caller-identity --query Account --output text
}

# Function to calculate days since date
days_since() {
    local date_str="$1"
    if [ -z "$date_str" ] || [ "$date_str" = "None" ] || [ "$date_str" = "null" ]; then
        echo "N/A"
        return
    fi
    
    local date_epoch=$(date -d "$date_str" +%s 2>/dev/null || echo "0")
    local now_epoch=$(date +%s)
    local days=$(( (now_epoch - date_epoch) / 86400 ))
    echo "$days"
}

# Function to get CloudWatch metric statistics
get_metric_stats() {
    local namespace="$1"
    local metric_name="$2"
    local dimensions="$3"
    local region="$4"
    local days="${5:-30}"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%S")
    local start_time=$(date -u -d "$days days ago" +"%Y-%m-%dT%H:%M:%S")
    
    aws cloudwatch get-metric-statistics \
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

echo -e "${YELLOW}Getting account information...${NC}"
ACCOUNT_ID=$(get_account_id)
echo -e "Account ID: ${GREEN}${ACCOUNT_ID}${NC}"
echo ""

# Get regions to scan
REGIONS=($(get_regions))
echo -e "${YELLOW}Scanning ${#REGIONS[@]} region(s)...${NC}"
echo ""

################################################################################
# 1. EC2 INSTANCES ANALYSIS
################################################################################
echo -e "${BLUE}[1/9] Analyzing EC2 Instances...${NC}"

EC2_FILE="$OUTPUT_DIR/01_ec2_instances.csv"
echo "Region,InstanceId,Name,State,InstanceType,LaunchTime,DaysSinceLaunch,AvgCPU_30d,Platform,PrivateIP,PublicIP,Tags,Recommendation,EstMonthlyCost" > "$EC2_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    instances=$(aws ec2 describe-instances \
        --region "$region" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],State.Name,InstanceType,LaunchTime,Platform,PrivateIpAddress,PublicIpAddress,Tags]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$instances" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r instance_id name state instance_type launch_time platform private_ip public_ip tags; do
        [ -z "$instance_id" ] && continue
        
        name="${name:-N/A}"
        platform="${platform:-Linux}"
        private_ip="${private_ip:-N/A}"
        public_ip="${public_ip:-N/A}"
        
        # Calculate days since launch
        days_old=$(days_since "$launch_time")
        
        # Get average CPU utilization
        avg_cpu="N/A"
        if [ "$state" = "running" ]; then
            avg_cpu=$(get_metric_stats "AWS/EC2" "CPUUtilization" "Name=InstanceId,Value=$instance_id" "$region" 30)
        fi
        
        # Estimate monthly cost (rough estimates)
        cost="N/A"
        if [ "$state" = "running" ]; then
            case "$instance_type" in
                t2.micro) cost="\$8.50" ;;
                t2.small) cost="\$17.00" ;;
                t2.medium) cost="\$34.00" ;;
                t3.micro) cost="\$7.50" ;;
                t3.small) cost="\$15.00" ;;
                t3.medium) cost="\$30.00" ;;
                m5.large) cost="\$70.00" ;;
                m5.xlarge) cost="\$140.00" ;;
                *) cost="Unknown" ;;
            esac
        elif [ "$state" = "stopped" ]; then
            cost="\$0 (but EBS charges apply)"
        fi
        
        # Generate recommendation
        recommendation=""
        if [ "$state" = "stopped" ] && [ "$days_old" != "N/A" ] && [ "$days_old" -gt "$DAYS_THRESHOLD" ]; then
            recommendation="DELETE - Stopped for $days_old days"
        elif [ "$state" = "running" ] && [ "$avg_cpu" != "N/A" ] && [ "$(echo "$avg_cpu < $CPU_THRESHOLD" | bc -l)" = "1" ]; then
            recommendation="REVIEW - Low CPU usage ($avg_cpu%)"
        elif [ "$state" = "terminated" ]; then
            recommendation="IGNORE - Already terminated"
        else
            recommendation="KEEP"
        fi
        
        # Clean tags for CSV
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        echo "$region,$instance_id,$name,$state,$instance_type,$launch_time,$days_old,$avg_cpu,$platform,$private_ip,$public_ip,\"$clean_tags\",$recommendation,$cost" >> "$EC2_FILE"
    done <<< "$instances"
done

echo -e "${GREEN}  ✓ EC2 analysis complete${NC}"
echo ""

################################################################################
# 2. EBS VOLUMES ANALYSIS
################################################################################
echo -e "${BLUE}[2/9] Analyzing EBS Volumes...${NC}"

EBS_FILE="$OUTPUT_DIR/02_ebs_volumes.csv"
echo "Region,VolumeId,State,Size(GB),VolumeType,CreateTime,DaysSinceCreation,AttachedTo,AvgReadOps,AvgWriteOps,IOPS,Encrypted,Tags,Recommendation,EstMonthlyCost" > "$EBS_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    volumes=$(aws ec2 describe-volumes \
        --region "$region" \
        --query 'Volumes[].[VolumeId,State,Size,VolumeType,CreateTime,Attachments[0].InstanceId,Iops,Encrypted,Tags]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$volumes" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r volume_id state size volume_type create_time instance_id iops encrypted tags; do
        [ -z "$volume_id" ] && continue
        
        instance_id="${instance_id:-Unattached}"
        iops="${iops:-N/A}"
        encrypted="${encrypted:-false}"
        
        days_old=$(days_since "$create_time")
        
        # Get read/write ops
        avg_read="N/A"
        avg_write="N/A"
        if [ "$state" = "in-use" ]; then
            avg_read=$(get_metric_stats "AWS/EBS" "VolumeReadOps" "Name=VolumeId,Value=$volume_id" "$region" 30)
            avg_write=$(get_metric_stats "AWS/EBS" "VolumeWriteOps" "Name=VolumeId,Value=$volume_id" "$region" 30)
        fi
        
        # Estimate cost
        cost="N/A"
        case "$volume_type" in
            gp2) cost="\$$(echo "$size * 0.10" | bc)" ;;
            gp3) cost="\$$(echo "$size * 0.08" | bc)" ;;
            io1) cost="\$$(echo "$size * 0.125 + $iops * 0.065" | bc)" ;;
            io2) cost="\$$(echo "$size * 0.125 + $iops * 0.065" | bc)" ;;
            st1) cost="\$$(echo "$size * 0.045" | bc)" ;;
            sc1) cost="\$$(echo "$size * 0.025" | bc)" ;;
        esac
        
        # Recommendation
        recommendation=""
        if [ "$state" = "available" ] && [ "$days_old" != "N/A" ] && [ "$days_old" -gt "$DAYS_THRESHOLD" ]; then
            recommendation="DELETE - Unattached for $days_old days"
        elif [ "$state" = "available" ]; then
            recommendation="REVIEW - Currently unattached"
        else
            recommendation="KEEP"
        fi
        
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        echo "$region,$volume_id,$state,$size,$volume_type,$create_time,$days_old,$instance_id,$avg_read,$avg_write,$iops,$encrypted,\"$clean_tags\",$recommendation,$cost" >> "$EBS_FILE"
    done <<< "$volumes"
done

echo -e "${GREEN}  ✓ EBS analysis complete${NC}"
echo ""

################################################################################
# 3. EBS SNAPSHOTS ANALYSIS
################################################################################
echo -e "${BLUE}[3/9] Analyzing EBS Snapshots...${NC}"

SNAP_FILE="$OUTPUT_DIR/03_ebs_snapshots.csv"
echo "Region,SnapshotId,VolumeId,StartTime,DaysSinceCreation,Size(GB),State,Description,Encrypted,Tags,Recommendation,EstMonthlyCost" > "$SNAP_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    snapshots=$(aws ec2 describe-snapshots \
        --region "$region" \
        --owner-ids "$ACCOUNT_ID" \
        --query 'Snapshots[].[SnapshotId,VolumeId,StartTime,VolumeSize,State,Description,Encrypted,Tags]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$snapshots" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r snapshot_id volume_id start_time size state description encrypted tags; do
        [ -z "$snapshot_id" ] && continue
        
        volume_id="${volume_id:-N/A}"
        description="${description:-N/A}"
        encrypted="${encrypted:-false}"
        
        days_old=$(days_since "$start_time")
        
        # Cost estimate (snapshots are charged per GB-month)
        cost="\$$(echo "$size * 0.05" | bc)"
        
        # Recommendation
        recommendation=""
        if [ "$days_old" != "N/A" ] && [ "$days_old" -gt 90 ]; then
            recommendation="REVIEW - Older than 90 days"
        elif [ "$days_old" != "N/A" ] && [ "$days_old" -gt 365 ]; then
            recommendation="DELETE - Older than 1 year"
        else
            recommendation="KEEP"
        fi
        
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        clean_desc=$(echo "$description" | tr ',' ';')
        
        echo "$region,$snapshot_id,$volume_id,$start_time,$days_old,$size,$state,\"$clean_desc\",$encrypted,\"$clean_tags\",$recommendation,$cost" >> "$SNAP_FILE"
    done <<< "$snapshots"
done

echo -e "${GREEN}  ✓ Snapshot analysis complete${NC}"
echo ""

################################################################################
# 4. ELASTIC IPs ANALYSIS
################################################################################
echo -e "${BLUE}[4/9] Analyzing Elastic IPs...${NC}"

EIP_FILE="$OUTPUT_DIR/04_elastic_ips.csv"
echo "Region,AllocationId,PublicIp,AssociatedInstanceId,PrivateIpAddress,Domain,NetworkInterfaceId,Tags,Recommendation,EstMonthlyCost" > "$EIP_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    eips=$(aws ec2 describe-addresses \
        --region "$region" \
        --query 'Addresses[].[AllocationId,PublicIp,InstanceId,PrivateIpAddress,Domain,NetworkInterfaceId,Tags]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$eips" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r allocation_id public_ip instance_id private_ip domain network_interface tags; do
        [ -z "$allocation_id" ] && continue
        
        instance_id="${instance_id:-Unassociated}"
        private_ip="${private_ip:-N/A}"
        network_interface="${network_interface:-N/A}"
        
        # Unassociated EIPs cost money!
        cost="\$0"
        recommendation="KEEP"
        if [ "$instance_id" = "Unassociated" ] && [ "$network_interface" = "N/A" ]; then
            cost="\$3.60"
            recommendation="DELETE - Unassociated (costing \$3.60/month)"
        fi
        
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        echo "$region,$allocation_id,$public_ip,$instance_id,$private_ip,$domain,$network_interface,\"$clean_tags\",$recommendation,$cost" >> "$EIP_FILE"
    done <<< "$eips"
done

echo -e "${GREEN}  ✓ Elastic IP analysis complete${NC}"
echo ""

################################################################################
# 5. LOAD BALANCERS ANALYSIS (ALB/NLB/CLB)
################################################################################
echo -e "${BLUE}[5/9] Analyzing Load Balancers...${NC}"

LB_FILE="$OUTPUT_DIR/05_load_balancers.csv"
echo "Region,LoadBalancerName,Type,DNSName,Scheme,VpcId,CreatedTime,DaysSinceCreation,State,AvgRequestCount,AvgActiveConnections,Tags,Recommendation,EstMonthlyCost" > "$LB_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    # ALB/NLB (ELBv2)
    lbs=$(aws elbv2 describe-load-balancers \
        --region "$region" \
        --query 'LoadBalancers[].[LoadBalancerName,Type,DNSName,Scheme,VpcId,CreatedTime,State.Code,LoadBalancerArn]' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$lbs" ]; then
        while IFS=$'\t' read -r lb_name lb_type dns_name scheme vpc_id created_time state lb_arn; do
            [ -z "$lb_name" ] && continue
            
            days_old=$(days_since "$created_time")
            
            # Get metrics
            avg_requests="N/A"
            avg_connections="N/A"
            
            if [ "$lb_type" = "application" ]; then
                # Extract LB name from ARN for CloudWatch
                cw_lb_name=$(echo "$lb_arn" | awk -F'loadbalancer/' '{print $2}')
                avg_requests=$(get_metric_stats "AWS/ApplicationELB" "RequestCount" "Name=LoadBalancer,Value=$cw_lb_name" "$region" 30)
                avg_connections=$(get_metric_stats "AWS/ApplicationELB" "ActiveConnectionCount" "Name=LoadBalancer,Value=$cw_lb_name" "$region" 30)
            elif [ "$lb_type" = "network" ]; then
                cw_lb_name=$(echo "$lb_arn" | awk -F'loadbalancer/' '{print $2}')
                avg_connections=$(get_metric_stats "AWS/NetworkELB" "ActiveFlowCount" "Name=LoadBalancer,Value=$cw_lb_name" "$region" 30)
            fi
            
            # Get tags
            tags=$(aws elbv2 describe-tags --region "$region" --resource-arns "$lb_arn" --query 'TagDescriptions[0].Tags' --output text 2>/dev/null || echo "")
            clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
            
            # Cost estimates
            cost="\$16-22"  # ALB/NLB rough estimate
            
            # Recommendation
            recommendation=""
            if [ "$avg_requests" != "N/A" ] && [ "$(echo "$avg_requests < 1" | bc -l)" = "1" ] && [ "$days_old" -gt 7 ]; then
                recommendation="DELETE - No traffic for 30 days"
            elif [ "$avg_connections" != "N/A" ] && [ "$(echo "$avg_connections < 1" | bc -l)" = "1" ] && [ "$days_old" -gt 7 ]; then
                recommendation="DELETE - No connections for 30 days"
            else
                recommendation="KEEP"
            fi
            
            echo "$region,$lb_name,$lb_type,$dns_name,$scheme,$vpc_id,$created_time,$days_old,$state,$avg_requests,$avg_connections,\"$clean_tags\",$recommendation,$cost" >> "$LB_FILE"
        done <<< "$lbs"
    fi
    
    # Classic Load Balancers
    clbs=$(aws elb describe-load-balancers \
        --region "$region" \
        --query 'LoadBalancerDescriptions[].[LoadBalancerName,DNSName,Scheme,VPCId,CreatedTime]' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$clbs" ]; then
        while IFS=$'\t' read -r lb_name dns_name scheme vpc_id created_time; do
            [ -z "$lb_name" ] && continue
            
            days_old=$(days_since "$created_time")
            
            avg_requests=$(get_metric_stats "AWS/ELB" "RequestCount" "Name=LoadBalancerName,Value=$lb_name" "$region" 30)
            
            # Get tags
            tags=$(aws elb describe-tags --region "$region" --load-balancer-names "$lb_name" --query 'TagDescriptions[0].Tags' --output text 2>/dev/null || echo "")
            clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
            
            cost="\$18"  # Classic LB estimate
            
            recommendation=""
            if [ "$avg_requests" != "N/A" ] && [ "$(echo "$avg_requests < 1" | bc -l)" = "1" ]; then
                recommendation="DELETE - No traffic for 30 days"
            else
                recommendation="KEEP"
            fi
            
            echo "$region,$lb_name,classic,$dns_name,$scheme,$vpc_id,$created_time,$days_old,active,$avg_requests,N/A,\"$clean_tags\",$recommendation,$cost" >> "$LB_FILE"
        done <<< "$clbs"
    fi
done

echo -e "${GREEN}  ✓ Load Balancer analysis complete${NC}"
echo ""

################################################################################
# 6. RDS INSTANCES ANALYSIS
################################################################################
echo -e "${BLUE}[6/9] Analyzing RDS Instances...${NC}"

RDS_FILE="$OUTPUT_DIR/06_rds_instances.csv"
echo "Region,DBInstanceIdentifier,DBInstanceClass,Engine,EngineVersion,Status,AllocatedStorage(GB),CreateTime,DaysSinceCreation,MultiAZ,StorageEncrypted,AvgConnections,AvgReadIOPS,AvgWriteIOPS,Tags,Recommendation,EstMonthlyCost" > "$RDS_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    instances=$(aws rds describe-db-instances \
        --region "$region" \
        --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceClass,Engine,EngineVersion,DBInstanceStatus,AllocatedStorage,InstanceCreateTime,MultiAZ,StorageEncrypted,TagList]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$instances" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r db_id db_class engine engine_version status storage create_time multi_az encrypted tags; do
        [ -z "$db_id" ] && continue
        
        days_old=$(days_since "$create_time")
        
        # Get metrics
        avg_connections="N/A"
        avg_read_iops="N/A"
        avg_write_iops="N/A"
        
        if [ "$status" = "available" ]; then
            avg_connections=$(get_metric_stats "AWS/RDS" "DatabaseConnections" "Name=DBInstanceIdentifier,Value=$db_id" "$region" 30)
            avg_read_iops=$(get_metric_stats "AWS/RDS" "ReadIOPS" "Name=DBInstanceIdentifier,Value=$db_id" "$region" 30)
            avg_write_iops=$(get_metric_stats "AWS/RDS" "WriteIOPS" "Name=DBInstanceIdentifier,Value=$db_id" "$region" 30)
        fi
        
        # Cost estimate (very rough)
        cost="Unknown"
        case "$db_class" in
            db.t2.micro) cost="\$15" ;;
            db.t2.small) cost="\$30" ;;
            db.t3.micro) cost="\$15" ;;
            db.t3.small) cost="\$30" ;;
            db.t3.medium) cost="\$60" ;;
            db.m5.large) cost="\$140" ;;
        esac
        
        # Recommendation
        recommendation=""
        if [ "$status" = "stopped" ]; then
            recommendation="REVIEW - Currently stopped"
        elif [ "$avg_connections" != "N/A" ] && [ "$(echo "$avg_connections < 1" | bc -l)" = "1" ]; then
            recommendation="DELETE - Zero connections for 30 days"
        else
            recommendation="KEEP"
        fi
        
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        echo "$region,$db_id,$db_class,$engine,$engine_version,$status,$storage,$create_time,$days_old,$multi_az,$encrypted,$avg_connections,$avg_read_iops,$avg_write_iops,\"$clean_tags\",$recommendation,$cost" >> "$RDS_FILE"
    done <<< "$instances"
done

echo -e "${GREEN}  ✓ RDS analysis complete${NC}"
echo ""

################################################################################
# 7. S3 BUCKETS ANALYSIS
################################################################################
echo -e "${BLUE}[7/9] Analyzing S3 Buckets...${NC}"

S3_FILE="$OUTPUT_DIR/07_s3_buckets.csv"
echo "BucketName,CreationDate,DaysSinceCreation,Region,NumberOfObjects,TotalSize(GB),Versioning,Encryption,PublicAccess,Tags,Recommendation,EstMonthlyCost" > "$S3_FILE"

buckets=$(aws s3api list-buckets --query 'Buckets[].[Name,CreationDate]' --output text 2>/dev/null || echo "")

if [ -n "$buckets" ]; then
    while IFS=$'\t' read -r bucket_name creation_date; do
        [ -z "$bucket_name" ] && continue
        
        echo -e "  Analyzing bucket: ${bucket_name}"
        
        days_old=$(days_since "$creation_date")
        
        # Get bucket region
        bucket_region=$(aws s3api get-bucket-location --bucket "$bucket_name" --query 'LocationConstraint' --output text 2>/dev/null || echo "us-east-1")
        [ "$bucket_region" = "None" ] && bucket_region="us-east-1"
        
        # Get bucket size and object count
        size_info=$(aws s3 ls s3://"$bucket_name" --recursive --summarize 2>/dev/null | tail -2)
        object_count=$(echo "$size_info" | grep "Total Objects:" | awk '{print $3}')
        total_size=$(echo "$size_info" | grep "Total Size:" | awk '{print $3}')
        
        object_count="${object_count:-0}"
        total_size="${total_size:-0}"
        size_gb=$(echo "scale=2; $total_size / 1073741824" | bc)
        
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
        cost="\$$(echo "scale=2; $size_gb * 0.023" | bc)"  # Standard S3 pricing
        
        # Recommendation
        recommendation=""
        if [ "$object_count" -eq 0 ]; then
            recommendation="DELETE - Empty bucket"
        elif [ "$(echo "$size_gb < 0.1" | bc -l)" = "1" ] && [ "$days_old" -gt 180 ]; then
            recommendation="REVIEW - Nearly empty and old"
        else
            recommendation="KEEP"
        fi
        
        echo "$bucket_name,$creation_date,$days_old,$bucket_region,$object_count,$size_gb,$versioning,$encryption,$public_access,\"$clean_tags\",$recommendation,$cost" >> "$S3_FILE"
    done <<< "$buckets"
fi

echo -e "${GREEN}  ✓ S3 analysis complete${NC}"
echo ""

################################################################################
# 8. LAMBDA FUNCTIONS ANALYSIS
################################################################################
echo -e "${BLUE}[8/9] Analyzing Lambda Functions...${NC}"

LAMBDA_FILE="$OUTPUT_DIR/08_lambda_functions.csv"
echo "Region,FunctionName,Runtime,MemorySize(MB),CodeSize(bytes),LastModified,DaysSinceModified,Timeout,AvgInvocations,AvgDuration,AvgErrors,Tags,Recommendation,EstMonthlyCost" > "$LAMBDA_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    functions=$(aws lambda list-functions \
        --region "$region" \
        --query 'Functions[].[FunctionName,Runtime,MemorySize,CodeSize,LastModified,Timeout]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$functions" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r func_name runtime memory code_size last_modified timeout; do
        [ -z "$func_name" ] && continue
        
        days_old=$(days_since "$last_modified")
        
        # Get metrics
        avg_invocations=$(get_metric_stats "AWS/Lambda" "Invocations" "Name=FunctionName,Value=$func_name" "$region" 30)
        avg_duration=$(get_metric_stats "AWS/Lambda" "Duration" "Name=FunctionName,Value=$func_name" "$region" 30)
        avg_errors=$(get_metric_stats "AWS/Lambda" "Errors" "Name=FunctionName,Value=$func_name" "$region" 30)
        
        # Get tags
        func_arn=$(aws lambda get-function --function-name "$func_name" --region "$region" --query 'Configuration.FunctionArn' --output text 2>/dev/null)
        tags=$(aws lambda list-tags --resource "$func_arn" --region "$region" --query 'Tags' --output text 2>/dev/null || echo "")
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        # Cost is usually negligible for Lambda
        cost="<\$1"
        
        # Recommendation
        recommendation=""
        if [ "$avg_invocations" != "N/A" ] && [ "$(echo "$avg_invocations < 1" | bc -l)" = "1" ] && [ "$days_old" -gt 90 ]; then
            recommendation="DELETE - No invocations for 30 days"
        else
            recommendation="KEEP"
        fi
        
        echo "$region,$func_name,$runtime,$memory,$code_size,$last_modified,$days_old,$timeout,$avg_invocations,$avg_duration,$avg_errors,\"$clean_tags\",$recommendation,$cost" >> "$LAMBDA_FILE"
    done <<< "$functions"
done

echo -e "${GREEN}  ✓ Lambda analysis complete${NC}"
echo ""

################################################################################
# 9. NAT GATEWAYS ANALYSIS
################################################################################
echo -e "${BLUE}[9/9] Analyzing NAT Gateways...${NC}"

NAT_FILE="$OUTPUT_DIR/09_nat_gateways.csv"
echo "Region,NatGatewayId,State,SubnetId,VpcId,CreateTime,DaysSinceCreation,PublicIp,PrivateIp,AvgBytesOut,Tags,Recommendation,EstMonthlyCost" > "$NAT_FILE"

for region in "${REGIONS[@]}"; do
    echo -e "  Scanning region: ${region}"
    
    nat_gws=$(aws ec2 describe-nat-gateways \
        --region "$region" \
        --query 'NatGateways[].[NatGatewayId,State,SubnetId,VpcId,CreateTime,NatGatewayAddresses[0].PublicIp,NatGatewayAddresses[0].PrivateIp,Tags]' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$nat_gws" ]; then
        continue
    fi
    
    while IFS=$'\t' read -r nat_id state subnet_id vpc_id create_time public_ip private_ip tags; do
        [ -z "$nat_id" ] && continue
        
        days_old=$(days_since "$create_time")
        
        # Get metrics
        avg_bytes_out="N/A"
        if [ "$state" = "available" ]; then
            avg_bytes_out=$(get_metric_stats "AWS/NATGateway" "BytesOutToDestination" "Name=NatGatewayId,Value=$nat_id" "$region" 30)
        fi
        
        clean_tags=$(echo "$tags" | tr '\n' ' ' | tr ',' ';' | sed 's/\t/ /g')
        
        # NAT Gateways are expensive!
        cost="\$32.40"  # ~$0.045/hour
        
        # Recommendation
        recommendation=""
        if [ "$avg_bytes_out" != "N/A" ] && [ "$(echo "$avg_bytes_out < 1000000" | bc -l)" = "1" ]; then
            recommendation="REVIEW - Very low traffic (consider deleting)"
        else
            recommendation="KEEP"
        fi
        
        echo "$region,$nat_id,$state,$subnet_id,$vpc_id,$create_time,$days_old,$public_ip,$private_ip,$avg_bytes_out,\"$clean_tags\",$recommendation,$cost" >> "$NAT_FILE"
    done <<< "$nat_gws"
done

echo -e "${GREEN}  ✓ NAT Gateway analysis complete${NC}"
echo ""

################################################################################
# GENERATE SUMMARY REPORT
################################################################################
echo -e "${BLUE}Generating Summary Report...${NC}"

SUMMARY_FILE="$OUTPUT_DIR/00_SUMMARY_REPORT.txt"

cat > "$SUMMARY_FILE" << EOF
================================================================================
AWS RESOURCE CLEANUP AUDIT REPORT
================================================================================

Generated: $(date)
AWS Account: ${ACCOUNT_ID}
AWS Profile: ${AWS_PROFILE}
Regions Scanned: ${#REGIONS[@]}

================================================================================
EXECUTIVE SUMMARY
================================================================================

This report contains detailed CSV files for the following resource types:

1. EC2 Instances       - 01_ec2_instances.csv
2. EBS Volumes         - 02_ebs_volumes.csv
3. EBS Snapshots       - 03_ebs_snapshots.csv
4. Elastic IPs         - 04_elastic_ips.csv
5. Load Balancers      - 05_load_balancers.csv
6. RDS Instances       - 06_rds_instances.csv
7. S3 Buckets          - 07_s3_buckets.csv
8. Lambda Functions    - 08_lambda_functions.csv
9. NAT Gateways        - 09_nat_gateways.csv

================================================================================
KEY FINDINGS
================================================================================

EOF

# Count recommendations by type
for file in "$OUTPUT_DIR"/*.csv; do
    [ "$file" = "$OUTPUT_DIR/*.csv" ] && continue
    [ "$(basename "$file")" = "00_SUMMARY_REPORT.txt" ] && continue
    
    filename=$(basename "$file")
    total_resources=$(tail -n +2 "$file" | wc -l)
    delete_count=$(tail -n +2 "$file" | grep -c "DELETE" || echo "0")
    review_count=$(tail -n +2 "$file" | grep -c "REVIEW" || echo "0")
    
    echo "File: $filename" >> "$SUMMARY_FILE"
    echo "  Total Resources: $total_resources" >> "$SUMMARY_FILE"
    echo "  Recommended for DELETE: $delete_count" >> "$SUMMARY_FILE"
    echo "  Recommended for REVIEW: $review_count" >> "$SUMMARY_FILE"
    echo "" >> "$SUMMARY_FILE"
done

cat >> "$SUMMARY_FILE" << EOF

================================================================================
QUICK WINS (HIGH PRIORITY)
================================================================================

1. UNATTACHED ELASTIC IPs
   - Check: 04_elastic_ips.csv
   - Look for: Recommendation = "DELETE - Unassociated"
   - Action: Release these immediately
   - Savings: \$3.60/month per IP

2. UNATTACHED EBS VOLUMES
   - Check: 02_ebs_volumes.csv
   - Look for: State = "available" AND DaysSinceCreation > 30
   - Action: Create snapshots, then delete
   - Savings: Varies by volume type/size

3. OLD EBS SNAPSHOTS
   - Check: 03_ebs_snapshots.csv
   - Look for: DaysSinceCreation > 365
   - Action: Delete after confirming not needed
   - Savings: \$0.05/GB-month

4. STOPPED EC2 INSTANCES
   - Check: 01_ec2_instances.csv
   - Look for: State = "stopped" AND DaysSinceLaunch > 30
   - Action: Terminate (EBS charges still apply while stopped!)
   - Savings: Varies by instance type

5. IDLE RDS INSTANCES
   - Check: 06_rds_instances.csv
   - Look for: AvgConnections < 1
   - Action: Take final snapshot, then delete
   - Savings: Varies by instance class

6. IDLE LOAD BALANCERS
   - Check: 05_load_balancers.csv
   - Look for: AvgRequestCount < 1 or AvgActiveConnections < 1
   - Action: Delete
   - Savings: \$16-22/month per LB

================================================================================
NEXT STEPS
================================================================================

1. Review each CSV file in a spreadsheet application
2. Sort by "Recommendation" column to prioritize actions
3. Start with "DELETE" recommendations (safest wins)
4. Review "REVIEW" recommendations more carefully
5. For critical resources, verify in CloudWatch before deleting
6. Take snapshots/backups before deletion
7. Delete in stages (week by week) to catch any issues
8. Monitor AWS Cost Explorer for savings impact

================================================================================
IMPORTANT NOTES
================================================================================

- All cost estimates are approximate
- CloudWatch metrics are 30-day averages
- Some metrics may show "N/A" if CloudWatch data is unavailable
- Always verify critical resources before deletion
- Keep snapshots for 30 days after resource deletion
- Consider setting up AWS Config for ongoing monitoring

================================================================================
TAGS RECOMMENDATION
================================================================================

For better resource management going forward, implement these tags:

- Environment: production/staging/development/test
- Owner: team-name or email
- Project: project-name
- CostCenter: department or cost allocation
- AutoDelete: yes/no (for automation)
- ExpiryDate: YYYY-MM-DD (for temporary resources)

Use AWS Tag Editor to bulk-apply tags to existing resources.

================================================================================
END OF REPORT
================================================================================
EOF

echo -e "${GREEN}  ✓ Summary report generated${NC}"
echo ""

################################################################################
# FINAL OUTPUT
################################################################################

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}AUDIT COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Report location: ${BLUE}${OUTPUT_DIR}${NC}"
echo ""
echo -e "Generated files:"
ls -lh "$OUTPUT_DIR"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Review ${BLUE}00_SUMMARY_REPORT.txt${NC} for overview"
echo -e "2. Open CSV files in spreadsheet application"
echo -e "3. Sort by 'Recommendation' column"
echo -e "4. Start with 'DELETE' recommendations"
echo -e "5. Verify critical resources before deletion"
echo ""
echo -e "${RED}WARNING: Always backup/snapshot before deleting resources!${NC}"
echo ""
