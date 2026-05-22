#!/usr/bin/env bash
# replicate-nbhi-to-assocs.sh
# Enumerate all ELBv2 load balancers in the configured region.
# For each LB, if tag NBHI-CostCenter-Application exists, copy it to:
#   - Target Groups (elbv2:AddTags)
#   - Network Interfaces (ec2:CreateTags)
#   - Elastic IPs attached to those ENIs (ec2:CreateTags on AllocationId or PublicIp)
# Usage:
#   ./replicate-nbhi-to-assocs.sh [--dry-run]
# Requirements:
#   - AWS CLI v2 configured
#   - IAM principal with: elasticloadbalancing:DescribeLoadBalancers, DescribeTags, DescribeTargetGroups, AddTags;
#     ec2:DescribeNetworkInterfaces, DescribeAddresses, CreateTags
set -euo pipefail

TAG_KEY="NBHI-CostCenter-Application"
AWS_REGION="${AWS_REGION:-$(aws configure get region || echo us-east-1)}"
DRY_RUN=false

# parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown arg: $arg"; echo "Usage: $0 [--dry-run]"; exit 1 ;;
  esac
done

err() { printf '%s\n' "$*" >&2; }

if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI not found"
  exit 2
fi

err "Region: $AWS_REGION"
if $DRY_RUN; then err "Mode: DRY-RUN (no changes will be made)"; fi

# Helper: convert whitespace/tab/newline separated text into unique lines
# Removes empty lines and 'None' tokens
to_array() {
  local raw="$1"
  printf '%s\n' "$raw" \
    | tr '\t' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v -e '^$' -e '^None$' \
    | awk '!seen[$0]++'
}

# Process a single LB ARN
process_lb() {
  local lb_arn="$1"
  err "=== Processing LB: $lb_arn ==="

  # Get tag value
  local tag_value
  tag_value=$(aws elbv2 describe-tags --region "$AWS_REGION" --resource-arns "$lb_arn" \
    --query "TagDescriptions[0].Tags[?Key=='${TAG_KEY}'].Value | [0]" --output text || true)

  if [[ -z "$tag_value" || "$tag_value" == "None" ]]; then
    err "  Tag ${TAG_KEY} not present on LB; skipping."
    return
  fi
  err "  Found tag: ${TAG_KEY}=${tag_value}"

  # 1) Target Groups
  local tg_raw tg_array
  tg_raw=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --load-balancer-arn "$lb_arn" \
    --query "TargetGroups[].TargetGroupArn" --output text || true)
  mapfile -t tg_array < <(to_array "$tg_raw")
  if [[ ${#tg_array[@]} -gt 0 ]]; then
    err "  Target groups: ${tg_array[*]}"
    if $DRY_RUN; then
      err "  [dry-run] Would add tag to target groups: ${tg_array[*]}"
    else
      # chunk to avoid too-large calls (safe chunk size 20)
      local i=0 chunk_size=20
      while [ $i -lt ${#tg_array[@]} ]; do
        chunk=( "${tg_array[@]:$i:$chunk_size}" )
        aws elbv2 add-tags --region "$AWS_REGION" --resource-arns "${chunk[@]}" --tags Key="$TAG_KEY",Value="$tag_value"
        i=$((i + chunk_size))
      done
      err "  Tagged target groups."
    fi
  else
    err "  No target groups found."
  fi

  # 2) ENI discovery
  local eni_raw eni_array
  # Preferred: LoadBalancerAddresses (works for NLB)
  eni_raw=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$lb_arn" \
    --query "LoadBalancers[0].AvailabilityZones[].LoadBalancerAddresses[].NetworkInterfaceId" --output text || true)

  if [[ -z "$eni_raw" || "$eni_raw" == "None" ]]; then
    # fallback: search ENIs by LoadBalancerName in description (works for ALB/NLB)
    local lb_name
    lb_name=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --load-balancer-arns "$lb_arn" \
      --query "LoadBalancers[0].LoadBalancerName" --output text || true)
    if [[ -n "$lb_name" && "$lb_name" != "None" ]]; then
      err "  No ENIs from LoadBalancerAddresses; searching ENIs by description fragment: ${lb_name}"
      eni_raw=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --filters "Name=description,Values=*${lb_name}*" "Name=status,Values=in-use" \
        --query "NetworkInterfaces[].NetworkInterfaceId" --output text || true)
    fi
  fi

  mapfile -t eni_array < <(to_array "$eni_raw")
  if [[ ${#eni_array[@]} -eq 0 ]]; then
    err "  No ENIs discovered for LB."
  else
    err "  ENIs discovered: ${eni_array[*]}"
    if $DRY_RUN; then
      for eni in "${eni_array[@]}"; do err "  [dry-run] Would tag ENI: $eni -> $TAG_KEY=$tag_value"; done
    else
      # Tag ENIs (chunk if many)
      aws ec2 create-tags --region "$AWS_REGION" --resources "${eni_array[@]}" --tags Key="$TAG_KEY",Value="$tag_value"
      err "  Tagged ENIs."
    fi

    # 3) EIPs for each ENI
    for eni in "${eni_array[@]}"; do
      local alloc_raw alloc_array
      # Query both AllocationId and PublicIp; output text gives tab-separated columns
      alloc_raw=$(aws ec2 describe-addresses --region "$AWS_REGION" --filters "Name=network-interface-id,Values=${eni}" \
        --query "Addresses[].{alloc:AllocationId,ip:PublicIp}" --output text || true)

      # Build an array of non-empty resource IDs (prefer AllocationId)
      alloc_array=()
      if [[ -n "$alloc_raw" ]]; then
        # Each line is either "alloc<TAB>ip" or "None<TAB>ip" etc.
        while IFS=$'\t' read -r alloc ip; do
          # trim whitespace
          alloc="${alloc##*( )}"
          alloc="${alloc%%*( )}"
          ip="${ip##*( )}"
          ip="${ip%%*( )}"
          if [[ -n "$alloc" && "$alloc" != "None" ]]; then
            alloc_array+=("$alloc")
          elif [[ -n "$ip" && "$ip" != "None" ]]; then
            alloc_array+=("$ip")
          fi
        done <<< "$alloc_raw"
      fi

      if [[ ${#alloc_array[@]} -gt 0 ]]; then
        if $DRY_RUN; then
          for a in "${alloc_array[@]}"; do err "  [dry-run] Would tag EIP resource: $a (ENI $eni) -> $TAG_KEY=$tag_value"; done
        else
          aws ec2 create-tags --region "$AWS_REGION" --resources "${alloc_array[@]}" --tags Key="$TAG_KEY",Value="$tag_value"
          err "  Tagged EIPs for ENI $eni: ${alloc_array[*]}"
        fi
      else
        err "  No EIP associated with ENI $eni"
      fi
    done
  fi

  err "=== Done LB: $lb_arn ==="
}

# Main: enumerate all LBs and process each
all_lb_raw=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "LoadBalancers[].LoadBalancerArn" --output text || true)
mapfile -t all_lbs < <(to_array "$all_lb_raw")

if [[ ${#all_lbs[@]} -eq 0 ]]; then
  err "No ELBv2 load balancers found in region $AWS_REGION."
  exit 0
fi

err "Found ${#all_lbs[@]} load balancer(s). Starting replication..."
for lb in "${all_lbs[@]}"; do
  process_lb "$lb"
done

err "All done."
exit 0