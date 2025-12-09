# CloudPi Azure Infrastructure

Infrastructure as Code for deploying CloudPi production environment on Azure using Bicep templates.

## Overview

This repository contains modular Bicep templates to deploy a complete production-ready infrastructure for the CloudPi application, including networking, compute, storage, security, and monitoring components.

## Quick Start

```bash
# Login to Azure
az login

# Run interactive deployment
./deploy-interactive.sh
```

The interactive script will guide you through 8 steps:
1. **Azure Login Verification** - Auto-detects your subscription and tenant
2. **Project Name** - Short name for resource naming (3-10 characters)
3. **Environment Selection** - Choose dev/test/prod with pre-configured settings
4. **Auto-Shutdown** - Optional scheduled shutdown for dev/test cost savings
5. **Network Configuration** - Option to add temporary public IP for testing
6. **Azure Region** - Select deployment region
7. **SSH Key** - Auto-generates if not found
8. **Deployment Summary** - Review and confirm before deployment

**After deployment (~10-15 minutes), the script automatically:**
- Waits for cloud-init to complete (3-5 minutes)
- Runs 10 comprehensive health checks
- Displays validation results in your terminal
- Provides SSH connection details

For detailed instructions, see [DEPLOYMENT.md](DEPLOYMENT.md).

## Project Structure

```
CloudPi_01/
├── main.bicep                    # Main orchestration template
├── main.bicepparam               # Default parameter file
├── parameters.json               # Production parameters
├── test.parameters.json          # Test environment parameters
├── dev.parameters.json           # Dev environment parameters
├── deploy-interactive.sh         # Interactive deployment script
├── DEPLOYMENT.md                 # Comprehensive deployment guide
├── README.md                     # This file
└── modules/
    ├── networking.bicep          # VNet, subnets, NSG
    ├── storage.bicep             # Storage account and containers
    ├── security.bicep            # Key Vault
    ├── compute.bicep             # VM with Docker and monitoring
    ├── monitoring.bicep          # Log Analytics, alerts, backup
    └── roleAssignments.bicep     # RBAC permissions
```

## What Gets Deployed

### Infrastructure Components

| Category | Resources | Purpose |
|----------|-----------|---------|
| **Management** | Resource Group | Container for all resources |
| **Networking** | VNet, Subnet, NSG | Network isolation with auto-assigned IP ranges |
| **Compute** | Ubuntu 22.04 VM | Application server with Docker pre-installed |
| **Storage** | Storage Account | Optional: Azure cost exports for billing analysis |
| **Security** | Key Vault, Managed Identity | Secrets management and passwordless auth |
| **Monitoring** | Log Analytics, Alerts | Centralized logging and performance metrics |
| **Backup** | Recovery Services Vault | Daily VM backups (configurable) |

**Total**: 13+ Azure resources per environment

### Multi-Environment Support

**Automatic IP range assignment** prevents conflicts when deploying multiple projects:
- IP ranges are **auto-generated** from `projectName + environment` hash
- Each unique combination gets a **deterministic, conflict-free** IP range
- Range: `10.50-249.x.x/16` (200 possible unique networks)
- **Manual override** supported for enterprise IP planning
- **Note**: Hash calculation uses string lengths; while collisions are rare, verify IP assignments don't conflict with existing networks

| Environment | VM Size | Data Disk | Backup | IP Assignment | Est. Monthly |
|-------------|---------|-----------|--------|---------------|--------------|
| **dev** | D2s_v3 | 128GB | No | Auto (10.x.0.0/16) | ~$90-120 |
| **test** | D2s_v3 | 256GB | 14-day | Auto (10.y.0.0/16) | ~$130-160 |
| **prod** | D4s_v3 | 256GB | 30-day | Auto (10.z.0.0/16) | ~$190-220 |

> **Example:** `cloudpi-dev` and `myapp-dev` get different IP ranges automatically

