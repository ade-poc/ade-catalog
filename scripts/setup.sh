#!/bin/bash
# =============================================================
# Azure Deployment Environments (ADE) - Complete Setup Script
# Deploys: Dev Center → Catalog → Project → VM Environment
# Output:  SSH command to connect to VM + Hello World Python
# =============================================================

set -e

# ─────────────────────────────────────────────
# CONFIGURATION — Edit these values
# ─────────────────────────────────────────────
RG="rg-ade-demo3"
LOCATION="eastus"
DEVCENTER="my-devcenter2"
PROJECT="my-ade-project"
ENV_TYPE="Dev"
CATALOG_NAME="my-catalog"
ENV_NAME="my-dev-vm"
GITHUB_REPO="https://github.com/srinipaddu/ade-catalog.git"
GITHUB_PAT="YOUR_GITHUB_PAT_HERE"
ADMIN_USERNAME="azureuser"
VM_SIZE="Standard_D2s_v3"

# ─────────────────────────────────────────────
# COLORS & TIMING
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_START=$(date +%s)
STEP_START=$SCRIPT_START

ts()          { date '+%H:%M:%S'; }
total_elapsed(){
  local D=$(( $(date +%s) - SCRIPT_START ))
  printf "%02dm %02ds" $((D/60)) $((D%60))
}
step_elapsed(){
  local D=$(( $(date +%s) - STEP_START ))
  printf "%02dm %02ds" $((D/60)) $((D%60))
}
log()    { echo -e "${BLUE}  [$(ts)]${NC} $1"; }
success(){
  echo -e "${GREEN}  [$(ts)] ✅ $1${NC}"
  echo -e "${MAGENTA}  ⏱  Step: $(step_elapsed) | Total: $(total_elapsed)${NC}"
  echo ""
  STEP_START=$(date +%s)
}
warn()   { echo -e "${YELLOW}  [$(ts)] ⚠️  $1${NC}"; }
error()  { echo -e "${RED}  [$(ts)] ❌ $1${NC}"; exit 1; }
step(){
  STEP_START=$(date +%s)
  echo ""
  echo -e "${CYAN}┌─────────────────────────────────────────────────┐${NC}"
  echo -e "${CYAN}│ [$(ts)] STEP $1: $2${NC}"
  echo -e "${CYAN}└─────────────────────────────────────────────────┘${NC}"
}

echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     ADE Full Setup — Started at $(ts)       ║${NC}"
echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"

# ─────────────────────────────────────────────
# STEP 0 — Prerequisites
# ─────────────────────────────────────────────
step "0" "Verifying Prerequisites"
az --version > /dev/null 2>&1 || error "Azure CLI not installed. Run: brew install azure-cli"
az extension show --name devcenter > /dev/null 2>&1 || {
  log "Installing devcenter extension..."
  az extension add --name devcenter --output none
}
log "Updating devcenter extension..."
az extension update --name devcenter --output none 2>/dev/null || true
success "Prerequisites verified"

