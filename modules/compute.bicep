// ============================================================================
// Compute Module - Virtual Machine with Docker
// ============================================================================
// Description: Creates VM with managed identity and monitoring extensions
// ============================================================================

@description('Azure region for resources')
param location string

@description('Environment name')
param environment string

@description('Resource tags')
param tags object

@description('Project name for resource naming')
param namingPrefix string

@description('VM size')
param vmSize string

@description('Admin username')
param adminUsername string

@description('SSH public key')
@secure()
param sshPublicKey string

@description('OS disk size in GB')
param osDiskSizeGB int

@description('Data disk size in GB')
param dataDiskSizeGB int

@description('Subnet resource ID for the VM')
param subnetId string

@description('NSG resource ID')
param nsgId string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Recovery Services Vault name (if backup is enabled)')
param recoveryServicesVaultName string

@description('Key Vault name for secrets access')
param keyVaultName string

@description('Enable backup')
param enableBackup bool

@description('Enable auto-shutdown schedule')
param enableAutoShutdown bool = false

@description('Auto-shutdown time in 24-hour format (e.g., 2200 for 10 PM)')
param autoShutdownTime string = '2200'

@description('Timezone for auto-shutdown (e.g., Eastern Standard Time, Pacific Standard Time)')
param autoShutdownTimeZone string = 'UTC'

@description('Email notification for auto-shutdown')
param autoShutdownNotificationEmail string = ''

// ============================================================================
// Variables
// ============================================================================

var vmName = 'vm-${namingPrefix}-app-01-${environment}'
var nicName = 'nic-${namingPrefix}-app-01-${environment}'
var osDiskName = '${vmName}-osdisk'
var dataDiskName = '${vmName}-datadisk'

