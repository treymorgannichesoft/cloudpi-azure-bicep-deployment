# CloudPi Infrastructure Deployment Guide

Complete guide for deploying CloudPi infrastructure to Azure using Bicep templates.

## Table of Contents
- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [What Gets Deployed](#what-gets-deployed)
- [Deployment Methods](#deployment-methods)
- [Post-Deployment Configuration](#post-deployment-configuration)
- [Validation](#validation)
- [Troubleshooting](#troubleshooting)
- [Clean Up](#clean-up)

## Quick Start

**TL;DR - Deploy in 2 steps:**

```bash
# 1. Login to Azure
az login

# 2. Run interactive deployment
./deploy-interactive.sh
```

The script will:
- **Auto-detect** your Azure subscription and tenant
- **Prompt for project name** (default: "cloudpi") - used for naming all resources
- **Guide you through** environment selection (dev/test/prod), network config, and region
- **Deploy infrastructure** in ~10-15 minutes

> **Note:** All resources are named using the pattern `{resourceType}-{projectName}-{environment}`
> Example: If projectName=myapp and environment=dev → Resource group: `rg-myapp-dev`

## Prerequisites

### Required Tools
- **Azure CLI** 2.50.0 or later
- **Bicep CLI** 0.20.0 or later
- **SSH key pair** for VM access
- **Azure permissions**: Owner or Contributor role on subscription

### Install/Update Tools

```bash
# Update Azure CLI
az upgrade

# Update Bicep
az bicep upgrade

# Verify versions
az --version
az bicep version
```

### Generate SSH Key (if needed)

```bash
# Generate SSH key pair
ssh-keygen -t rsa -b 4096 -f ~/.ssh/cloudpi_azure -C "cloudpi-azure-vm"

# View public key
cat ~/.ssh/cloudpi_azure.pub
```

The interactive deployment script will automatically use `~/.ssh/cloudpi_azure.pub` or generate one if it doesn't exist.

## What Gets Deployed

### Infrastructure Components by Environment

| Environment | VM Size | Data Disk | Backup | Est. Monthly Cost |
|-------------|---------|-----------|--------|-------------------|
| **dev** | Standard_D2s_v3 (2 vCPU, 8GB) | 128GB | No | ~$90-120 |
| **test** | Standard_D2s_v3 (2 vCPU, 8GB) | 256GB | 14-day | ~$130-160 |
| **prod** | Standard_D4s_v3 (4 vCPU, 16GB) | 256GB | 30-day | ~$190-220 |

### Resources Created (All Environments)

All resources use parameterized naming with `{projectName}` (default: "cloudpi"):

| Category | Resources | Details |
|----------|-----------|---------|
| **Management** | Resource Group | `rg-{projectName}-{env}` (e.g., rg-cloudpi-dev) |
| **Networking** | VNet, Subnet, NSG | Auto-assigned IP ranges per environment |
| **Compute** | Ubuntu 22.04 VM | Docker pre-installed via cloud-init |
| **Storage** | Storage Account | 3 containers: billing-exports, mysql-backups, app-data |
| **Security** | Key Vault, Managed Identity | RBAC-based access, passwordless auth |
| **Monitoring** | Log Analytics, Alerts | Performance counters, syslog collection |
| **Backup** | Recovery Services Vault | Daily backups (if enabled) |

**Total**: 13+ Azure resources per environment

### Network IP Ranges (Automatic Assignment)

**Conflict-Free IP Generation:** Each unique `projectName + environment` combination automatically gets a unique IP range.

#### Examples:

| Project Name | Environment | VNet Range | App Subnet | Status |
|--------------|-------------|------------|------------|--------|
| cloudpi | dev | 10.x.0.0/16 | 10.x.1.0/24 | Auto-generated |
| myapp | dev | 10.y.0.0/16 | 10.y.1.0/24 | ✅ No conflict! |
| cloudpi | prod | 10.z.0.0/16 | 10.z.1.0/24 | Auto-generated |
| webapp | test | 10.w.0.0/16 | 10.w.1.0/24 | Auto-generated |

> **Note:** The actual third octet (x, y, z, w) is deterministically calculated from the hash of `projectName + environment`.
> Same input always produces the same IP range.

### Network Strategy Details

The Bicep template uses **hash-based IP generation** to automatically assign non-overlapping IP ranges, preventing conflicts when multiple projects are deployed in the same subscription.

#### How It Works:

The template calculates a unique third octet from `projectName + environment` in `main.bicep`:

```bicep
// Calculate unique third octet (50-249) from projectName + environment hash
var hashString = uniqueString(projectName, environment)
var hashValue = (length(hashString) * 17 + length(projectName) * 13 + length(environment) * 7)
var calculateIpOctet = string((hashValue % 200) + 50)

// Generate IP ranges based on calculated octet
var autoVnetPrefix = '10.${calculateIpOctet}.0.0/16'
var autoAppSubnetPrefix = '10.${calculateIpOctet}.1.0/24'

// Use provided values if specified, otherwise use auto-calculated values
var actualVnetAddressPrefix = !empty(vnetAddressPrefix) ? vnetAddressPrefix : autoVnetPrefix
var actualAppSubnetPrefix = !empty(appSubnetPrefix) ? appSubnetPrefix : autoAppSubnetPrefix
```

**How this prevents conflicts:**
- Each unique `projectName + environment` combination produces a unique third octet (50-249)
- Example: `cloudpi-dev` might get `10.87.0.0/16`, while `myapp-dev` gets `10.142.0.0/16`
- Deterministic: Same input always produces same output
- Supports up to 200 unique project/environment combinations

**Manual Override:**

You can still specify custom IP ranges if needed for enterprise IP planning:

```bash
az deployment sub create \
  --template-file main.bicep \
  --parameters projectName=myapp \
               environment=prod \
               vnetAddressPrefix='10.200.0.0/16' \
               appSubnetPrefix='10.200.1.0/24'
```

**Benefits:**
- ✅ No IP conflicts between projects in same subscription
- ✅ No IP conflicts between environments in same project
- ✅ VNet peering ready - can peer multiple projects to hub VNet without conflicts
- ✅ Automatic conflict avoidance - no manual IP planning required
- ✅ Flexible - supports manual override for enterprise requirements

**VNet Peering Example:**

Once you have multiple environments deployed, you can peer them to a hub VNet:

```bash
# Peer prod to hub VNet
az network vnet peering create \
  --name prod-to-hub \
  --resource-group rg-cloudpi-prod \
  --vnet-name vnet-cloudpi-spoke-prod \
  --remote-vnet <HUB_VNET_ID> \
  --allow-vnet-access \
  --allow-forwarded-traffic
```

**Verify Assigned IP Ranges:**

```bash
# List all VNets with their auto-assigned ranges
az network vnet list \
  --query "[?contains(name,'cloudpi')].{Name:name, RG:resourceGroup, Range:addressSpace.addressPrefixes[0]}" \
  --output table

# Example output (assuming projectName=cloudpi):
# Name                     RG               Range
# vnet-cloudpi-spoke-dev   rg-cloudpi-dev   10.87.0.0/16   (auto-assigned)
# vnet-cloudpi-spoke-test  rg-cloudpi-test  10.142.0.0/16  (auto-assigned)
# vnet-cloudpi-spoke-prod  rg-cloudpi-prod  10.203.0.0/16  (auto-assigned)
#
# Note: Each projectName+environment combination gets a unique /16 range in 10.50-249.0.0/16

# Check specific deployment to see what IP was assigned
az deployment sub show --name cloudpi-prod-20251202-120000 \
  --query "properties.outputs.{VNet:vnetName.value, PrivateIP:vmPrivateIpAddress.value}"
```

### Key Features

- **Zero-Trust Security**: No public IPs by default, NSG-based access control
- **Managed Identity**: Passwordless authentication to Azure services
- **Automated Monitoring**: Performance metrics and syslog collection
- **Docker Ready**: VM pre-configured with Docker and Docker Compose
- **Cost Optimization**: Lifecycle policies for automatic data archival
- **Multi-Environment**: Deploy dev, test, prod with automatic IP isolation

## Deployment Methods

### Method 1: Interactive Deployment (Recommended)

The interactive script provides a user-friendly deployment experience.

```bash
./deploy-interactive.sh
```

**What it does:**
1. Prompts for environment selection (dev/test/prod)
2. Asks if you want a public IP for testing
3. Lets you select Azure region
4. Shows deployment summary with cost estimates
5. Deploys infrastructure with automatic IP assignment
6. Optionally adds public IP after deployment

**Typical session:**
```
[1/6] Select Environment
  1) dev   - Development (smaller VMs, no backup, auto-assigned IP)
  2) test  - Testing (medium VMs, backup enabled, auto-assigned IP)
  3) prod  - Production (full resources, backup enabled, auto-assigned IP)

Enter your choice (1-3): 3

[2/6] Network Configuration
Add public IP for testing? (y/n): n

[3/6] Select Azure Region
  1) eastus2       - East US 2 (recommended)
  2) centralus     - Central US
  3) westus2       - West US 2

Enter your choice (1-3): 1

... deployment proceeds ...
```

### Method 2: Direct Deployment with Parameter Files

Use pre-configured parameter files for each environment:

```bash
# Login to Azure
az login
az account set --subscription "2e0bf2f9-61df-4a48-804f-44997bc3c22b"

# Deploy production environment
az deployment sub create \
  --name cloudpi-prod-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @parameters.json

# Deploy test environment
az deployment sub create \
  --name cloudpi-test-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @test.parameters.json

# Deploy dev environment
az deployment sub create \
  --name cloudpi-dev-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @dev.parameters.json
```

### Method 3: Custom Deployment

For custom configurations, create your own parameter file:

```bash
# Copy an example parameter file
cp parameters.json my-custom.parameters.json

# Edit with your values
nano my-custom.parameters.json

# Deploy
az deployment sub create \
  --name cloudpi-custom-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @my-custom.parameters.json
```

### Preview Changes Before Deployment

Use `--what-if` to preview changes without deploying:

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @parameters.json \
  --what-if
```

## Deployment Time

Expected deployment time: **10-15 minutes**

Breakdown:
- Resource group creation: 1 min
- Networking setup: 2-3 min
- VM provisioning: 5-7 min
- Docker installation via cloud-init: 2-3 min
- Monitoring agent installation: 1-2 min
- Backup configuration: 1 min

## Post-Deployment Configuration

### 1. Retrieve Deployment Information

```bash
# Set deployment name (use the name from your deployment)
DEPLOYMENT_NAME="cloudpi-prod-20251116-120000"

# Get all outputs
az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs

# Get specific values
RG_NAME=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.resourceGroupName.value -o tsv)
VM_NAME=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.vmName.value -o tsv)
VM_IP=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.vmPrivateIpAddress.value -o tsv)
STORAGE=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.storageAccountName.value -o tsv)
KV_URI=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.keyVaultUri.value -o tsv)

echo "Resource Group: $RG_NAME"
echo "VM Name: $VM_NAME"
echo "VM IP: $VM_IP"
echo "Storage Account: $STORAGE"
echo "Key Vault: $KV_URI"
```

### 2. Connect to the VM

**Option A: Using Public IP (if added during deployment)**

```bash
# Get public IP
PUBLIC_IP=$(az network public-ip show \
  --resource-group $RG_NAME \
  --name pip-${VM_NAME}-temp \
  --query ipAddress -o tsv)

# SSH to VM
ssh -i ~/.ssh/cloudpi_azure azureadmin@$PUBLIC_IP
```

**Option B: Using Azure Bastion or VPN**

```bash
# Connect via private IP (requires VPN or Bastion)
ssh -i ~/.ssh/cloudpi_azure azureadmin@$VM_IP
```

**Option C: Add Public IP After Deployment**

```bash
# Create public IP
az network public-ip create \
  --resource-group $RG_NAME \
  --name pip-${VM_NAME}-temp \
  --sku Standard \
  --location eastus2

# Attach to NIC
az network nic ip-config update \
  --resource-group $RG_NAME \
  --nic-name nic-cloudpi-app-01-prod \
  --name ipconfig1 \
  --public-ip-address pip-${VM_NAME}-temp
```

### 3. Review Automatic Health Check Results

**If you used the interactive deployment script (`./deploy-interactive.sh`):**

The health check results are automatically displayed in your terminal after deployment completes. The script:
- Waits for cloud-init to finish (3-5 minutes)
- SSHs to the VM and retrieves health check results
- Displays all 10 validation checks

**For manual deployments or to re-check:**

```bash
# SSH to the VM
ssh -i ~/.ssh/cloudpi_azure azureadmin@$VM_IP

# View health check results
cat /var/log/cloudpi-deployment-health.log
```

Expected output:
```
========================================
CloudPi Deployment Health Check
========================================
[1/10] Checking Docker installation...
  ✅ Docker installed: Docker version 29.1.2
[2/10] Checking Docker service...
  ✅ Docker service is running
[3/10] Checking Docker data-root...
  ✅ Docker using data disk: /datadisk/docker
[4/10] Checking data disk mount...
  ✅ Data disk mounted: 126G total, 120G available
[5/10] Checking systemd mount unit...
  ✅ systemd mount unit enabled (will auto-mount on reboot)
[6/10] Checking Azure CLI...
  ✅ Azure CLI installed
[7/10] Checking CloudPi directories...
  ✅ /datadisk/mysql exists (owner: azureadmin:azureadmin)
  ✅ /datadisk/app exists (owner: azureadmin:azureadmin)
  ✅ /datadisk/logs exists (owner: azureadmin:azureadmin)
  ✅ /datadisk/backups exists (owner: azureadmin:azureadmin)
  ✅ /datadisk/docker exists (owner: root:root)
[8/10] Checking managed identity...
  ✅ Managed identity authentication successful
[9/10] Checking Key Vault access...
  ✅ Key Vault accessible: kv-cloudpit19-dev-mfcrmz
[10/10] Checking disk space...
  ✅ Data disk usage: 1%

========================================
✅ ALL CHECKS PASSED - Deployment Successful!

Your CloudPi VM is ready to use.
========================================
```

**Additional health check logs:**
- `/var/log/cloudpi-disk-setup.log` - Data disk setup details
- `/var/log/cloud-init-output.log` - Full cloud-init execution log

### 4. Verify VM Setup (Manual Verification)

Once connected to the VM, you can manually verify the setup:

```bash
# Check Docker installation
docker --version
docker compose version

# Verify Docker is running
sudo systemctl status docker

# Check data disk is mounted at /datadisk
df -h | grep datadisk
# Should show: /dev/sdc1  126G  224K  120G   1% /datadisk

# Verify systemd mount unit
systemctl status datadisk.mount
# Should show: active (mounted)

# Verify Docker using data disk
docker info | grep "Docker Root Dir"
# Should show: /datadisk/docker

# View directory structure
ls -la /datadisk/
```

Expected output:
```
/datadisk/
├── mysql/      # MySQL data directory
├── app/        # Application data
├── logs/       # Application logs
├── backups/    # Local backup staging
└── docker/     # Docker data-root
```

### 4. Configure Azure Cost Management Export (Optional)

A storage account is deployed with your infrastructure. While not required by the CloudPi application, you can optionally use it to store Azure cost exports for billing analysis.

**To set up automatic billing exports:**

1. Go to **Azure Portal** > **Cost Management + Billing**
2. Select your subscription
3. Click **Exports** under Cost Management
4. Click **+ Add** to create new export
5. Configure:
   - Name: `cloudpi-billing-export`
   - Export type: Daily export of month-to-date costs
   - Storage account: Select deployed storage account (e.g., `stcloudpiprodapps`)
   - Container: `billing-exports`
   - Directory: `azure-cost-data`
6. Click **Create**

> **Note**: The storage account is provisioned for optional customer use. The CloudPi application does not require it.

### 5. Deploy CloudPi Application

Once the infrastructure is deployed and verified, you're ready to deploy your CloudPi application.

**Next Steps:**
1. Clone your CloudPi application repository (contains docker-compose.yml and application code)
2. Follow the application-specific deployment instructions in that repository
3. The infrastructure provides:
   - Docker and Docker Compose pre-installed
   - Data disk mounted at `/datadisk` with subdirectories: `mysql/`, `app/`, `logs/`, `backups/`, `docker/`
   - Proper permissions for your admin user
   - Key Vault for secrets management (accessible via managed identity)
   - Storage account for backups and data

**Infrastructure is ready for your application!**

### 6. Azure Key Vault

A Key Vault is deployed with your infrastructure for secure secrets management. The VM has a **Managed Identity** with "Key Vault Secrets User" role for passwordless access.

**What's Configured:**
- Key Vault deployed with soft-delete and purge protection
- VM managed identity has access to read secrets
- Health checks verify Key Vault connectivity

**Get Your Key Vault Information:**

```bash
# From deployment outputs
az deployment sub show --name <deployment-name> \
  --query properties.outputs.keyVaultUri.value -o tsv

# Example output: https://kv-cloudpi-prod-bhrlr4.vault.azure.net/
```

**Secret Management:**

Your CloudPi application repository includes a Key Vault setup script that handles all secret configuration and retrieval. Refer to your application documentation for secret management instructions.

## Validation

### Verify All Resources Deployed

```bash
# List all resources in the resource group
az resource list \
  --resource-group $RG_NAME \
  --output table

# Expected count: 13+ resources
az resource list \
  --resource-group $RG_NAME \
  --query "length(@)"
```

### Verify Managed Identity Access

```bash
# Check VM managed identity has proper roles
PRINCIPAL_ID=$(az vm show \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --query identity.principalId -o tsv)

az role assignment list \
  --assignee $PRINCIPAL_ID \
  --output table

# Test from within VM
ssh -i ~/.ssh/cloudpi_azure azureadmin@$VM_IP

# On the VM:
az login --identity
az storage account list --query "[].name"  # Should work
az keyvault secret list --vault-name kv-cloudpi-prod  # Should work
```

### Verify Backup Configuration

```bash
# Check if backup is configured
az backup protection check-vm \
  --resource-group $RG_NAME \
  --vm $VM_NAME \
  --vault-name rsv-cloudpi-prod

# View backup policy
az backup policy show \
  --resource-group $RG_NAME \
  --vault-name rsv-cloudpi-prod \
  --name DailyBackupPolicy
```

### Verify Monitoring

```bash
# Check Azure Monitor Agent is installed
az vm extension list \
  --resource-group $RG_NAME \
  --vm-name $VM_NAME \
  --query "[?name=='AzureMonitorLinuxAgent']"

# Query Log Analytics (wait 5-10 minutes after deployment)
az monitor log-analytics query \
  --workspace $(az deployment sub show \
    --name $DEPLOYMENT_NAME \
    --query properties.outputs.logAnalyticsWorkspaceId.value -o tsv) \
  --analytics-query "Heartbeat | where Computer contains 'cloudpi' | summarize count() by Computer" \
  --timespan P1D
```

## Troubleshooting

### Deployment Failures

**Issue**: "Resource name already exists"

```bash
# Check if resources exist from previous deployment
# Replace {projectName} and {env} with your values
az resource list --resource-group rg-{projectName}-{env} --output table

# Example with default naming:
az resource list --resource-group rg-cloudpi-prod --output table

# Delete resource group and retry
az group delete --name rg-{projectName}-{env} --yes
```

**Issue**: "SkuNotAvailable - VM size not available in region"

```bash
# Check available VM sizes in your region
az vm list-skus --location eastus2 --size Standard_D --output table

# Try a different region or VM size
```

**Issue**: "VaultAlreadyExists - Key Vault name in use"

This happens when a Key Vault was recently deleted (soft-delete protection):

```bash
# Option 1: Purge the soft-deleted vault
az keyvault purge --name kv-cloudpi-prod

# Option 2: Use a different environment name
# Edit your parameter file to change environment from "prod" to "production"
```

### Network Connectivity Issues

**Issue**: Cannot SSH to VM

```bash
# Check NSG rules
az network nsg rule list \
  --resource-group $RG_NAME \
  --nsg-name nsg-cloudpi-app-prod \
  --output table

# Verify VM has no public IP (expected)
az vm show -d \
  --resource-group $RG_NAME \
  --name $VM_NAME \
  --query publicIps -o tsv

# Add public IP if needed (see Post-Deployment section)
```

**Issue**: Public IP not accessible

```bash
# Check if NSG allows your IP
az network nsg rule show \
  --resource-group $RG_NAME \
  --nsg-name nsg-cloudpi-app-prod \
  --name Allow-SSH-Inbound

# Update source addresses if needed
```

### Docker Issues

**Issue**: Docker not installed

```bash
# Check cloud-init logs on VM
ssh -i ~/.ssh/cloudpi_azure azureadmin@$VM_IP
sudo cat /var/log/cloud-init-output.log

# Manually install Docker if needed
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

**Issue**: Data disk not mounted

```bash
# Check disk status
lsblk

# Check systemd mount unit status
systemctl status datadisk.mount

# Mount manually if needed (if filesystem exists)
sudo mount /dev/sdc /datadisk

# Or create filesystem if needed (WARNING: destroys existing data)
sudo mkfs.ext4 /dev/sdc
sudo mkdir -p /datadisk
sudo mount /dev/sdc /datadisk
```

### Managed Identity Issues

**Issue**: VM cannot access storage or Key Vault

```bash
# Verify role assignments
az role assignment list \
  --assignee $PRINCIPAL_ID \
  --output table

# Manually assign if missing
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $PRINCIPAL_ID \
  --scope $(az storage account show --name $STORAGE --query id -o tsv)

az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee $PRINCIPAL_ID \
  --scope $(az keyvault show --name kv-cloudpi-prod --query id -o tsv)
```

### Monitoring Issues

**Issue**: No data in Log Analytics

```bash
# Check Data Collection Rule association
az monitor data-collection rule association list \
  --resource $(az vm show --resource-group $RG_NAME --name $VM_NAME --query id -o tsv)

# Restart Azure Monitor Agent
ssh -i ~/.ssh/cloudpi_azure azureadmin@$VM_IP
sudo systemctl restart azuremonitoragent
```

## Clean Up

### Remove Public IP (Production)

If you added a public IP for testing, remove it before production:

```bash
az network nic ip-config update \
  --resource-group $RG_NAME \
  --nic-name nic-cloudpi-app-01-prod \
  --name ipconfig1 \
  --remove publicIpAddress

az network public-ip delete \
  --resource-group $RG_NAME \
  --name pip-${VM_NAME}-temp
```

### Delete Entire Environment

To delete all resources and stop charges:

```bash
# Delete resource group (deletes everything inside)
az group delete \
  --name $RG_NAME \
  --yes \
  --no-wait

# Verify deletion (after a few minutes)
az group show --name $RG_NAME
```

### Purge Key Vault (Complete Cleanup)

Key Vaults have soft-delete enabled. To completely remove:

```bash
# List soft-deleted vaults
az keyvault list-deleted

# Purge specific vault
az keyvault purge --name kv-cloudpi-prod
```

## Cost Optimization Tips

1. **Stop VMs when not in use** (dev/test environments)
   ```bash
   az vm deallocate --resource-group $RG_NAME --name $VM_NAME
   az vm start --resource-group $RG_NAME --name $VM_NAME
   ```

2. **Use smaller VM sizes** for dev/test
   - Dev: Standard_D2s_v3 instead of D4s_v3

3. **Disable backups** for dev environments
   - Set `enableBackup: false` in parameter file

4. **Review storage lifecycle policies**
   - Automatic data archival is configured
   - Adjust retention as needed

5. **Set up budget alerts**
   ```bash
   # Create budget in Azure Portal
   # Cost Management + Billing > Budgets
   ```

## Additional Resources

- [README.md](README.md) - Project overview
- [Docs/Instructions.md](Docs/Instructions.md) - Infrastructure requirements
- [Azure Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Monitor for VMs](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-overview)

## Support

For issues or questions:
1. Check this troubleshooting section
2. Review Azure Activity Logs in portal
3. Check deployment error messages
4. Contact: trey.morgan@nichesoft.ai

---

**Ready to deploy?** Run `./deploy-interactive.sh` to get started!