See [DEPLOYMENT.md](DEPLOYMENT.md#network-strategy-details) for detailed network information.

## Advanced Features

### Temporary Public IP for Testing

The interactive deployment script offers an **optional temporary public IP** for testing:

**How it works:**
- The Bicep templates do NOT create public IPs (secure by default)
- The deployment script offers to add a public IP **after** deployment using Azure CLI
- Created as `pip-{vmname}-temp` for easy identification
- Script provides SSH connection string and removal instructions

**When to use:**
- ✅ Testing and initial setup without VPN/Bastion infrastructure
- ✅ Development environments for quick access
- ✅ Learning and experimentation

**Security warnings:**
- ⚠️ Script displays clear warnings to remove before production
- ⚠️ Public IP exposes SSH port to internet (protected by NSG rules)
- ⚠️ Recommendation: Remove immediately after testing

**To remove public IP:**
```bash
VM_NAME="vm-cloudpi-app-01-dev"
RG_NAME="rg-cloudpi-dev"

az network nic ip-config update \
  --resource-group $RG_NAME \
  --nic-name nic-${VM_NAME} \
  --name ipconfig1 \
  --remove publicIpAddress

az network public-ip delete \
  --resource-group $RG_NAME \
  --name pip-${VM_NAME}-temp
```

### Auto-Shutdown for Cost Savings

The template includes optional auto-shutdown functionality for dev/test environments:

```bicep
enableAutoShutdown: true
autoShutdownTime: '2200'              // 24-hour format (e.g., 2200 = 10 PM)
autoShutdownTimeZone: 'Eastern Standard Time'
autoShutdownNotificationEmail: 'admin@example.com'  // Optional email notification
```

**Benefits:**
- Automatically shuts down VMs during non-working hours
- Reduces costs by up to 70% for dev/test environments
- Configurable timezone and notification settings
- 30-minute warning email before shutdown (if configured)

**Recommended for:** Development and test environments
**Not recommended for:** Production workloads requiring 24/7 availability

### Cloud-Init Health Checks

All VMs include comprehensive post-deployment validation that runs automatically during provisioning.

**Automated Checks (10 validations):**
1. Docker installation and version
2. Docker service status
3. Docker data-root configuration on data disk (`/datadisk/docker`)
4. Data disk mount at `/datadisk` (126GB persistent storage)
5. Systemd mount unit enabled for boot persistence (`datadisk.mount`)
6. Azure CLI installation
7. CloudPi directory structure and permissions at `/datadisk`
8. Managed identity authentication
9. Key Vault access verification with actual vault name
10. Disk space usage monitoring

**Interactive Deployment Display:**
When using `./deploy-interactive.sh`, the script automatically:
- Waits for cloud-init to complete
- SSHs to the VM and retrieves health check results
- Displays all 10 validation checks in your terminal
- Shows ✅ for passed checks and ❌ for failures

**Log Files:**
- `/var/log/cloudpi-deployment-health.log` - Complete health check results
- `/var/log/cloudpi-disk-setup.log` - Data disk setup details
- `/var/log/cloud-init-output.log` - Full cloud-init execution log

**Health Check Output Example:**
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
You can now run: docker compose up -d
========================================
```

### Data Disk Management

The template automatically configures persistent data disk mounting at `/datadisk`:

**Features:**
- **Industry-standard mount point:** `/datadisk` (Azure recommended practice)
- **UUID-based systemd mount units** (survives disk reattachment and device name changes)
- **Automatic filesystem detection** and reuse on redeployment
- **Safety checks** prevent accidental OS disk formatting
- **Docker data-root** configured on data disk (`/datadisk/docker`)
- **Pre-created directory structure** at `/datadisk`: `mysql/`, `app/`, `logs/`, `backups/`, `docker/`
- **Proper ownership** and permissions for admin user
- **Independent of ephemeral disk** - No conflicts with Azure's `/mnt` ephemeral storage

**Benefits:**
- Data persists across VM deletions/recreations
- Systemd ensures reliable automatic mounting on boot
- No systemd ordering conflicts with Azure's ephemeral disk
- Docker storage separated from OS disk for performance
- Comprehensive logging for troubleshooting
- Boot persistence guaranteed (no dependency cycles)

## Key Features

- **Flexible Naming**: Parameterized project naming for multi-tenant/multi-project deployments
- **Auto-Detection**: Automatically detects Azure subscription and tenant context
- **Network Security**: NSG-based access control with no public IPs on VMs
- **Managed Identity**: Passwordless authentication to Azure services
- **Automated Monitoring**: Performance metrics and syslog collection via Azure Monitor
- **Automated Backups**: Daily VM backups with configurable retention
- **Auto-Shutdown**: Optional scheduled VM shutdown for dev/test cost savings
- **Docker Ready**: VM pre-configured with Docker and Docker Compose
- **Health Checks**: Comprehensive cloud-init validation with detailed logging
- **Cost Optimization**: Lifecycle policies for automatic data archival
- **Multi-Environment**: Isolated dev, test, prod with automatic IP assignment

## Prerequisites

- **Azure CLI** 2.50.0 or later
- **Bicep CLI** 0.20.0 or later
- **SSH key pair** for VM access
- **Azure permissions**: Owner or Contributor role on subscription

## Deployment Options

### Option 1: Interactive Deployment (Recommended)

```bash
./deploy-interactive.sh
```

Guides you through:
- Azure subscription verification (auto-detected)
- Project name for resource naming
- Environment selection (dev/test/prod)
- **Public IP option** for testing environments (added post-deployment via Azure CLI)
- Azure region selection
- Deployment summary with cost estimates

### Option 2: Direct Deployment with Parameter Files

```bash
# Deploy production
az deployment sub create \
  --name cloudpi-prod-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @parameters.json

# Deploy test
az deployment sub create \
  --name cloudpi-test-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @test.parameters.json

# Deploy dev
az deployment sub create \
  --name cloudpi-dev-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @dev.parameters.json
```

### Option 3: Preview Before Deployment

```bash
# Use --what-if to preview changes
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @parameters.json \
  --what-if
```

## Architecture Highlights

### Networking
- Hub-spoke topology ready (peering not included)
- Automatic non-overlapping IP ranges per environment
- NSG with least-privilege access rules
- Service tags for Azure service connectivity

### Security
- RBAC-based access control
- System-assigned managed identity
- Soft-delete and purge protection on Key Vault
- Encrypted storage and disks (platform-managed keys)
- No public IPs on VMs
- **Note**: Storage and Key Vault use public endpoints with network ACLs set to Allow; consider implementing private endpoints for production workloads

### High Availability & DR
- Daily automated backups (configurable)
- Premium SSD for performance
- Lifecycle policies for cost optimization
- Data disk auto-mounted at `/datadisk` with systemd for boot persistence

### Monitoring
- Azure Monitor Agent for metrics and logs
- Performance counters: CPU, memory, disk, network
- Syslog collection for system events (auth, daemon, kern, cron)
- Email alerts for critical issues
- Log Analytics workspace with data collection rules
- 60-second sampling interval for performance metrics
- **Note**: Performance counter paths use Windows notation; verify metrics are collecting correctly for Linux VMs in Log Analytics

## Post-Deployment Tasks

After successful deployment:

1. **Review Health Check Results** - Interactive deployment automatically displays validation results in your terminal
2. **Connect to VM** - Use private IP via VPN/ExpressRoute, Azure Bastion, or temporary public IP (if added during interactive deployment)
3. **Verify Docker** - Docker and Docker Compose pre-installed via cloud-init with data-root on `/datadisk/docker`
4. **Verify Data Disk Mount** - Confirm `/datadisk` is mounted with systemd mount unit enabled (`datadisk.mount`)
5. **Deploy Application** - Clone your CloudPi application repository and follow deployment instructions
6. **(Optional) Configure Cost Export** - Set up Azure Cost Management export to storage account for billing analysis
7. **Test Monitoring** - Verify metrics and logs in Log Analytics
8. **(Optional) Configure Auto-Shutdown** - Set shutdown schedule for dev/test environments to save costs (pre-configured if selected during interactive deployment)

**Health Check Logs Available:**
- `/var/log/cloudpi-deployment-health.log` - Complete validation results
- `/var/log/cloudpi-disk-setup.log` - Data disk setup details
- `/var/log/cloud-init-output.log` - Full provisioning log

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed post-deployment steps.

## Deployment Outputs

After deployment, retrieve important information:

```bash
# Set deployment name
DEPLOYMENT_NAME="cloudpi-prod-20251116-120000"

# Get outputs
az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs

# Specific values
RG_NAME=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.resourceGroupName.value -o tsv)
VM_IP=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.vmPrivateIpAddress.value -o tsv)
STORAGE=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.storageAccountName.value -o tsv)
KV_URI=$(az deployment sub show --name $DEPLOYMENT_NAME --query properties.outputs.keyVaultUri.value -o tsv)
```

## Customization

### Extending the Infrastructure

The modular design allows easy customization:

- **Add Application Gateway** - Uncomment AGW subnet in networking module
- **Enable Private Endpoints** - **Recommended for production**: Update storage and Key Vault modules to use private endpoints and change network ACLs to Deny
- **Add VNet Peering** - Connect to hub VNet for central connectivity
- **Multi-VM Deployment** - Extend compute module with VM scale set or availability zones
- **Managed Database** - Replace VM MySQL with Azure Database for MySQL
- **DDoS Protection** - Add Azure DDoS Protection Standard plan to VNet
- **Customer-Managed Keys** - Configure Key Vault for disk and storage encryption

### Custom Environment

Create your own parameter file:

```bash
cp parameters.json my-environment.parameters.json
# Edit with your values
nano my-environment.parameters.json

