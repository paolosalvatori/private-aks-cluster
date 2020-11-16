#!/bin/bash

# Variables

# AKS cluster name
aksName="<AKS cluster name>"

# ARM template and parameters file
template="../templates/one-node-pool/azuredeploy.json"
parameters="../templates/one-node-pool/azuredeploy.parameters.json"

# Name and location of the resource group for the Azure Kubernetes Service (AKS) cluster
aksResourceGroup="<AKS resource group name>"
location="<Region>"

# Name and resource group name of the Azure Container Registry used by the AKS cluster.
# The name of the cluster is also used to create or select an existing admin group in the Azure AD tenant.
acrName="<ACR name>"
acrResourceGroup="<ACR resource group name>"
acrSku="Basic"

# SubscriptionId and tenantId of the current subscription
subscriptionId=$(az account show --query id --output tsv)
tenantId=$(az account show --query tenantId --output tsv)

# Data necessary to identify or create an admin user in the admin users group
userPrincipalName=$(az account show --query user.name --output tsv)
if [[ -n $userPrincipalName ]]; then
    echo "["$userPrincipalName"] successfully retrieved from ["$tenantId"]"
else
    echo "Failed to retrieve the username from ["$tenantId"]"
    exit
fi

# Install aks-preview Azure extension
echo "Checking if [aks-preview] extension is already installed..."
az extension show --name aks-preview &>/dev/null

if [[ $? == 0 ]]; then
    echo "[aks-preview] extension is already installed"

    # Update the extension to make sure you have the latest version installed
    echo "Updating [aks-preview] extension..."
    az extension update --name aks-preview &>/dev/null
else
    echo "[aks-preview] extension is not installed. Installing..."

    # Install aks-preview extension
    az extension add --name aks-preview 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "[aks-preview] extension successfully installed"
    else
        echo "Failed to install [aks-preview] extension"
        exit
    fi
fi

