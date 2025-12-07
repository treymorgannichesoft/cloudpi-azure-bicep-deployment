#!/bin/bash
# ============================================================================
# Interactive CloudPi Infrastructure Deployment Script
# ============================================================================
# Description: Interactive script that prompts for deployment options
# Usage: ./deploy-interactive.sh
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        Interactive Infrastructure Deployment                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ============================================================================
# Step 0: Azure Login and Context Verification
# ============================================================================

echo -e "${CYAN}[0/7] Verify Azure Login${NC}"
echo ""

# Check if logged into Azure
if ! az account show &>/dev/null; then
    echo -e "${RED}✗ Not logged into Azure${NC}"
    echo ""
    echo "Please login first:"
    echo "  az login"
    echo ""
    exit 1
fi

# Auto-detect current Azure context
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

echo -e "${GREEN}✓ Logged into Azure${NC}"
echo ""
echo -e "${YELLOW}Current Azure Context:${NC}"
echo "  Subscription: $SUBSCRIPTION_NAME"
echo "  Subscription ID: $SUBSCRIPTION_ID"
echo "  Tenant ID: $TENANT_ID"
echo ""

read -p "Deploy to this subscription? (y/n): " confirm_subscription

if [[ ! $confirm_subscription =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${CYAN}Available Subscriptions:${NC}"
    az account list --query "[].{Name:name, SubscriptionId:id, Default:isDefault}" -o table
    echo ""
    read -p "Enter the Subscription ID to use: " new_subscription_id

    # Validate and set subscription
    if az account set --subscription "$new_subscription_id" 2>/dev/null; then
        SUBSCRIPTION_ID="$new_subscription_id"
        TENANT_ID=$(az account show --query tenantId -o tsv)
        SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
        echo -e "${GREEN}✓ Switched to: $SUBSCRIPTION_NAME${NC}"
    else
        echo -e "${RED}✗ Invalid subscription ID${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ Using: $SUBSCRIPTION_NAME${NC}"
echo ""

# ============================================================================
# Step 1: Project Name
# ============================================================================

echo -e "${CYAN}[1/7] Project Name${NC}"
echo ""
echo "Enter a short project/application name (3-10 characters, lowercase)"
echo "This will be used for naming all Azure resources."
echo "Examples: cloudpi, myapp, webapp"
echo ""
read -p "Project name [default: cloudpi]: " PROJECT_NAME
PROJECT_NAME=${PROJECT_NAME:-cloudpi}

# Validate project name
if [[ ! $PROJECT_NAME =~ ^[a-z0-9]{3,10}$ ]]; then
    echo -e "${RED}Invalid project name. Must be 3-10 lowercase alphanumeric characters.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Project: $PROJECT_NAME${NC}"
echo ""

# Update SSH key path based on project name
SSH_KEY_PATH="$HOME/.ssh/${PROJECT_NAME}_azure.pub"

# ============================================================================
# Step 2: Environment Selection
# ============================================================================

echo -e "${CYAN}[2/7] Select Environment${NC}"
echo ""
echo "  1) dev   - Development (smaller VMs, no backup)"
echo "  2) test  - Testing (medium VMs, backup enabled)"
echo "  3) prod  - Production (full resources, backup enabled)"
echo ""
echo "Note: IP ranges are auto-assigned based on projectName + environment"
echo ""
read -p "Enter your choice (1-3): " env_choice

case $env_choice in
    1)
        ENVIRONMENT="dev"
        VM_SIZE="Standard_D2s_v3"
        ENABLE_BACKUP="false"
        BACKUP_RETENTION="7"
        DATA_DISK_SIZE="128"
        PARAM_FILE="dev.parameters.json"
        ;;
    2)
        ENVIRONMENT="test"
        VM_SIZE="Standard_D2s_v3"
        ENABLE_BACKUP="true"
        BACKUP_RETENTION="14"
        DATA_DISK_SIZE="256"
        PARAM_FILE="test.parameters.json"
        ;;
    3)
        ENVIRONMENT="prod"
        VM_SIZE="Standard_D4s_v3"
        ENABLE_BACKUP="true"
        BACKUP_RETENTION="30"
        DATA_DISK_SIZE="256"
        PARAM_FILE="parameters.json"
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        exit 1
        ;;