# Deploy
az deployment sub create \
  --name cloudpi-custom-$(date +%Y%m%d-%H%M%S) \
  --location eastus2 \
  --template-file main.bicep \
  --parameters @my-environment.parameters.json
```

## Troubleshooting

Common issues and solutions are documented in [DEPLOYMENT.md](DEPLOYMENT.md#troubleshooting).

### Quick Deployment Checks

```bash
# Verify tools
az --version
az bicep version

# Validate template
az bicep build --file main.bicep

# Check deployment status
az deployment sub show --name cloudpi-prod-20251116-120000

# View activity logs
az monitor activity-log list --resource-group rg-cloudpi-prod
```

### VM Health Verification

**Interactive Deployment:**
If you used `./deploy-interactive.sh`, health check results are automatically displayed in your terminal after deployment.

**Manual Verification:**
After deployment, SSH to your VM and verify the health checks:

```bash
# Review health check results
cat /var/log/cloudpi-deployment-health.log

# Check data disk mount
df -h /datadisk
systemctl status datadisk.mount

# Verify Docker configuration
docker info | grep "Docker Root Dir"
# Should show: /datadisk/docker

# Check cloud-init completion
cloud-init status

# View full cloud-init logs
cat /var/log/cloud-init-output.log

# Verify no systemd ordering conflicts
systemctl list-dependencies datadisk.mount
```

### Common Issues

**Data disk not mounted:**
```bash
# Check systemd mount unit
systemctl status datadisk.mount
journalctl -u datadisk.mount