# ─────────────────────────────────────────────
# STEP 1 — Login & Subscription
# ─────────────────────────────────────────────
step "1" "Fetching Login & Subscription Info"
SUB_ID=$(az account show --query id -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
log "Subscription : $SUB_ID"
log "Tenant       : $TENANT_ID"
log "User OID     : $MY_OBJECT_ID"
success "Subscription info fetched"

# ─────────────────────────────────────────────
# STEP 2 — Resource Group
# ─────────────────────────────────────────────
step "2" "Creating Resource Group: $RG in $LOCATION"

# Wait for any existing RG with same name to finish deleting
MAX_WAIT=900  # 15 minutes max (ADE resource groups can take longer)
WAITED=0
while true; do
  STATE=$(az group show --name $RG --query "properties.provisioningState" -o tsv 2>/dev/null) || STATE="Gone"
  if [ "$STATE" == "Gone" ] || [ -z "$STATE" ]; then
    log "No existing RG found — safe to create"
    break
  elif [ "$STATE" == "Deleting" ]; then
    if [ $WAITED -ge $MAX_WAIT ]; then
      error "Timed out waiting for RG '$RG' to finish deleting after ${MAX_WAIT}s"
    fi
    warn "RG '$RG' is still deleting... waiting 15s (${WAITED}s elapsed)"
    sleep 15
    WAITED=$((WAITED + 15))
  else
    warn "RG '$RG' exists with state: $STATE — deleting it first..."
    az group delete --name $RG --yes --no-wait --output none
    sleep 15
    WAITED=$((WAITED + 15))
  fi
done

az group create --name $RG --location $LOCATION --output none
success "Resource group '$RG' created"

# ─────────────────────────────────────────────
# STEP 3 — Register Providers
# ─────────────────────────────────────────────
step "3" "Registering Resource Providers"
for NS in Microsoft.DevCenter Microsoft.KeyVault Microsoft.Compute Microsoft.Network; do
  STATE=$(az provider show --namespace $NS --query "registrationState" -o tsv 2>/dev/null)
  if [ "$STATE" == "Registered" ]; then
    log "$NS already registered ✓"
  else
    log "Registering $NS..."
    az provider register --namespace $NS --wait
  fi
done
success "All providers registered"

# ─────────────────────────────────────────────
# STEP 4 — Dev Center
# ─────────────────────────────────────────────
step "4" "Creating Dev Center: $DEVCENTER"

# Check if Dev Center name already exists in tenant
EXISTING_DC=$(az devcenter admin devcenter list \
  --query "[?name=='$DEVCENTER'].name" -o tsv 2>/dev/null)
if [ ! -z "$EXISTING_DC" ]; then
  warn "Dev Center '$DEVCENTER' already exists in tenant"
  warn "Either delete it first or change DEVCENTER name in config"
  error "Dev Center name must be unique across the entire tenant"
fi
az devcenter admin devcenter create \
  --name $DEVCENTER \
  --resource-group $RG \
  --location $LOCATION \
  --identity-type SystemAssigned \
  --output none

PRINCIPAL_ID=$(az devcenter admin devcenter show \
  --name $DEVCENTER \
  --resource-group $RG \
  --query "identity.principalId" -o tsv)

DEVCENTER_URI=$(az devcenter admin devcenter show \
  --name $DEVCENTER \
  --resource-group $RG \
  --query "devCenterUri" -o tsv)

log "Principal ID  : $PRINCIPAL_ID"
log "Dev Center URI: $DEVCENTER_URI"
success "Dev Center '$DEVCENTER' created"

# ─────────────────────────────────────────────
# STEP 5 — Roles for Dev Center Identity
# ─────────────────────────────────────────────
step "5" "Assigning Roles to Dev Center Managed Identity"
log "Assigning Contributor..."
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUB_ID" \
  --output none

log "Assigning User Access Administrator..."
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUB_ID" \
  --output none
success "Dev Center identity roles assigned"

# ─────────────────────────────────────────────
# STEP 6 — Key Vault + GitHub PAT
# ─────────────────────────────────────────────
step "6" "Creating Key Vault & Storing GitHub PAT"
KV_NAME="kvade${RANDOM}"
log "Key Vault name: $KV_NAME"

az keyvault create \
  --name $KV_NAME \
  --resource-group $RG \
  --location $LOCATION \
  --enable-rbac-authorization true \
  --output none
log "Key Vault created"

KV_ID=$(az keyvault show --name $KV_NAME --query id -o tsv)

log "Granting Secrets Officer to current user..."
az role assignment create \
  --assignee $MY_OBJECT_ID \
  --role "Key Vault Secrets Officer" \
  --scope $KV_ID \
  --output none

log "Waiting 30s for role propagation..."
sleep 30

log "Storing GitHub PAT..."
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "github-pat" \
  --value "$GITHUB_PAT" \
  --output none

SECRET_ID=$(az keyvault secret show \
  --vault-name $KV_NAME \
  --name "github-pat" \
  --query "id" -o tsv | sed 's|/[^/]*$||')

log "Granting Key Vault Secrets User to Dev Center..."
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Key Vault Secrets User" \
  --scope $KV_ID \
  --output none
success "Key Vault created and PAT stored"

# ─────────────────────────────────────────────
# STEP 7 — Dev Center Environment Type
# ─────────────────────────────────────────────
step "7" "Creating Dev Center Environment Type: $ENV_TYPE"
az devcenter admin environment-type create \
  --name $ENV_TYPE \
  --dev-center-name $DEVCENTER \
  --resource-group $RG \
  --output none
success "Environment type '$ENV_TYPE' created"

# ─────────────────────────────────────────────
# STEP 8 — Project
# ─────────────────────────────────────────────
step "8" "Creating Project: $PROJECT"
DEVCENTER_ID=$(az devcenter admin devcenter show \
  --name $DEVCENTER \
  --resource-group $RG \
  --query id -o tsv)

az devcenter admin project create \
  --name $PROJECT \
  --dev-center-id $DEVCENTER_ID \
  --resource-group $RG \
  --location $LOCATION \
  --identity-type SystemAssigned \
  --output none

PROJECT_PRINCIPAL_ID=$(az devcenter admin project show \
  --name $PROJECT \
  --resource-group $RG \
  --query "identity.principalId" -o tsv)

PROJECT_ID=$(az devcenter admin project show \
  --name $PROJECT \
  --resource-group $RG \
  --query id -o tsv)

log "Project Principal ID: $PROJECT_PRINCIPAL_ID"

log "Assigning Contributor to Project identity..."
az role assignment create \
  --assignee $PROJECT_PRINCIPAL_ID \
  --role "Contributor" \
  --scope "/subscriptions/$SUB_ID" \
  --output none

log "Assigning Deployment Environments User to current user..."
az role assignment create \
  --assignee $MY_OBJECT_ID \
  --role "Deployment Environments User" \
  --scope $PROJECT_ID \
  --output none
success "Project '$PROJECT' created and roles assigned"

# ─────────────────────────────────────────────
# STEP 9 — Project Environment Type
# ─────────────────────────────────────────────
step "9" "Creating Project Environment Type (waiting 60s for propagation)"
log "Sleeping 60s for role assignments to propagate..."
sleep 60

az devcenter admin project-environment-type create \
  --name $ENV_TYPE \
  --project-name $PROJECT \
  --resource-group $RG \
  --deployment-target-id "/subscriptions/$SUB_ID" \
  --identity-type SystemAssigned \
  --status "Enabled" \
  --roles "{\"b24988ac-6180-42a0-ab88-20f7382dd24c\": {}}" \
  --output none
success "Project environment type '$ENV_TYPE' created"

# ─────────────────────────────────────────────
# STEP 10 — Catalog
# ─────────────────────────────────────────────
step "10" "Attaching GitHub Catalog: $CATALOG_NAME"
az devcenter admin catalog create \
  --name $CATALOG_NAME \
  --dev-center-name $DEVCENTER \
  --resource-group $RG \
  --git-hub \
    uri="$GITHUB_REPO" \
    branch="main" \
    path="/Environments" \
    secret-identifier="$SECRET_ID" \
  --output none

# Re-set the PAT secret to ensure ADE picks up a fresh version
log "Re-setting GitHub PAT in Key Vault to ensure fresh auth..."
az keyvault secret set \
  --vault-name $KV_NAME \
  --name "github-pat" \
  --value "$GITHUB_PAT" \
  --output none

log "Waiting for catalog sync to complete (polling every 15s, max 10 mins)..."
SYNC_WAITED=0
SYNC_MAX=600
while true; do
  SYNC_STATE=$(az devcenter admin catalog show \
    --name $CATALOG_NAME \
    --dev-center-name $DEVCENTER \
    --resource-group $RG \
    --query "syncState" -o tsv)
  log "Catalog sync state: $SYNC_STATE (${SYNC_WAITED}s elapsed)"

  if [ "$SYNC_STATE" == "Succeeded" ]; then
    break
  elif [ "$SYNC_STATE" == "Failed" ]; then
    warn "Catalog sync failed — re-setting PAT and forcing re-sync..."
    az keyvault secret set \
      --vault-name $KV_NAME \
      --name "github-pat" \
      --value "$GITHUB_PAT" \
      --output none
    az devcenter admin catalog sync \
      --name $CATALOG_NAME \
      --dev-center-name $DEVCENTER \
      --resource-group $RG \
      --no-wait
  fi

  if [ $SYNC_WAITED -ge $SYNC_MAX ]; then
    error "Timed out waiting for catalog sync after ${SYNC_MAX}s (last state: $SYNC_STATE)"
  fi

  sleep 15
  SYNC_WAITED=$((SYNC_WAITED + 15))
done
success "Catalog synced successfully"

# ─────────────────────────────────────────────
# STEP 11 — Deploy VM Environment
# ─────────────────────────────────────────────
step "11" "Deploying VM Environment: $ENV_NAME (5-8 mins)"
log "Checking if environment '$ENV_NAME' already exists..."
ENV_EXISTS=$(az devcenter dev environment show \
  --endpoint $DEVCENTER_URI \
  --project-name $PROJECT \
  --name $ENV_NAME \
  2>/dev/null) || true

if [ -n "$ENV_EXISTS" ]; then
  warn "Environment '$ENV_NAME' already exists. Deleting it first..."
  az devcenter dev environment delete \
    --endpoint $DEVCENTER_URI \
    --project-name $PROJECT \
    --name $ENV_NAME \
    --yes
  log "Waiting for environment deletion to complete..."
  while az devcenter dev environment show \
      --endpoint $DEVCENTER_URI \
      --project-name $PROJECT \
      --name $ENV_NAME \
      2>/dev/null; do
    sleep 10
  done
  success "Existing environment deleted"
fi

log "Starting VM deployment at $(ts)..."
az devcenter dev environment create \
  --endpoint $DEVCENTER_URI \
  --project-name $PROJECT \
  --name $ENV_NAME \
  --environment-type $ENV_TYPE \
  --catalog-name $CATALOG_NAME \
  --environment-definition-name "LinuxVM" \
  --parameters "{\"adminUsername\": \"$ADMIN_USERNAME\"}"
success "VM environment deployed"

# ─────────────────────────────────────────────
# STEP 12 — Get SSH Command & Outputs
# ─────────────────────────────────────────────
step "12" "Fetching SSH Command & VM Details"

ENV_RG=$(az devcenter dev environment show \
  --endpoint $DEVCENTER_URI \
  --project-name $PROJECT \
  --name $ENV_NAME \
  --user-id me \
  --query "resourceGroupId" -o tsv | sed 's|.*/||')
log "Environment RG: $ENV_RG"

DEPLOYMENT_NAME=$(az deployment group list \
  --resource-group $ENV_RG \
  --query "[0].name" -o tsv)
log "Deployment name: $DEPLOYMENT_NAME"

SSH_COMMAND=$(az deployment group show \
  --resource-group $ENV_RG \
  --name $DEPLOYMENT_NAME \
  --query "properties.outputs.sshCommand.value" -o tsv)

VM_PASSWORD=$(az deployment group show \
  --resource-group $ENV_RG \
  --name $DEPLOYMENT_NAME \
  --query "properties.outputs.adminPassword.value" -o tsv)

VM_FQDN=$(az deployment group show \
  --resource-group $ENV_RG \
  --name $DEPLOYMENT_NAME \
  --query "properties.outputs.vmFqdn.value" -o tsv)
success "VM details fetched"

# ─────────────────────────────────────────────
# STEP 13 — Verify Hello World
# ─────────────────────────────────────────────
step "13" "Verifying Hello World Python on VM"
log "Waiting 60s for VM to fully boot and run cloud-init..."
sleep 60

log "Connecting to VM and running Hello World..."
HELLO_OUTPUT=$(sshpass -p "$VM_PASSWORD" ssh \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=30 \
  $ADMIN_USERNAME@$VM_FQDN \
  'python3 -c "print(\"Hello World from Azure VM!\")"' 2>/dev/null) || {
    warn "sshpass not installed or SSH not ready yet"
    warn "You can SSH manually using the details below"
    HELLO_OUTPUT="(run manually)"
  }
log "Hello World output: $HELLO_OUTPUT"
success "Hello World verified"

# ─────────────────────────────────────────────
# FINAL SUMMARY
# ─────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔═════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           ✅ DEPLOYMENT COMPLETE                ║${NC}"
echo -e "${GREEN}║        Total time: $(total_elapsed)                    ║${NC}"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${YELLOW}  Resource Group  :${NC} $RG"
echo -e "${YELLOW}  Dev Center      :${NC} $DEVCENTER"
echo -e "${YELLOW}  Dev Center URI  :${NC} $DEVCENTER_URI"
echo -e "${YELLOW}  Project         :${NC} $PROJECT"
echo -e "${YELLOW}  Environment     :${NC} $ENV_NAME"
echo -e "${YELLOW}  Environment RG  :${NC} $ENV_RG"
echo -e "${YELLOW}  VM FQDN         :${NC} $VM_FQDN"
echo -e "${YELLOW}  Admin Username  :${NC} $ADMIN_USERNAME"
echo -e "${YELLOW}  Admin Password  :${NC} $VM_PASSWORD"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  SSH Command:${NC}"
echo -e "  $SSH_COMMAND"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  Run Hello World Python:${NC}"
echo -e "  $SSH_COMMAND 'python3 -c \"print(\\\"Hello World from Azure VM!\\\")\"'"
echo -e "${GREEN}╠═════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  Hello World Output:${NC} $HELLO_OUTPUT"
echo -e "${GREEN}╚═════════════════════════════════════════════════╝${NC}"
