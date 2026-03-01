#!/bin/bash
# =============================================================
# Azure Deployment Environments (ADE) - Destroy Script
# Tears down EVERYTHING created by the setup script
# =============================================================

set -e

# ─────────────────────────────────────────────
# CONFIGURATION — Must match setup script
# ─────────────────────────────────────────────
RG="rg-ade-demo3"
DEVCENTER="my-devcenter2"
PROJECT="my-ade-project"
ENV_NAME="my-dev-vm"

# Extra RGs to clean up from previous attempts
EXTRA_RGS="rg-ade-demo rg-ade-demo2"

# ─────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_START=$(date +%s)
ts()          { date '+%H:%M:%S'; }
total_elapsed(){
  local D=$(( $(date +%s) - SCRIPT_START ))
  printf "%02dm %02ds" $((D/60)) $((D%60))
}
log()    { echo -e "${BLUE}  [$(ts)]${NC} $1"; }
success(){ echo -e "${GREEN}  [$(ts)] ✅ $1 (total: $(total_elapsed))${NC}"; echo ""; }
warn()   { echo -e "${YELLOW}  [$(ts)] ⚠️  $1${NC}"; }
step(){
  echo ""
  echo -e "${CYAN}┌─────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│ [$(ts)] $1${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────────┘${NC}"
}

echo ""
echo -e "${RED}╔═════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║        ADE Destroy — Started at $(ts)       ║${NC}"
echo -e "${RED}╚═════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${RED}⚠️  This will permanently delete:${NC}"
echo -e "   Resource Group : $RG (+ all resources inside)"
echo -e "   Extra RGs      : $EXTRA_RGS"
echo -e "   Dev Center     : $DEVCENTER"
echo -e "   Project        : $PROJECT"
echo -e "   Environment    : $ENV_NAME"
echo -e "   All VM RGs     : my-ade-project-* pattern"
echo ""
read -p "Type 'yes' to confirm destruction: " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted. Nothing was deleted."
  exit 0
fi

SUB_ID=$(az account show --query id -o tsv)

# ─────────────────────────────────────────────
# STEP 1 — Delete Environment
# ─────────────────────────────────────────────
step "Deleting ADE Environment: $ENV_NAME"
DEVCENTER_URI=$(az devcenter admin devcenter show \
  --name $DEVCENTER \
  --resource-group $RG \
  --query "devCenterUri" -o tsv 2>/dev/null) || {
    warn "Dev Center not found — skipping environment deletion"
    DEVCENTER_URI=""
  }

if [ ! -z "$DEVCENTER_URI" ]; then
  log "Deleting environment (this takes 5-10 mins)..."
  az devcenter dev environment delete \
    --endpoint $DEVCENTER_URI \
    --project-name $PROJECT \
    --name $ENV_NAME \
    --user-id me \
    --yes \
    --output none 2>/dev/null || warn "Environment not found or already deleted"
  success "Environment deleted"
fi

step "Deleting Extra Resource Groups from Previous Attempts"
for EXTRA_RG in $EXTRA_RGS; do
  EXISTS=$(az group show --name $EXTRA_RG --query name -o tsv 2>/dev/null) || true
  if [ ! -z "$EXISTS" ]; then
    log "Deleting: $EXTRA_RG..."
    az group delete \
      --name $EXTRA_RG \
      --yes \
      --no-wait \
      --output none 2>/dev/null || warn "Could not delete $EXTRA_RG"
  else
    log "$EXTRA_RG not found, skipping"
  fi
done
success "Extra resource groups deletion initiated"

# ─────────────────────────────────────────────
# STEP 2 — Delete VM Resource Groups
# ─────────────────────────────────────────────
step "Deleting VM Resource Groups (my-ade-project-* pattern)"
VM_RGS=$(az group list \
  --query "[?starts_with(name, 'my-ade-project-')].name" \
  -o tsv 2>/dev/null)

if [ -z "$VM_RGS" ]; then
  warn "No VM resource groups found"
else
  for RG_NAME in $VM_RGS; do
    log "Deleting: $RG_NAME..."
    az group delete \
      --name $RG_NAME \
      --yes \
      --no-wait \
      --output none 2>/dev/null || warn "Could not delete $RG_NAME"
  done
  success "VM resource groups deletion initiated"
fi

# ─────────────────────────────────────────────
# STEP 3 — Delete Main Resource Group
# ─────────────────────────────────────────────
step "Deleting Main Resource Group: $RG"
az group delete \
  --name $RG \
  --yes \
  --no-wait \
  --output none 2>/dev/null || warn "Resource group $RG not found"
success "Main resource group deletion initiated"

# ─────────────────────────────────────────────
# STEP 4 — Clean Orphaned Role Assignments
# ─────────────────────────────────────────────
step "Cleaning Orphaned Role Assignments"
log "Removing role assignments for deleted service principals..."
ORPHANED=$(az role assignment list \
  --scope "/subscriptions/$SUB_ID" \
  --query "[?principalType=='ServicePrincipal' && principalName==null].id" \
  -o tsv 2>/dev/null)

if [ -z "$ORPHANED" ]; then
  log "No orphaned role assignments found"
else
  echo "$ORPHANED" | while read RA_ID; do
    az role assignment delete --ids $RA_ID --output none 2>/dev/null || true
  done
fi
success "Role assignments cleaned"

# ─────────────────────────────────────────────
# FINAL
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✅ DESTROY COMPLETE                   ║${NC}"
echo -e "${GREEN}║        Total time: $(total_elapsed)                    ║${NC}"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}  Note: Resource group deletions run in background${NC}"
echo -e "${YELLOW}  Check status with:${NC}"
echo -e "  az group show --name $RG --query provisioningState -o tsv"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  To recreate everything from scratch:${NC}"
echo -e "  ./setup.sh"
echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