# Review disk setup logs
cat /var/log/cloudpi-disk-setup.log

# Verify mount point exists
ls -la /datadisk

# Check for systemd ordering issues
systemctl list-dependencies datadisk.mount
```

**Docker not using data disk:**
```bash
# Verify Docker daemon configuration
cat /etc/docker/daemon.json
# Should show: "data-root": "/datadisk/docker"

# Check Docker Root Dir
docker info | grep "Docker Root Dir"
# Should show: /datadisk/docker

# Restart Docker if needed
systemctl restart docker
```

**Performance metrics not appearing in Log Analytics:**
- Verify Azure Monitor Agent is running: `systemctl status azuremonitoragent`
- Check Data Collection Rule association in Azure Portal
- Note: Performance counter paths are Windows-style; some metrics may need adjustment for Linux

**Check if VM has a public IP attached:**
```bash
# List all public IPs in resource group
az network public-ip list --resource-group rg-cloudpi-dev --output table

# Check specific NIC configuration
az network nic show --resource-group rg-cloudpi-dev \
  --name nic-vm-cloudpi-app-01-dev \
  --query "ipConfigurations[0].publicIpAddress" -o tsv
```

**Remove temporary public IP from VM:**
```bash
# See "Temporary Public IP for Testing" section above for removal commands
```

## Maintenance

### Regular Tasks
- **Monthly**: Review and update NSG rules
- **Quarterly**: Review backup retention and test restores
- **As needed**: Update VM size based on performance metrics
- **As needed**: Rotate secrets in Key Vault

### Cost Optimization
- Monitor unused resources via Azure Advisor
- Review storage lifecycle policies
- Use Azure Cost Management exports (configured post-deployment)
- Deallocate VMs when not in use (dev/test)

## Security Best Practices

This template implements:

- ✅ No public IPs on VMs (Bicep templates secure by default; deployment script offers optional temp public IP for testing)
- ✅ NSG with explicit allow rules and deny-all fallback
- ✅ SSH key-only authentication (password disabled)
- ✅ Managed identity instead of credentials
- ✅ RBAC-based access control
- ✅ Encryption at rest for all storage (platform-managed keys)
- ✅ TLS 1.2 minimum for all services
- ✅ Soft-delete and purge protection on Key Vault
- ✅ Boot diagnostics enabled
- ✅ Automated patching configured (AutomaticByPlatform)
- ✅ Blob public access disabled
- ✅ Storage lifecycle policies for cost optimization
- ⚠️ Storage and Key Vault accessible via public endpoints (network ACLs: Allow)

### Recommended Production Hardening

For production deployments, consider:
- Implement private endpoints for Storage Account and Key Vault
- Change network ACLs `defaultAction` from `Allow` to `Deny` with specific IP allowlists
- Enable customer-managed keys (CMK) for enhanced encryption control
- Implement Azure DDoS Protection on VNet
- Configure availability zones for high availability
- Set up Azure Policy for governance and compliance
- Restrict `sshAllowedSourceAddresses` and `httpsAllowedSourceAddresses` to specific IP ranges (avoid wildcards)

## Documentation

- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Complete deployment guide with troubleshooting and network strategy

## Clean Up

To delete all resources:

```bash
# Delete environment
az group delete --name rg-cloudpi-{env} --yes --no-wait

# Purge Key Vault (if needed)
az keyvault purge --name kv-cloudpi-{env}
```

## Resources

- [Azure Bicep Documentation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Azure Architecture Center](https://learn.microsoft.com/en-us/azure/architecture/)
- [Azure Monitor for VMs](https://learn.microsoft.com/en-us/azure/azure-monitor/vm/vminsights-overview)
- [Azure Backup](https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-introduction)

## Support

For questions or issues:
- Review [DEPLOYMENT.md](DEPLOYMENT.md) troubleshooting section
- Check Azure activity logs in portal
- Contact: trey.morgan@nichesoft.ai

---

**Ready to deploy?** Run `./deploy-interactive.sh` to get started!