esac

echo -e "${GREEN}✓ Selected: $ENVIRONMENT${NC}"
echo ""

# ============================================================================
# Step 3: Auto-Shutdown Configuration (dev/test only)
# ============================================================================

if [[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "test" ]]; then
    echo -e "${CYAN}[3/7] Auto-Shutdown Configuration${NC}"
    echo ""
    echo -e "${YELLOW}Enable automatic VM shutdown at 10 PM daily?${NC}"
    echo "  - Saves costs when VM is not in use"
    echo "  - You can manually start the VM anytime from Azure Portal"
    echo "  - Recommended for dev/test environments"
    echo "  - Can save ~40-60% on compute costs"
    echo ""
    read -p "Enable auto-shutdown? (y/n): " enable_shutdown

    if [[ $enable_shutdown =~ ^[Yy]$ ]]; then
        ENABLE_AUTO_SHUTDOWN="true"
        AUTO_SHUTDOWN_TIME="2200"  # 10 PM

        echo ""
        echo -e "${CYAN}Select timezone for shutdown:${NC}"
        echo "  1) Eastern Standard Time (EST)"
        echo "  2) Central Standard Time (CST)"
        echo "  3) Pacific Standard Time (PST)"
        echo "  4) UTC"
        echo ""
        read -p "Enter your choice (1-4) [default: 1]: " tz_choice
        tz_choice=${tz_choice:-1}

        case $tz_choice in
            1) AUTO_SHUTDOWN_TIMEZONE="Eastern Standard Time" ;;
            2) AUTO_SHUTDOWN_TIMEZONE="Central Standard Time" ;;
            3) AUTO_SHUTDOWN_TIMEZONE="Pacific Standard Time" ;;
            4) AUTO_SHUTDOWN_TIMEZONE="UTC" ;;
            *) AUTO_SHUTDOWN_TIMEZONE="Eastern Standard Time" ;;
        esac

        echo -e "${GREEN}✓ Auto-shutdown enabled at 10 PM $AUTO_SHUTDOWN_TIMEZONE${NC}"
    else
        ENABLE_AUTO_SHUTDOWN="false"
        AUTO_SHUTDOWN_TIME="2200"
        AUTO_SHUTDOWN_TIMEZONE="UTC"
        echo -e "${GREEN}✓ Auto-shutdown disabled${NC}"
    fi
    echo ""
else
    # Production - auto-shutdown disabled by default
    ENABLE_AUTO_SHUTDOWN="false"
    AUTO_SHUTDOWN_TIME="2200"
    AUTO_SHUTDOWN_TIMEZONE="UTC"
fi

# ============================================================================
# Step 4: Public IP for Testing
# ============================================================================

echo -e "${CYAN}[4/7] Network Configuration${NC}"
echo ""
echo "By default, VMs have NO public IP (secure, production-ready)."
echo ""
echo -e "${YELLOW}Do you want to add a PUBLIC IP for testing?${NC}"
echo "  - Allows direct SSH from your machine"
echo "  - Can be removed later for production"
echo "  - Adds ~\$4/month cost"
echo ""
read -p "Add public IP? (y/n): " add_public_ip

if [[ $add_public_ip =~ ^[Yy]$ ]]; then
    ADD_PUBLIC_IP="true"
    echo -e "${GREEN}✓ Will add public IP for testing${NC}"
else
    ADD_PUBLIC_IP="false"
    echo -e "${GREEN}✓ No public IP (use Bastion or VPN to connect)${NC}"
fi
echo ""

# ============================================================================
# Step 5: Azure Region
# ============================================================================

echo -e "${CYAN}[5/8] Select Azure Region${NC}"
echo ""
echo "  1) eastus2       - East US 2 (recommended)"
echo "  2) centralus     - Central US"
echo "  3) westus2       - West US 2"
echo "  4) other         - Specify custom region"
echo ""
read -p "Enter your choice (1-4): " region_choice

