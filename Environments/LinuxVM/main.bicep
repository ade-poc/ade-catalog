param adminUsername string = 'azureuser'
param location string = resourceGroup().location
param branchName string = 'main'

var vmName = 'adevm${uniqueString(resourceGroup().id)}'
var pipName = '${vmName}-pip'
var nsgName = '${vmName}-nsg'
var vnetName = '${vmName}-vnet'
var nicName = '${vmName}-nic'
var adminPassword = 'AdeP@ss${uniqueString(resourceGroup().id, vmName)}'

var cloudInitScript = '''#!/bin/bash
apt-get update -y
apt-get install -y python3 git

# Clone the branch
git clone -b BRANCH_NAME https://github.com/srinipaddu/ade-catalog.git /app

# Replace branch placeholder in hello.py
sed -i "s/BRANCH_PLACEHOLDER/BRANCH_NAME/g" /app/src/hello.py

# Run Hello World from branch code
python3 /app/src/hello.py > /tmp/hello_output.txt 2>&1

echo "Deploy complete" >> /tmp/hello_output.txt
'''

resource pip 'Microsoft.Network/publicIPAddresses@2022-01-01' = {
  name: pipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: vmName
    }
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2022-01-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 1000
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2022-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2022-01-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_D2s_v3'
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(replace(cloudInitScript, 'BRANCH_NAME', branchName))
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output sshCommand string = 'ssh ${adminUsername}@${pip.properties.ipAddress}'
output adminPassword string = adminPassword
output vmIp string = pip.properties.ipAddress
output branchDeployed string = branchName