// Cloud-init configuration for Docker setup
var cloudInitTemplate = '''
#cloud-config
package_upgrade: true
packages:
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - parted

write_files:
  - path: /etc/docker/daemon.json
    content: |
      {
        "log-driver": "json-file",
        "log-opts": {
          "max-size": "10m",
          "max-file": "3"
        },
        "data-root": "/datadisk/docker"
      }

runcmd:
  # Install Docker
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  - echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker {{ADMIN_USERNAME}}

  # Setup data disk using LUN-based detection
  - |
    set -e
    LOG_FILE="/var/log/cloudpi-disk-setup.log"
    MOUNT_POINT="/datadisk"
    ADMIN_USER="{{ADMIN_USERNAME}}"

    # Logging function
    log() {
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
    }

    log "Starting data disk setup (admin user: $ADMIN_USER)"

    # Create mount point
    mkdir -p "$MOUNT_POINT"
    log "Created mount point: $MOUNT_POINT"

    # Wait for Azure data disk (LUN 0) to be available
    log "Waiting for data disk (LUN 0) to be available..."
    RETRY_COUNT=0
    MAX_RETRIES=30

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
      if [ -e /dev/disk/azure/scsi1/lun0 ]; then
        log "Data disk LUN 0 detected"
        break
      fi
      log "Waiting for disk... (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
      sleep 2
      RETRY_COUNT=$((RETRY_COUNT + 1))
    done

    if [ ! -e /dev/disk/azure/scsi1/lun0 ]; then
      log "ERROR: Data disk (LUN 0) not found after $MAX_RETRIES attempts"
      log "Available disks: $(ls -l /dev/disk/azure/scsi1/ 2>&1 || echo 'none')"
      exit 1
    fi

    # Get the actual device path
    DATA_DISK=$(readlink -f /dev/disk/azure/scsi1/lun0)
    log "Data disk device: $DATA_DISK"

    # Safety check: Ensure we're not using the root filesystem disk
    ROOT_DISK=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    log "Root filesystem disk: $ROOT_DISK"

    if [ "$DATA_DISK" = "$ROOT_DISK" ]; then
      log "ERROR: Data disk ($DATA_DISK) is the same as root filesystem disk ($ROOT_DISK)!"
      log "This would destroy the OS. Aborting."
      log "Available LUNs:"
      ls -la /dev/disk/azure/scsi1/ | tee -a "$LOG_FILE"
      log "All block devices:"
      lsblk | tee -a "$LOG_FILE"
      exit 1
    fi

    log "Safety check passed: Data disk ($DATA_DISK) is different from root disk ($ROOT_DISK)"

    # Check if disk is already formatted and mounted
    if mount | grep -q "$MOUNT_POINT"; then
      log "Data disk already mounted at $MOUNT_POINT"
      exit 0
    fi

    # Check if disk already has a filesystem
    if blkid "$DATA_DISK" | grep -q "TYPE="; then
      log "Disk already formatted, mounting existing filesystem"
      EXISTING_FS=$(blkid -o value -s TYPE "$DATA_DISK")
      DISK_UUID=$(blkid -o value -s UUID "$DATA_DISK")
      log "Existing filesystem type: $EXISTING_FS"
      log "Disk UUID: $DISK_UUID"

      # Create systemd mount unit
      MOUNT_UNIT_FILE="/etc/systemd/system/datadisk.mount"
      log "Creating systemd mount unit: $MOUNT_UNIT_FILE"

      printf '%s\n' \
        '[Unit]' \
        'Description=CloudPi Data Disk Mount' \
        'Before=docker.service' \
        "After=blockdev@dev-disk-by\\\\x2duuid-${DISK_UUID}.target" \
        '' \
        '[Mount]' \
        "What=UUID=${DISK_UUID}" \
        'Where=/datadisk' \
        "Type=${EXISTING_FS}" \
        'Options=defaults,nofail' \
        'DirectoryMode=0755' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > "$MOUNT_UNIT_FILE"

      systemctl daemon-reload
      systemctl enable datadisk.mount
      systemctl start datadisk.mount
      log "Systemd mount unit created and enabled"
    else
      log "Disk not formatted, creating new filesystem"

      # Create partition table and partition
      log "Creating GPT partition table..."
      parted "$DATA_DISK" --script mklabel gpt mkpart primary ext4 0% 100%

      # Wait for partition to be recognized
      sleep 2
      partprobe "$DATA_DISK"
      sleep 2

      # Determine partition device name
      if [ -b "${DATA_DISK}1" ]; then
        PARTITION="${DATA_DISK}1"
      elif [ -b "${DATA_DISK}p1" ]; then
        PARTITION="${DATA_DISK}p1"
      else
        log "ERROR: Cannot determine partition device name"
        log "Tried: ${DATA_DISK}1 and ${DATA_DISK}p1"
        exit 1
      fi

      log "Partition created: $PARTITION"

      # Format the partition
      log "Formatting partition as ext4..."
      mkfs.ext4 -F "$PARTITION"

      # Wait for filesystem to be recognized and get UUID
      sleep 2
      partprobe "$PARTITION"
      sleep 1

      PARTITION_UUID=$(blkid -o value -s UUID "$PARTITION")
      log "Partition UUID: $PARTITION_UUID"

      # Create systemd mount unit
      MOUNT_UNIT_FILE="/etc/systemd/system/datadisk.mount"
      log "Creating systemd mount unit: $MOUNT_UNIT_FILE"

      printf '%s\n' \
        '[Unit]' \
        'Description=CloudPi Data Disk Mount' \
        'Before=docker.service' \
        "After=blockdev@dev-disk-by\\\\x2duuid-${PARTITION_UUID}.target" \
        '' \
        '[Mount]' \
        "What=UUID=${PARTITION_UUID}" \
        'Where=/datadisk' \
        'Type=ext4' \
        'Options=defaults,nofail' \
        'DirectoryMode=0755' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > "$MOUNT_UNIT_FILE"

      systemctl daemon-reload
      systemctl enable datadisk.mount
      systemctl start datadisk.mount
      log "Systemd mount unit created and enabled"
    fi

    # Verify mount
    if mount | grep -q "$MOUNT_POINT"; then
      log "SUCCESS: Data disk mounted at $MOUNT_POINT"
      df -h "$MOUNT_POINT" | tee -a "$LOG_FILE"
    else
      log "ERROR: Failed to mount data disk"
      exit 1
    fi

    # Set ownership
    chown -R $ADMIN_USER:$ADMIN_USER "$MOUNT_POINT"
    log "Set ownership to $ADMIN_USER"

    log "Data disk setup completed successfully"

  # Create directories for CloudPi
  - mkdir -p /datadisk/mysql
  - mkdir -p /datadisk/app
  - mkdir -p /datadisk/logs
  - mkdir -p /datadisk/backups
  - mkdir -p /datadisk/docker
  - chown -R {{ADMIN_USERNAME}}:{{ADMIN_USERNAME}} /datadisk

  # Restart Docker to apply data-root configuration
  - systemctl restart docker

  # Install Azure CLI (for potential management tasks)
  - curl -sL https://aka.ms/InstallAzureCLIDeb | bash

  # Post-deployment validation and health check
  - |
    HEALTH_LOG="/var/log/cloudpi-deployment-health.log"
    ADMIN_USER="{{ADMIN_USERNAME}}"
    KEY_VAULT_NAME="{{KEY_VAULT_NAME}}"

    # Run health check and tee output to log file (sh-compatible syntax)
    {
      ERRORS=0

      echo "========================================"
      echo "CloudPi Deployment Health Check"
      echo "========================================"
      echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "Hostname: $(hostname)"
      echo ""

      # Check 1: Docker Installation
      echo "[1/10] Checking Docker installation..."
      if command -v docker >/dev/null 2>&1; then
        DOCKER_VERSION=$(docker --version)
        echo "  ✅ Docker installed: $DOCKER_VERSION"
      else
        echo "  ❌ ERROR: Docker not installed"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 2: Docker Running
      echo "[2/10] Checking Docker service..."
      if systemctl is-active --quiet docker; then
        echo "  ✅ Docker service is running"
      else
        echo "  ❌ ERROR: Docker service not running"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 3: Docker Data Root
      echo "[3/10] Checking Docker data-root..."
      DOCKER_ROOT=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $4}')
      if [ "$DOCKER_ROOT" = "/datadisk/docker" ]; then
        echo "  ✅ Docker using data disk: $DOCKER_ROOT"
      else
        echo "  ❌ ERROR: Docker not using data disk (current: $DOCKER_ROOT)"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 4: Data Disk Mount
      echo "[4/10] Checking data disk mount..."
      if mountpoint -q /datadisk; then
        DISK_SIZE=$(df -h /datadisk | tail -1 | awk '{print $2}')
        DISK_AVAIL=$(df -h /datadisk | tail -1 | awk '{print $4}')
        echo "  ✅ Data disk mounted: $DISK_SIZE total, $DISK_AVAIL available"
      else
        echo "  ❌ ERROR: Data disk not mounted at /datadisk"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 5: systemd Mount Unit
      echo "[5/10] Checking systemd mount unit..."
      if systemctl is-enabled --quiet datadisk.mount 2>/dev/null; then
        echo "  ✅ systemd mount unit enabled (will auto-mount on reboot)"
      else
        echo "  ❌ ERROR: systemd mount unit not enabled"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 6: Azure CLI
      echo "[6/10] Checking Azure CLI..."
      if command -v az >/dev/null 2>&1; then
        AZ_VERSION=$(az --version 2>&1 | head -1)
        echo "  ✅ Azure CLI installed: $AZ_VERSION"
      else
        echo "  ❌ ERROR: Azure CLI not installed"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 7: Directories
      echo "[7/10] Checking CloudPi directories..."
      DIRS_OK=true
      for dir in mysql app logs backups docker; do
        if [ -d "/datadisk/$dir" ]; then
          OWNER=$(stat -c "%U:%G" "/datadisk/$dir" 2>/dev/null)
          if [ "$dir" = "docker" ]; then
            echo "  ✅ /datadisk/$dir exists (owner: $OWNER)"
          elif [ "$OWNER" = "$ADMIN_USER:$ADMIN_USER" ]; then
            echo "  ✅ /datadisk/$dir exists (owner: $OWNER)"
          else
            echo "  ⚠️  WARNING: /datadisk/$dir has incorrect owner: $OWNER (expected: $ADMIN_USER:$ADMIN_USER)"
            DIRS_OK=false
          fi
        else
          echo "  ❌ ERROR: /datadisk/$dir missing"
          ERRORS=$((ERRORS + 1))
          DIRS_OK=false
        fi
      done

      # Check 8: Managed Identity
      echo "[8/10] Checking managed identity..."
      if az login --identity --allow-no-subscriptions >/dev/null 2>&1; then
        echo "  ✅ Managed identity authentication successful"
      else
        echo "  ❌ ERROR: Managed identity authentication failed"
        ERRORS=$((ERRORS + 1))
      fi

      # Check 9: Key Vault Access
      echo "[9/10] Checking Key Vault access..."
      if [ -n "$KEY_VAULT_NAME" ]; then
        if az keyvault secret list --vault-name "$KEY_VAULT_NAME" >/dev/null 2>&1; then
          echo "  ✅ Key Vault accessible: $KEY_VAULT_NAME"
        else
          echo "  ⚠️  WARNING: Cannot access Key Vault: $KEY_VAULT_NAME"
          echo "      (This is expected if no secrets exist yet)"
        fi
      else
        echo "  ⚠️  WARNING: Key Vault name not provided to health check"
      fi

      # Check 10: Disk Space
      echo "[10/10] Checking disk space..."
      DATA_DISK_USAGE=$(df -h /datadisk | tail -1 | awk '{print $5}' | sed 's/%//')
      if [ "$DATA_DISK_USAGE" -lt 10 ]; then
        echo "  ✅ Data disk usage: ${DATA_DISK_USAGE}%"
      else
        echo "  ⚠️  WARNING: Data disk usage high: ${DATA_DISK_USAGE}%"
      fi

      echo ""
      echo "========================================"
      echo "Health Check Summary"
      echo "========================================"
      if [ $ERRORS -eq 0 ]; then
        echo "✅ ALL CHECKS PASSED - Deployment Successful!"
        echo ""
        echo "Your CloudPi VM is ready to use."
      else
        echo "❌ DEPLOYMENT ISSUES DETECTED: $ERRORS error(s) found"
        echo ""
        echo "Please review the errors above and check:"
        echo "  - /var/log/cloud-init-output.log"
        echo "  - /var/log/cloudpi-disk-setup.log"
        echo "  - /var/log/cloudpi-deployment-health.log (this file)"
      fi
      echo "========================================"
      echo ""
    } | tee "$HEALTH_LOG"

    # Make log readable by admin user
    chmod 644 "$HEALTH_LOG"
'''