case $region_choice in
    1) LOCATION="eastus2" ;;
    2) LOCATION="centralus" ;;
    3) LOCATION="westus2" ;;
    4)
        read -p "Enter Azure region (e.g., eastus): " LOCATION
        ;;
    *)
        echo -e "${RED}Invalid choice. Using eastus2.${NC}"
        LOCATION="eastus2"
        ;;
esac

echo -e "${GREEN}✓ Region: $LOCATION${NC}"
echo ""

# ============================================================================
# Step 6: Check SSH Key
# ============================================================================

echo -e "${CYAN}[6/8] Verifying SSH Key${NC}"
echo ""

if [ ! -f "$SSH_KEY_PATH" ]; then
    echo -e "${RED}✗ SSH key not found at $SSH_KEY_PATH${NC}"
    echo ""
    echo "Generating new SSH key..."
    ssh-keygen -t rsa -b 4096 -f "${SSH_KEY_PATH%.pub}" -N "" -C "cloudpi-azure-vm"
    echo -e "${GREEN}✓ SSH key generated${NC}"
else
    echo -e "${GREEN}✓ SSH key found${NC}"
fi

SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
echo ""

# ============================================================================
# Step 7: Deployment Summary and Confirmation
# ============================================================================

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                [7/8] Deployment Summary                        ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${CYAN}Project Name:${NC}       $PROJECT_NAME"
echo -e "  ${CYAN}Environment:${NC}        $ENVIRONMENT"
echo -e "  ${CYAN}Subscription:${NC}       $SUBSCRIPTION_NAME"
echo -e "  ${CYAN}Region:${NC}             $LOCATION"
echo -e "  ${CYAN}VM Size:${NC}            $VM_SIZE"
echo -e "  ${CYAN}Data Disk:${NC}          ${DATA_DISK_SIZE}GB"
echo -e "  ${CYAN}Backup Enabled:${NC}     $ENABLE_BACKUP"
if [ "$ENABLE_BACKUP" = "true" ]; then
    echo -e "  ${CYAN}Backup Retention:${NC}   ${BACKUP_RETENTION} days"
fi
echo -e "  ${CYAN}Auto-Shutdown:${NC}      $([[ $ENABLE_AUTO_SHUTDOWN == "true" ]] && echo "Enabled at 10 PM $AUTO_SHUTDOWN_TIMEZONE" || echo "Disabled")"
echo -e "  ${CYAN}Public IP:${NC}          $([[ $ADD_PUBLIC_IP == "true" ]] && echo "Yes (testing)" || echo "No (secure)")"
echo -e "  ${CYAN}VNet Range:${NC}         Auto-assigned (10.50-249.0.0/16)"
echo ""

# Cost estimate
if [ "$ENVIRONMENT" = "dev" ]; then
    echo -e "  ${YELLOW}Est. Monthly Cost:${NC}  ~\$90-120"
elif [ "$ENVIRONMENT" = "test" ]; then
    echo -e "  ${YELLOW}Est. Monthly Cost:${NC}  ~\$130-160"
else
    echo -e "  ${YELLOW}Est. Monthly Cost:${NC}  ~\$190-220"
fi
echo ""
echo -e "${BLUE}────────────────────────────────────────────────────────────────${NC}"
echo ""

read -p "Proceed with deployment? (yes/no): " confirm

if [[ ! $confirm =~ ^[Yy]es$ ]]; then
    echo -e "${RED}Deployment cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║              [8/8] Starting Deployment...                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

DEPLOYMENT_NAME="${PROJECT_NAME}-${ENVIRONMENT}-$(date +%Y%m%d-%H%M%S)"

