// ============================================================================
// CloudPi Production Infrastructure - Main Orchestration
// ============================================================================
// Description: Main Bicep template for deploying CloudPi infrastructure
// Author: Infrastructure as Code
// Version: 1.0
// ============================================================================

targetScope = 'subscription'

// ============================================================================
// Parameters
// ============================================================================

@description('Project or application name for resource naming (e.g., cloudpi, myapp)')
@minLength(3)
@maxLength(10)
param projectName string = 'cloudpi'

@description('The environment name (e.g., prod, dev, staging)')
param environment string = 'prod'

@description('Primary Azure region for resources')
param location string = 'eastus'

@description('Tags to apply to all resources')
param tags object = {
  Application: projectName
  Environment: environment
  ManagedBy: 'Bicep'
}

@description('Virtual Network address space (optional - auto-assigned based on environment if not specified)')
param vnetAddressPrefix string = ''

@description('Application subnet address prefix (optional - auto-assigned based on environment if not specified)')
param appSubnetPrefix string = ''

@description('Allowed IP ranges for SSH access (management subnet or jump host)')
param sshAllowedSourceAddresses array = []

@description('Allowed IP ranges for HTTPS access (Netskope connector or corporate ranges)')
param httpsAllowedSourceAddresses array = []

@description('VM size for the CloudPi application server')
@allowed([
  'Standard_D2s_v3'
  'Standard_D4s_v3'
  'Standard_D8s_v3'
  'Standard_D2s_v4'
  'Standard_D4s_v4'
  'Standard_D8s_v4'
  'Standard_D2s_v5'
  'Standard_D4s_v5'
  'Standard_D8s_v5'
  'Standard_D2as_v4'
  'Standard_D4as_v4'
  'Standard_D8as_v4'
  'Standard_D2as_v5'
  'Standard_D4as_v5'
  'Standard_D8as_v5'
])
param vmSize string = 'Standard_D4s_v5'

@description('Admin username for the VM')
param adminUsername string = 'azureadmin'

@description('SSH public key for VM access')
@secure()
param sshPublicKey string

@description('OS disk size in GB')
param osDiskSizeGB int = 128

@description('Data disk size in GB')
param dataDiskSizeGB int = 256

@description('Enable Azure Backup for the VM')
param enableBackup bool = true

@description('Backup retention in days')
param backupRetentionDays int = 30

@description('Email addresses for alert notifications')
param alertEmailAddresses array = []

@description('Your Azure AD Tenant ID')
param tenantId string

@description('Enable auto-shutdown schedule for VM (recommended for dev/test)')
param enableAutoShutdown bool = false

@description('Auto-shutdown time in 24-hour format (e.g., 2200 for 10 PM)')
param autoShutdownTime string = '2200'

@description('Timezone for auto-shutdown (e.g., Eastern Standard Time, Pacific Standard Time, Central Standard Time)')
param autoShutdownTimeZone string = 'UTC'

@description('Email notification for auto-shutdown (optional)')
param autoShutdownNotificationEmail string = ''

// ============================================================================
// Variables
// ============================================================================

var resourceGroupName = 'rg-${projectName}-${environment}'
var namingPrefix = projectName

// Automatic network range assignment based on projectName + environment
// Generates unique IP ranges to prevent conflicts when multiple projects use the same environment
// Uses deterministic hash: same projectName+environment always gets same IP range
// IP range: 10.50-249.0.0/16 (200 possible unique ranges)

// Calculate unique third octet from projectName + environment hash
// Uses uniqueString hash and calculates numeric value from string length and char codes
// This gives us a deterministic number in range 50-249
var hashString = uniqueString(projectName, environment)
var hashValue = (length(hashString) * 17 + length(projectName) * 13 + length(environment) * 7)
var calculateIpOctet = string((hashValue % 200) + 50)

// Generate IP ranges based on calculated octet
var autoVnetPrefix = '10.${calculateIpOctet}.0.0/16'
var autoAppSubnetPrefix = '10.${calculateIpOctet}.1.0/24'