// Replace placeholders with actual values and encode
var cloudInitWithUsername = replace(cloudInitTemplate, '{{ADMIN_USERNAME}}', adminUsername)
var cloudInitWithVars = replace(cloudInitWithUsername, '{{KEY_VAULT_NAME}}', keyVaultName)
var cloudInit = base64(cloudInitWithVars)

// ============================================================================
// Network Interface
// ============================================================================

resource nic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    networkSecurityGroup: {
      id: nsgId
    }
  }
}

// ============================================================================
// Virtual Machine
// ============================================================================

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            rebootSetting: 'IfRequired'
          }
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: osDiskSizeGB
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          name: dataDiskName
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          deleteOption: 'Delete'
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// ============================================================================
// VM Extensions
// ============================================================================

// Azure Monitor Agent
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.25'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Data Collection Rule Association
resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: 'dcr-${namingPrefix}-${environment}'
  location: location
  tags: tags
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'perfCounterDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Processor(*)\\% Processor Time'
            'Memory(*)\\Available MBytes'
            'Memory(*)\\% Used Memory'
            'Disk(*)\\% Free Space'
            'Disk(*)\\Disk Read Bytes/sec'
            'Disk(*)\\Disk Write Bytes/sec'
            'Network(*)\\Total Bytes'
          ]
        }
      ]
      syslog: [
        {
          name: 'syslogDataSource'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'cron'
            'daemon'
            'kern'
            'syslog'
          ]
          logLevels: [
            'Error'
            'Critical'
            'Alert'
            'Emergency'
            'Warning'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
          name: 'la-destination'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Perf'
          'Microsoft-Syslog'
        ]
        destinations: [
          'la-destination'
        ]
      }
    ]
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'dcra-${namingPrefix}-${environment}'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// ============================================================================
// Backup Configuration
// ============================================================================