# Build deployment command
DEPLOY_CMD="az deployment sub create \
  --name $DEPLOYMENT_NAME \
  --location $LOCATION \
  --template-file main.bicep \
  --parameters projectName=$PROJECT_NAME \
               environment=$ENVIRONMENT \
               location=$LOCATION \
               vmSize=$VM_SIZE \
               dataDiskSizeGB=$DATA_DISK_SIZE \
               enableBackup=$ENABLE_BACKUP \
               backupRetentionDays=$BACKUP_RETENTION \
               enableAutoShutdown=$ENABLE_AUTO_SHUTDOWN \
               autoShutdownTime=$AUTO_SHUTDOWN_TIME \
               autoShutdownTimeZone='$AUTO_SHUTDOWN_TIMEZONE' \
               adminUsername=azureadmin \
               tenantId=$TENANT_ID \
               alertEmailAddresses='[]' \
               sshPublicKey='$SSH_PUBLIC_KEY'"

echo "Deploying infrastructure..."
echo "This will take approximately 10-15 minutes..."
echo ""

# Execute deployment
if eval $DEPLOY_CMD; then
    DEPLOY_STATUS="Succeeded"
else
    DEPLOY_STATUS="Failed"
fi

echo ""

if [ "$DEPLOY_STATUS" = "Succeeded" ]; then
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              Deployment Completed Successfully!                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Get outputs
    RG_NAME=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.resourceGroupName.value -o tsv)
    VM_NAME=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.vmName.value -o tsv)
    VM_PRIVATE_IP=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.vmPrivateIpAddress.value -o tsv)

    echo -e "${CYAN}Deployment Outputs:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Resource Group:    $RG_NAME"
    echo "  VM Name:           $VM_NAME"
    echo "  Private IP:        $VM_PRIVATE_IP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Add public IP if requested
    if [ "$ADD_PUBLIC_IP" = "true" ]; then
        echo -e "${YELLOW}Adding public IP for testing...${NC}"

        az network public-ip create \
            --resource-group $RG_NAME \
            --name pip-${VM_NAME}-temp \
            --sku Standard \
            --location $LOCATION \
            --output none

        az network nic ip-config update \
            --resource-group $RG_NAME \
            --nic-name nic-${PROJECT_NAME}-app-01-${ENVIRONMENT} \
            --name ipconfig1 \
            --public-ip-address pip-${VM_NAME}-temp \
            --output none

        PUBLIC_IP=$(az network public-ip show \
            --resource-group $RG_NAME \
            --name pip-${VM_NAME}-temp \
            --query ipAddress -o tsv)

        echo -e "${GREEN}✓ Public IP added: $PUBLIC_IP${NC}"
        echo ""
        echo -e "${CYAN}SSH Connection:${NC}"
        echo "  ssh -i ~/.ssh/${PROJECT_NAME}_azure azureadmin@$PUBLIC_IP"
        echo ""
        echo -e "${YELLOW}⚠️  Remove public IP before production:${NC}"
        echo "  az network nic ip-config update \\"
        echo "    --resource-group $RG_NAME \\"
        echo "    --nic-name nic-${PROJECT_NAME}-app-01-${ENVIRONMENT} \\"
        echo "    --name ipconfig1 \\"
        echo "    --remove publicIpAddress"
        echo ""
    else
        echo -e "${CYAN}SSH Connection:${NC}"
        echo "  No public IP - use Azure Bastion, VPN, or Cloud Shell"
        echo "  Private IP: $VM_PRIVATE_IP"
        echo ""
    fi

    echo -e "${CYAN}Next Steps:${NC}"
    echo "  1. Connect to VM and verify Docker is installed"
    echo "  2. Deploy your CloudPi application"
    echo "  3. Configure Azure Cost Management export"
    echo "  4. See DEPLOYMENT.md for detailed next steps"
    echo ""

    # ============================================================================
    # Post-Deployment Health Check
    # ============================================================================

    if [ "$ADD_PUBLIC_IP" = "true" ]; then
        echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║              Running Deployment Health Check                   ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${CYAN}Waiting for cloud-init to complete...${NC}"
        echo "This may take 3-5 minutes for Docker and Azure CLI installation..."
        echo ""

        # Wait for SSH to be available first
        SSH_READY=false
        MAX_SSH_WAIT=120  # 2 minutes for SSH
        SSH_ELAPSED=0
        echo -n "Waiting for SSH"
        while [ $SSH_ELAPSED -lt $MAX_SSH_WAIT ]; do
            if ssh -i ~/.ssh/${PROJECT_NAME}_azure \
                   -o StrictHostKeyChecking=no \
                   -o ConnectTimeout=5 \
                   -o BatchMode=yes \
                   azureadmin@$PUBLIC_IP 'exit' &> /dev/null; then
                SSH_READY=true
                break
            fi
            sleep 5
            SSH_ELAPSED=$((SSH_ELAPSED + 5))
            echo -n "."
        done
        echo ""

        if [ "$SSH_READY" = "true" ]; then
            echo -e "${GREEN}✓ SSH connection established${NC}"
            echo ""

            # Wait for cloud-init to finish
            echo -n "Waiting for cloud-init to complete"
            MAX_WAIT=480  # 8 minutes for cloud-init
            ELAPSED=0
            CLOUD_INIT_DONE=false

            while [ $ELAPSED -lt $MAX_WAIT ]; do
                # Check cloud-init status
                if ssh -i ~/.ssh/${PROJECT_NAME}_azure \
                       -o StrictHostKeyChecking=no \
                       -o ConnectTimeout=10 \
                       azureadmin@$PUBLIC_IP \
                       'cloud-init status 2>/dev/null | grep -q "status: done"' 2>/dev/null; then
                    CLOUD_INIT_DONE=true
                    break
                fi
                sleep 10
                ELAPSED=$((ELAPSED + 10))
                echo -n "."
            done
            echo ""

            if [ "$CLOUD_INIT_DONE" = "true" ]; then
                echo -e "${GREEN}✓ cloud-init completed${NC}"
                echo ""

                # Display health check results
                echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${BLUE}║            Deployment Health Check Results                     ║${NC}"
                echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
                echo ""

                # Fetch and display the health check log
                if ssh -i ~/.ssh/${PROJECT_NAME}_azure \
                       -o StrictHostKeyChecking=no \
                       azureadmin@$PUBLIC_IP \
                       'cat /var/log/cloudpi-deployment-health.log' 2>/dev/null; then
                    echo ""
                else
                    echo -e "${YELLOW}⚠️  Health check log not available yet${NC}"
                    echo "You can check it manually with:"
                    echo "  ssh -i ~/.ssh/${PROJECT_NAME}_azure azureadmin@$PUBLIC_IP 'cat /var/log/cloudpi-deployment-health.log'"
                    echo ""
                fi
            else
                echo -e "${YELLOW}⚠️  cloud-init still running (timeout after ${MAX_WAIT}s)${NC}"
                echo ""
                echo "Your VM is deployed but cloud-init is still configuring."
                echo "You can check cloud-init status with:"
                echo "  ssh -i ~/.ssh/${PROJECT_NAME}_azure azureadmin@$PUBLIC_IP 'cloud-init status --wait'"
                echo ""
                echo "Once complete, view the health check:"
                echo "  ssh -i ~/.ssh/${PROJECT_NAME}_azure azureadmin@$PUBLIC_IP 'cat /var/log/cloudpi-deployment-health.log'"
                echo ""
            fi
        else
            echo -e "${YELLOW}⚠️  Could not establish SSH connection${NC}"
            echo ""
            echo "Your VM is deployed but SSH is not responding yet."
            echo "Wait a few minutes and connect manually:"
            echo "  ssh -i ~/.ssh/${PROJECT_NAME}_azure azureadmin@$PUBLIC_IP"
            echo ""
            echo "Then view the health check:"
            echo "  cat /var/log/cloudpi-deployment-health.log"
            echo ""
        fi
    else
        echo -e "${CYAN}No public IP configured - Health check available via:${NC}"
        echo "  1. Connect via Azure Bastion or VPN"
        echo "  2. SSH to private IP: $VM_PRIVATE_IP"
        echo "  3. Run: cat /var/log/cloudpi-deployment-health.log"
        echo ""
    fi

else
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                    Deployment Failed!                          ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Check deployment details:"
    echo "  az deployment sub show --name $DEPLOYMENT_NAME"
    echo ""
    exit 1
fi