# Registering AKS feature extensions
aksExtensions=("EnableAzureRBACPreview")
ok=0
for aksExtension in ${aksExtensions[@]}; do
    echo "Checking if ["$aksExtension"] extension is already registered..."
    extension=$(az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/$aksExtension') && @.properties.state == 'Registered'].{Name:name}" --output tsv)
    if [[ -z $extension ]]; then
        echo "["$aksExtension"] extension is not registered."
        echo "Registering ["$aksExtension"] extension..."
        az feature register --name $aksExtension --namespace Microsoft.ContainerService
        ok=1
    else
        echo "["$aksExtension"] extension is already registered."
    fi
done

if [[ $ok == 1 ]]; then
    echo "Refreshing the registration of the Microsoft.ContainerService resource provider..."
    az provider register --namespace Microsoft.ContainerService
    echo "Microsoft.ContainerService resource provider registration successfully refreshed"
fi

# Get the last Kubernetes version available in the region
kubernetesVersion=$(az aks get-versions --location $location --query orchestrators[-1].orchestratorVersion --output tsv)

if [[ -n $kubernetesVersion ]]; then
    echo "Successfully retrieved the last Kubernetes version ["$kubernetesVersion"] supported by AKS in ["$location"] Azure region"
else
    echo "Failed to retrieve the last Kubernetes version supported by AKS in ["$location"] Azure region"
    exit
fi

# Check if the resource group already exists
echo "Checking if ["$aksResourceGroup"] resource group actually exists in the ["$subscriptionId"] subscription..."

az group show --name $aksResourceGroup &>/dev/null

if [[ $? != 0 ]]; then
    echo "No ["$aksResourceGroup"] resource group actually exists in the ["$subscriptionId"] subscription"
    echo "Creating ["$aksResourceGroup"] resource group in the ["$subscriptionId"] subscription..."

    # Create the resource group
    az group create --name $aksResourceGroup --location $location 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "["$aksResourceGroup"] resource group successfully created in the ["$subscriptionId"] subscription"
    else
        echo "Failed to create ["$aksResourceGroup"] resource group in the ["$subscriptionId"] subscription"
        exit
    fi
else
    echo "["$aksResourceGroup"] resource group already exists in the ["$subscriptionId"] subscription"
fi

# Create AKS cluster if does not exist
echo "Checking if ["$aksName"] aks cluster actually exists in the ["$aksResourceGroup"] resource group..."

az aks show --name $aksName --resource-group $aksResourceGroup &>/dev/null

if [[ $? != 0 ]]; then
    echo "No ["$aksName"] aks cluster actually exists in the ["$aksResourceGroup"] resource group"
    echo "Creating ["$aksName"] aks cluster in the ["$aksResourceGroup"] resource group..."

    # Validate the ARM template
    echo "Validating ["$template"] ARM template..."
    az deployment group validate \
    --resource-group $aksResourceGroup \
    --only-show-errors \
    --template-file $template \
    --parameters $parameters \
    --parameters aksClusterName=$aksName \
                 aksClusterKubernetesVersion=$kubernetesVersion

    # Deploy the ARM template
    echo "Deploying ["$template"] ARM template..."
    az deployment group create \
        --resource-group $aksResourceGroup \
        --only-show-errors \
        --template-file $template \
        --parameters $parameters \
        --parameters aksClusterName=$aksName \
        aksClusterKubernetesVersion=$kubernetesVersion

    if [[ $? == 0 ]]; then
        echo "["$template"] ARM template successfully provisioned"
    else
        echo "Failed to provision the ["$template"] ARM template"
        exit
    fi
else
    echo "["$aksName"] aks cluster already exists in the ["$aksResourceGroup"] resource group"
fi

# Retrieve resource id for the ACR
echo "Retrieving the resource id of the ["$acrName"] azure container registry..."
acrResourceId=$(az acr show --name $acrName --resource-group $acrResourceGroup --query id --output tsv 2>/dev/null)

if [[ -n $acrResourceId ]]; then
    echo "Resource id for the ["$acrName"] azure container registry successfully retrieved: ["$acrResourceId"]"
else
    echo "Failed to retrieve resource id of the ["$acrName"] azure container registry"

    # Check if the resource group already exists
    echo "Checking if ["$acrResourceGroup"] resource group actually exists in the ["$subscriptionId"] subscription..."

    az group show --name $acrResourceGroup &>/dev/null

    if [[ $? != 0 ]]; then
        echo "No ["$acrResourceGroup"] resource group actually exists in the ["$subscriptionId"] subscription"
        echo "Creating ["$acrResourceGroup"] resource group in the ["$subscriptionId"] subscription..."

        # Create the resource group
        az group create --name $acrResourceGroup --location $location 1>/dev/null

        if [[ $? == 0 ]]; then
            echo "["$acrResourceGroup"] resource group successfully created in the ["$subscriptionId"] subscription"
        else
            echo "Failed to create ["$acrResourceGroup"] resource group in the ["$subscriptionId"] subscription"
            exit
        fi
    else
        echo "["$acrResourceGroup"] resource group already exists in the ["$subscriptionId"] subscription"
    fi

    # Create ACR registry
    echo "No ["$acrName"] azure container registry actually exists in the ["$acrResourceGroup"] resource group"
    echo "Creating ["$acrName"] azure container registry in the ["$acrResourceGroup"] resource group..."
    acrResourceId=$(az acr create --name $acrName --resource-group $acrResourceGroup --sku $acrSku --query id)

    if [[ -n $acrResourceId ]]; then
        echo "["$acrName"] azure container registry successfully created in the ["$acrResourceGroup"] resource group"
    else
        echo "Failed to create ["$acrName"] azure container registry in the ["$acrResourceGroup"] resource group"
        exit
    fi
fi

# Get the system-assigned managed identity used by the AKS cluster
echo "Retrieving the system-assigned managed identity from the [$aksName] AKS cluster..."
clientId=$(az aks show \
    --name $aksName \
    --resource-group $aksResourceGroup \
    --query identityProfile.kubeletidentity.clientId \
    --output tsv)

if [[ -n $clientId ]]; then
    echo "System-assigned managed identity of the [$aksName] AKS cluster successfully retrieved"
else
    echo "Failed to retrieve the system-assigned managed identity of the [$aksName] AKS cluster"
    exit
fi

# Assign the AKS system-assigned managed identity to the AcrPull for the ACR
echo "Checking if ["$clientId"] system-assigned managed identity has been assigned to [AcrPull] role for the ["$acrName"] azure container registry..."
role=$(az role assignment list --assignee $clientIdAppId --scope $acrResourceId --query [?roleDefinitionName].roleDefinitionName --output tsv 2>/dev/null)

if [[ $role == "Owner" ]] || [[ $role == "Contributor" ]] || [[ $role == "Reader" ]] || [[ $role == "AcrPull" ]]; then
    echo "["$clientId"] system-assigned managed identity is already assigned to the ["$role"] role for the ["$acrName"] azure container registry"
else
    echo "["$clientId"] system-assigned managed identity is not assigned to the [AcrPull] role for the ["$acrName"] azure container registry"
    echo "Assigning the ["$clientId"] system-assigned managed identity to the [AcrPull] role for the ["$acrName"] azure container registry..."

    az role assignment create \
        --assignee $clientId \
        --role AcrPull \
        --scope $acrResourceId \
        --only-show-errors 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "["$clientId"] system-assigned managed identity successfully assigned to the [AcrPull] role of the ["$acrName"] azure container registry"
    else
        echo "Failed to assign the ["$clientId"] system-assigned managed identity to the [AcrPull] role of the ["$acrName"] azure container registry"
        exit
    fi
fi
