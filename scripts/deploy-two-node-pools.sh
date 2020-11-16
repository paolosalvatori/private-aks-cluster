#!/bin/bash

# Variables

# AKS cluster name
aksPrefix="<YOUR-PREFIX->"
aksName="${aksPrefix}Aks"
validateTemplate=1
useWhatIf=0

# ARM template and parameters file
template="../templates/two-node-pools/azuredeploy.json"
parameters="../templates/two-node-pools/azuredeploy.parameters.json"

# Name and location of the resource group for the Azure Kubernetes Service (AKS) cluster
aksResourceGroupName="${aksPrefix}RG"
location="WestEurope"

# Name and resource group name of the Azure Container Registry used by the AKS cluster.
# The name of the cluster is also used to create or select an existing admin group in the Azure AD tenant.
acrName="${aksPrefix}Acr"
acrResourceGroupName="$aksResourceGroupName"
acrSku="Standard"

# Subscription id, subscription name, and tenant id of the current subscription
subscriptionId=$(az account show --query id --output tsv)
subscriptionName=$(az account show --query name --output tsv)
tenantId=$(az account show --query tenantId --output tsv)

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
aksExtensions=("EnableAzureRBACPreview" "UserAssignedIdentityPreview")
ok=0
for aksExtension in ${aksExtensions[@]}; do
    echo "Checking if [$aksExtension] extension is already registered..."
    extension=$(az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/$aksExtension') && @.properties.state == 'Registered'].{Name:name}" --output tsv)
    if [[ -z $extension ]]; then
        echo "[$aksExtension] extension is not registered."
        echo "Registering [$aksExtension] extension..."
        az feature register --name $aksExtension --namespace Microsoft.ContainerService
        ok=1
    else
        echo "[$aksExtension] extension is already registered."
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
    echo "Successfully retrieved the last Kubernetes version [$kubernetesVersion] supported by AKS in [$location] Azure region"
else
    echo "Failed to retrieve the last Kubernetes version supported by AKS in [$location] Azure region"
    exit
fi

# Check if the resource group already exists
echo "Checking if [$aksResourceGroupName] resource group actually exists in the [$subscriptionName] subscription..."

az group show --name $aksResourceGroupName &>/dev/null

if [[ $? != 0 ]]; then
    echo "No [$aksResourceGroupName] resource group actually exists in the [$subscriptionName] subscription"
    echo "Creating [$aksResourceGroupName] resource group in the [$subscriptionName] subscription..."

    # Create the resource group
    az group create --name $aksResourceGroupName --location $location 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "[$aksResourceGroupName] resource group successfully created in the [$subscriptionName] subscription"
    else
        echo "Failed to create [$aksResourceGroupName] resource group in the [$subscriptionName] subscription"
        exit
    fi
else
    echo "[$aksResourceGroupName] resource group already exists in the [$subscriptionName] subscription"
fi

# Create AKS cluster if does not exist
echo "Checking if [$aksName] aks cluster actually exists in the [$aksResourceGroupName] resource group..."

az aks show --name $aksName --resource-group $aksResourceGroupName &>/dev/null

if [[ $? != 0 ]]; then
    echo "No [$aksName] aks cluster actually exists in the [$aksResourceGroupName] resource group"

    # Delete any existing role assignments for the user-defined managed identity of the AKS cluster
    # in case you are re-deploying the solution in an existing resource group
    echo "Retrieving the list of role assignments on [$aksResourceGroupName] resource group..."
    assignmentIds=$(az role assignment list \
        --scope "/subscriptions/${subscriptionId}/resourceGroups/${aksResourceGroupName}" \
        --query [].id \
        --output tsv)

    if [[ -n $assignmentIds ]]; then
        echo "[${#assignmentIds[@]}] role assignments have been found on [$aksResourceGroupName] resource group"
        for assignmentId in ${assignmentIds[@]}; do
            if [[ -n $assignmentId ]]; then
                az role assignment delete --ids $assignmentId

                if [[ $? == 0 ]]; then
                    assignmentName=$(echo $assignmentId | awk -F '/' '{print $NF}')
                    echo "[$assignmentName] role assignment on [$aksResourceGroupName] resource group successfully deleted"
                fi
            fi
        done
    else
        echo "No role assignment actually exists on [$aksResourceGroupName] resource group"
    fi

    # Get the kubelet managed identity used by the AKS cluster
    echo "Retrieving the kubelet identity from the [$aksName] AKS cluster..."
    clientId=$(az aks show \
        --name $aksName \
        --resource-group $aksResourceGroupName \
        --query identityProfile.kubeletidentity.clientId \
        --output tsv 2>/dev/null)

    if [[ -n $clientId ]]; then
        # Delete any role assignment to kubelet managed identity on any ACR in the resource group
        echo "kubelet identity of the [$aksName] AKS cluster successfully retrieved"
        echo "Retrieving the list of ACR resources in the [$aksResourceGroupName] resource group..."
        acrIds=$(az acr list \
            --resource-group $aksResourceGroupName \
            --query [].id \
            --output tsv)

        if [[ -n $acrIds ]]; then
            echo "[${#acrIds[@]}] ACR resources have been found in [$aksResourceGroupName] resource group"
            for acrId in ${acrIds[@]}; do
                if [[ -n $acrId ]]; then
                    acrName=$(echo $acrId | awk -F '/' '{print $NF}')
                    echo "Retrieving the list of role assignments on [$acrName] ACR..."
                    assignmentIds=$(az role assignment list \
                        --scope "$acrId" \
                        --query [].id \
                        --output tsv)

                    if [[ -n $assignmentIds ]]; then
                        echo "[${#assignmentIds[@]}] role assignments have been found on [$acrName] ACR"
                        for assignmentId in ${assignmentIds[@]}; do
                            if [[ -n $assignmentId ]]; then
                                az role assignment delete --ids $assignmentId

                                if [[ $? == 0 ]]; then
                                    assignmentName=$(echo $assignmentId | awk -F '/' '{print $NF}')
                                    echo "[$assignmentName] role assignment on [$acrName] ACR successfully deleted"
                                fi
                            fi
                        done
                    else
                        echo "No role assignment actually exists on [$acrName] ACR"
                    fi
                fi
            done
        else
            echo "No ACR actually exists in [$aksResourceGroupName] resource group"
        fi
    else
        echo "Failed to retrieve the kubelet identity of the [$aksName] AKS cluster"
    fi

    # Validate the ARM template
    if [[ $validateTemplate == 1 ]]; then
        if [[ $useWhatIf == 1 ]]; then
            # Execute a deployment What-If operation at resource group scope.
            echo "Previewing changes deployed by [$template] ARM template..."
            az deployment group what-if \
                --resource-group $aksResourceGroupName \
                --template-file $template \
                --parameters $parameters \
                --parameters aksClusterName=$aksName \
                aksClusterKubernetesVersion=$kubernetesVersion \
                acrName=$acrName

            if [[ $? == 0 ]]; then
                echo "[$template] ARM template validation succeeded"
            else
                echo "Failed to validate [$template] ARM template"
                exit
            fi
        else
            # Validate the ARM template
            echo "Validating [$template] ARM template..."
            output=$(az deployment group validate \
                --resource-group $aksResourceGroupName \
                --template-file $template \
                --parameters $parameters \
                --parameters aksClusterName=$aksName \
                aksClusterKubernetesVersion=$kubernetesVersion \
                acrName=$acrName)

            if [[ $? == 0 ]]; then
                echo "[$template] ARM template validation succeeded"
            else
                echo "Failed to validate [$template] ARM template"
                echo $output
                exit
            fi
        fi
    fi

    # Deploy the ARM template
    echo "Deploying [$template] ARM template..."
    az deployment group create \
        --resource-group $aksResourceGroupName \
        --only-show-errors \
        --template-file $template \
        --parameters $parameters \
        --parameters aksClusterName=$aksName \
        aksClusterKubernetesVersion=$kubernetesVersion \
        acrName=$acrName 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "[$template] ARM template successfully provisioned"
    else
        echo "Failed to provision the [$template] ARM template"
        exit
    fi
else
    echo "[$aksName] aks cluster already exists in the [$aksResourceGroupName] resource group"
fi

# Get the user principal name of the current user
echo "Retrieving the user principal name of the current user from the [$tenantId] Azure AD tenant..."
userPrincipalName=$(az account show --query user.name --output tsv)
if [[ -n $userPrincipalName ]]; then
    echo "[$userPrincipalName] user principal name successfully retrieved from the [$tenantId] Azure AD tenant"
else
    echo "Failed to retrieve the user principal name of the current user from the [$tenantId] Azure AD tenant"
    exit
fi

# Retrieve the objectId of the user in the Azure AD tenant used by AKS for user authentication
echo "Retrieving the objectId of the [$userPrincipalName] user principal name from the [$tenantId] Azure AD tenant..."
userObjectId=$(az ad user show --upn-or-object-id $userPrincipalName --query objectId --output tsv 2>/dev/null)

if [[ -n $userObjectId ]]; then
    echo "[$userObjectId] objectId successfully retrieved for the [$userPrincipalName] user principal name"
else
    echo "Failed to retrieve the objectId of the [$userPrincipalName] user principal name"
    exit
fi

# Retrieve the resource id of the AKS cluster
echo "Retrieving the resource id of the [$aksName] AKS cluster..."
aksClusterId=$(az aks show \
    --name "$aksName" \
    --resource-group "$aksResourceGroupName" \
    --query id \
    --output tsv 2>/dev/null)

if [[ -n $aksClusterId ]]; then
    echo "Resource id of the [$aksName] AKS cluster successfully retrieved"
else
    echo "Failed to retrieve the resource id of the [$aksName] AKS cluster"
    exit
fi

# Assign Azure Kubernetes Service RBAC Admin role to the current user
echo "Checking if [$userPrincipalName] user has been assigned to [Azure Kubernetes Service RBAC Admin] role on the [$aksName] AKS cluster..."
role=$(az role assignment list \
    --assignee $userObjectId \
    --scope $aksClusterId \
    --query [?roleDefinitionName].roleDefinitionName \
    --output tsv 2>/dev/null)

if [[ $role == "Owner" ]] || [[ $role == "Contributor" ]] || [[ $role == "Azure Kubernetes Service RBAC Admin" ]]; then
    echo "[$userPrincipalName] user is already assigned to the [$role] role on the [$aksName] AKS cluster"
else
    echo "[$userPrincipalName] user is not assigned to the [Azure Kubernetes Service RBAC Admin] role on the [$aksName] AKS cluster"
    echo "Assigning the [$userPrincipalName] user to the [Azure Kubernetes Service RBAC Admin] role on the [$aksName] AKS cluster..."

    az role assignment create \
        --role "Azure Kubernetes Service RBAC Admin" \
        --assignee $userObjectId \
        --scope $aksClusterId \
        --only-show-errors 1>/dev/null

    if [[ $? == 0 ]]; then
        echo "[$userPrincipalName] user successfully assigned to the [Azure Kubernetes Service RBAC Admin] role on the [$aksName] AKS cluster"
    else
        echo "Failed to assign the [$userPrincipalName] user to the [Azure Kubernetes Service RBAC Admin] role on the [$aksName] AKS cluster"
        exit
    fi
fi