resource backupProtection 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-01-01' = if (enableBackup && !empty(recoveryServicesVaultName)) {
  name: '${recoveryServicesVaultName}/Azure/iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vmName}/vm;iaasvmcontainerv2;${resourceGroup().name};${vmName}'
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    sourceResourceId: vm.id
    policyId: resourceId('Microsoft.RecoveryServices/vaults/backupPolicies', recoveryServicesVaultName, 'DailyBackupPolicy')
  }
}

// ============================================================================
// Auto-Shutdown Schedule
// ============================================================================

resource autoShutdownSchedule 'Microsoft.DevTestLab/schedules@2018-09-15' = if (enableAutoShutdown) {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    targetResourceId: vm.id
    notificationSettings: !empty(autoShutdownNotificationEmail) ? {
      status: 'Enabled'
      timeInMinutes: 30
      emailRecipient: autoShutdownNotificationEmail
      notificationLocale: 'en'
    } : {
      status: 'Disabled'
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('The name of the VM')
output vmName string = vm.name

@description('The resource ID of the VM')
output vmId string = vm.id

@description('The private IP address of the VM')
output vmPrivateIpAddress string = nic.properties.ipConfigurations[0].properties.privateIPAddress

@description('The principal ID of the VM managed identity')
output vmManagedIdentityPrincipalId string = vm.identity.principalId

@description('The name of the network interface')
output nicName string = nic.name

@description('The resource ID of the data collection rule')
output dataCollectionRuleId string = dcr.id
