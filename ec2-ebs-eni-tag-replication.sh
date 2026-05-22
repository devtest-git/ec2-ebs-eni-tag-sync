#!/usr/bin/env bash
set -euo pipefail

# Configuration
TAG_KEY="NBHI-CostCenter-Application"
DRY_RUN="${DRY_RUN:-false}"   # export DRY_RUN=true for dry-run

log() { printf '%s\n' "$*" >&2; }

# Ensure AWS CLI is available
if ! command -v aws >/dev/null 2>&1; then
  log "aws CLI not found. Install or run in CloudShell."
  exit 2
fi

# Get all instance IDs that have the tag key
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag-key,Values=${TAG_KEY}" \
  --query "Reservations[].Instances[].InstanceId" --output text)

if [ -z "${INSTANCE_IDS}" ]; then
  log "No instances found with tag key ${TAG_KEY}. Exiting."
  exit 0
fi

log "Found instances: ${INSTANCE_IDS}"

for INSTANCE in ${INSTANCE_IDS}; do
  # Get the tag value for this instance
  TAG_VALUE=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=${INSTANCE}" "Name=key,Values=${TAG_KEY}" \
    --query "Tags[0].Value" --output text)

  if [ -z "${TAG_VALUE}" ] || [ "${TAG_VALUE}" = "None" ]; then
    log "Instance ${INSTANCE} has no value for ${TAG_KEY}, skipping."
    continue
  fi

  log "Processing instance ${INSTANCE} with ${TAG_KEY}=${TAG_VALUE}"

  # Collect attached ENI IDs
  ENI_IDS=$(aws ec2 describe-instances --instance-ids "${INSTANCE}" \
    --query "Reservations[].Instances[].NetworkInterfaces[].NetworkInterfaceId" --output text || true)

  # Collect attached EBS volume IDs
  VOLUME_IDS=$(aws ec2 describe-instances --instance-ids "${INSTANCE}" \
    --query "Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId" --output text || true)

  # Build resource list (skip empty)
  RESOURCES=()
  if [ -n "${ENI_IDS}" ]; then
    for id in ${ENI_IDS}; do RESOURCES+=("${id}"); done
  fi
  if [ -n "${VOLUME_IDS}" ]; then
    for id in ${VOLUME_IDS}; do RESOURCES+=("${id}"); done
  fi

  if [ "${#RESOURCES[@]}" -eq 0 ]; then
    log "No ENIs or EBS volumes attached to ${INSTANCE}"
    continue
  fi

  # Filter out resources that already have the same tag value to avoid unnecessary API calls
  TO_TAG=()
  for res in "${RESOURCES[@]}"; do
    existing=$(aws ec2 describe-tags \
      --filters "Name=resource-id,Values=${res}" "Name=key,Values=${TAG_KEY}" \
      --query "Tags[0].Value" --output text || echo "None")
    if [ "${existing}" = "None" ] || [ "${existing}" != "${TAG_VALUE}" ]; then
      TO_TAG+=("${res}")
    else
      log "Resource ${res} already has ${TAG_KEY}=${TAG_VALUE}, skipping."
    fi
  done

  if [ "${#TO_TAG[@]}" -eq 0 ]; then
    log "No resources to tag for instance ${INSTANCE}"
    continue
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    log "[DRY-RUN] Would tag resources: ${TO_TAG[*]} with ${TAG_KEY}=${TAG_VALUE}"
  else
    # Batch tagging (aws accepts multiple resource ids)
    aws ec2 create-tags --resources "${TO_TAG[@]}" --tags Key="${TAG_KEY}",Value="${TAG_VALUE}"
    log "Tagged resources: ${TO_TAG[*]} with ${TAG_KEY}=${TAG_VALUE}"
  fi
done

log "Completed."