// Use provided values if specified, otherwise use auto-calculated values
var actualVnetAddressPrefix = !empty(vnetAddressPrefix) ? vnetAddressPrefix : autoVnetPrefix
var actualAppSubnetPrefix = !empty(appSubnetPrefix) ? appSubnetPrefix : autoAppSubnetPrefix

// ============================================================================
// Resource Group
// ============================================================================

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ============================================================================
// Networking Module
// ============================================================================

module networking 'modules/networking.bicep' = {
  name: 'networking-deployment'
  scope: resourceGroup
  params: {
    location: location
    environment: environment
    tags: tags
    namingPrefix: namingPrefix
    vnetAddressPrefix: actualVnetAddressPrefix
    appSubnetPrefix: actualAppSubnetPrefix
    sshAllowedSourceAddresses: sshAllowedSourceAddresses
    httpsAllowedSourceAddresses: httpsAllowedSourceAddresses
  }
}

// ============================================================================
// Storage Module
// ============================================================================

module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    namingPrefix: namingPrefix
  }
}

// ============================================================================
// Security Module (Key Vault)
// ============================================================================

module security 'modules/security.bicep' = {
  name: 'security-deployment'
  scope: resourceGroup
  params: {
    location: location
    environment: environment
    tags: tags
    namingPrefix: namingPrefix
    tenantId: tenantId
  }
}

// ============================================================================
// Monitoring Module (Log Analytics, Alerts, Backup)
// ============================================================================

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-deployment'
  scope: resourceGroup
  params: {
    location: location
    environment: environment
    tags: tags
    namingPrefix: namingPrefix
    alertEmailAddresses: alertEmailAddresses
    enableBackup: enableBackup
    backupRetentionDays: backupRetentionDays
  }
}

// ============================================================================
// Compute Module (VM with Docker)
// ============================================================================

module compute 'modules/compute.bicep' = {
  name: 'compute-deployment'
  scope: resourceGroup
  params: {
    location: location
    environment: environment
    tags: tags
    namingPrefix: namingPrefix
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    osDiskSizeGB: osDiskSizeGB
    dataDiskSizeGB: dataDiskSizeGB
    subnetId: networking.outputs.appSubnetId
    nsgId: networking.outputs.nsgId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    recoveryServicesVaultName: enableBackup ? monitoring.outputs.recoveryServicesVaultName : ''
    keyVaultName: security.outputs.keyVaultName
    enableBackup: enableBackup
    enableAutoShutdown: enableAutoShutdown
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    autoShutdownNotificationEmail: autoShutdownNotificationEmail
  }
}

// ============================================================================
// Role Assignments for Managed Identity
// ============================================================================

// Grant VM managed identity access to storage account
module storageRoleAssignment 'modules/roleAssignments.bicep' = {
  name: 'storage-role-assignment'
  scope: resourceGroup
  params: {
    principalId: compute.outputs.vmManagedIdentityPrincipalId
    storageAccountName: storage.outputs.storageAccountName
    keyVaultName: security.outputs.keyVaultName
  }
}

// ============================================================================
// Outputs
// ============================================================================

@description('The name of the resource group')
output resourceGroupName string = resourceGroupName

@description('The name of the virtual network')
output vnetName string = networking.outputs.vnetName

@description('The resource ID of the app subnet')
output appSubnetId string = networking.outputs.appSubnetId

@description('The private IP address of the CloudPi VM')
output vmPrivateIpAddress string = compute.outputs.vmPrivateIpAddress

@description('The name of the CloudPi VM')
output vmName string = compute.outputs.vmName

@description('The principal ID of the VM managed identity')
output vmManagedIdentityPrincipalId string = compute.outputs.vmManagedIdentityPrincipalId

@description('The name of the storage account')
output storageAccountName string = storage.outputs.storageAccountName

@description('The URI of the Key Vault')
output keyVaultUri string = security.outputs.keyVaultUri

@description('The resource ID of the Log Analytics workspace')
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

@description('The name of the Recovery Services Vault (if backup is enabled)')
output recoveryServicesVaultName string = enableBackup ? monitoring.outputs.recoveryServicesVaultName : ''
