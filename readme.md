# AWS Tag Propagation Toolkit

A collection of Bash automation scripts to enforce consistent tagging across AWS infrastructure resources.  
This toolkit ensures the `NBHI-CostCenter-Application` tag is consistently propagated across dependent AWS resources for governance, cost allocation, and compliance.

---

## 📦 Included Scripts

### 1. EC2 → EBS + ENI Tag Replication
**File:** `ec2-ebs-eni-tag-replication.sh`

Replicates tags from EC2 instances to attached resources:

- EBS Volumes
- Network Interfaces (ENIs)

#### How it works:
- Finds EC2 instances with tag:
  ```
  NBHI-CostCenter-Application
  ```
- Extracts tag value from EC2 instance
- Applies the same tag to:
  - Attached EBS volumes
  - Attached ENIs
- Avoids duplicate tagging
- Supports dry-run mode

---

### 2. Load Balancer Tag Propagation
**File:** `replicate-lb-tag.sh`

Replicates tags from AWS Load Balancers to associated resources:

- Target Groups
- Network Interfaces (ENIs)
- Elastic IPs (if attached)

#### How it works:
- Scans all ELBv2 load balancers in the region
- Reads tag:
  ```
  NBHI-CostCenter-Application
  ```
- Propagates tag to:
  - Target Groups
  - ENIs
  - Elastic IPs
- Includes fallback logic for ENI discovery
- Supports `--dry-run` mode

---

## 🏗️ Architecture Overview

```
EC2 Instance
   ├── EBS Volumes
   └── ENIs
        ↓
Tag Replication Script


Load Balancer (ALB / NLB)
   ├── Target Groups
   ├── ENIs
   └── Elastic IPs
        ↓
Tag Replication Script
```

---

## ⚙️ Requirements

- AWS CLI v2 installed and configured
- `bash` shell environment

### IAM Permissions Required

#### EC2 Script
- `ec2:DescribeInstances`
- `ec2:DescribeTags`
- `ec2:CreateTags`

#### Load Balancer Script
- `elasticloadbalancing:DescribeLoadBalancers`
- `elasticloadbalancing:DescribeTags`
- `elasticloadbalancing:DescribeTargetGroups`
- `elasticloadbalancing:AddTags`
- `ec2:DescribeNetworkInterfaces`
- `ec2:DescribeAddresses`
- `ec2:CreateTags`

---

## 🚀 Usage

### 1. EC2 Tag Replication Script

```bash
chmod +x ec2-ebs-eni-tag-replication.sh
./ec2-ebs-eni-tag-replication.sh
```

#### Dry run mode:
```bash
DRY_RUN=true ./ec2-ebs-eni-tag-replication.sh
```

---

### 2. Load Balancer Tag Propagation Script

```bash
chmod +x replicate-lb-tag.sh
./replicate-lb-tag.sh
```

#### Dry run mode:
```bash
./replicate-lb-tag.sh --dry-run
```

---

## 🎯 Use Cases

- AWS FinOps cost allocation enforcement
- Tag governance across infrastructure
- Preventing untagged dependent resources
- Ensuring compliance with tagging policies
- Infrastructure consistency across AWS services

---

## ⚠️ Notes

- Both scripts depend on the base tag:
  ```
  NBHI-CostCenter-Application (Can be Changed according to the need)
  ```
- Designed for single-region execution
- Load balancer script supports ALB and NLB
- Uses AWS CLI (no external dependencies)
