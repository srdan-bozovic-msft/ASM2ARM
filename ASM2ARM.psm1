function NewAuthHeader
{
    $context = Get-AzureRmContext

    if($null -eq $context.Account)
    {
        throw "You need to login first."
    }

    if($null -eq $context.Subscription)
    {
        throw "You need to assign subscription or login to proper Azure Environment."
    }
    
    $azureRmProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile;
    $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azureRmProfile);
    $accessToken = $profileClient.AcquireAccessToken($context.Subscription.TenantId).AccessToken;
    
    @{
        'Content-Type' = 'application/xml'
        'x-ms-aad-authorization' = "Bearer $accessToken"
        'x-ms-version' = '2017-01-01'
    }
}

function InvokeAsmMethod($method, $uri, $body)
{
    $context = Get-AzureRmContext
    $subscriptionId = $context.Subscription.Id
    $serviceManagementUrl = $context.Environment.ServiceManagementUrl

    $headers = NewAuthHeader

    $uri = $serviceManagementUrl + $subscriptionId + $Uri

    $result = Invoke-WebRequest -Uri $uri -Method $method -Headers $headers -Body $body

    if($result.StatusCode -eq 202)
    {
        $requestId = $result.Headers['x-ms-request-id']
        while($true)
        {
            $uri = "/operations/$requestId"        
            $result = InvokeAsmMethod -Uri $uri -Method Get
            $status = $result.Operation.Status
            if($status -eq "InProgress")
            {
                Start-Sleep -Milliseconds 200
            }
            else
            {
                return $result.Operation
            }
        }
    }
    else
    {
        $result = [xml]$result.Content
        $result.DocumentElement.Attributes.RemoveAll()
        $result
    }
}

function HandleException($exception)
{
    if($null -ne $exception.CategoryInfo -and  $exception.CategoryInfo.Reason -eq "WebException")
    {
        $error = [xml]$exception.ErrorDetails.Message
        Write-Host $error.Error.Message -ForegroundColor Red
    }
    else
    {
        Write-Host $exception.Exception.Message -ForegroundColor Red
    }
}

function Get-AzureRmService
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $ServiceName,
        [Parameter(Mandatory = $false)]
        [string]
        $Slot
    )

    try
    {
        if([string]::IsNullOrEmpty($ServiceName))
        {
            $uri = "/services/hostedservices"        
            $result = InvokeAsmMethod -Uri $uri -Method Get
            return $result.HostedServices.HostedService
        }
        else
        {
            if([string]::IsNullOrEmpty($Slot))
            {
                $uri = "/services/hostedservices/$ServiceName"
                $result = InvokeAsmMethod -Uri $uri -Method Get
                return $result.HostedService
            }
            else
            {
                $uri = "/services/hostedservices/$ServiceName/deploymentslots/$Slot"        
                $result = InvokeAsmMethod -Uri $uri -Method Get
                return $result.Deployment
            }
        }
    }
    catch
    {
        HandleException -exception $_
    }
}

function Get-AzureRmReservedIP
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]
        $ReservedIPName
    )

    try
    {
        if([string]::IsNullOrEmpty($ReservedIPName))
        {
            $uri = "/services/networking/reservedips"        
            $result = InvokeAsmMethod -Uri $uri -Method Get
            return $result.ReservedIPs.ReservedIP
        }
        else
        {
            $uri = "/services/networking/reservedips/$ReservedIPName"        
            $result = InvokeAsmMethod -Uri $uri -Method Get
            return $result.ReservedIP
        }
    }
    catch
    {
        HandleException -exception $_
    }
}

function New-AzureRmReservedIP
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ReservedIPName,
        [Parameter(Mandatory = $true)]
        [string]
        $Location,
        [Parameter(Mandatory = $false)]
        [string]
        $Label,
        [Parameter(Mandatory = $false)]
        [string]
        $ServiceName,
        [Parameter(Mandatory = $false)]
        [string]
        $Slot,
        [Parameter(Mandatory = $false)]
        [object[]]
        $IPTagList
    )

    try
    {
    
        $deploymentName = ""
        
        $labelXml = ""
        if(-not [string]::IsNullOrEmpty($Label))
        {
            $labelXml = "<Label>$Label</Label>"
        }

        $serviceNameXml = ""
        $ipTagsXml = ""
        if(-not [string]::IsNullOrEmpty($ServiceName))
        {
            $serviceNameXml = "<ServiceName>$ServiceName</ServiceName>"
            
            if([string]::IsNullOrEmpty($Slot))
            {
                $Slot = "Production"
            }

            $uri = "/services/hostedservices/$ServiceName/deploymentslots/$Slot"        
            $result = InvokeAsmMethod -Uri $uri -Method Get
            $deploymentName = $result.Deployment.Name
        }
        elseif ($null -ne $IPTagList)
        {
            $ipTagsXml = "<IPTags>"   
            foreach($ipTag in $IPTagList)
            {
                $ipTagsXml += 
@"
                    <IPTag>
                      <IPTagType>$($ipTag.IPTagType)</IPTagType>
                      <Value>$($ipTag.Value)</Value>
                    </IPTag>

"@
            }
            $ipTagsXml += "</IPTags>"
        }

        $uri = "/services/networking/reservedips"

        $body = 
@"
    <ReservedIP xmlns="http://schemas.microsoft.com/windowsazure">
    	<Name>$($ReservedIPName)</Name>
        $($labelXml)
        $($serviceNameXml)
    	<DeploymentName>$($deploymentName)</DeploymentName>
    	<Location>$($Location)</Location>
        $($ipTagsXml)
    </ReservedIP>
"@
                
        InvokeAsmMethod -Uri $uri -Method Post -body $body
    }
    catch
    {
        HandleException -exception $_
    }
}

function Remove-AzureRmReservedIPAssociation
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ReservedIPName,
        [Parameter(Mandatory = $true)]
        [string]
        $ServiceName,
        [Parameter(Mandatory = $false)]
        [string]
        $Slot
    )

    try
    {
    
        $deploymentName = ""
        
        if([string]::IsNullOrEmpty($Slot))
        {
            $Slot = "Production"
        }

        $uri = "/services/hostedservices/$ServiceName/deploymentslots/$Slot"        
        $result = InvokeAsmMethod -Uri $uri -Method Get
        $deploymentName = $result.Deployment.Name


        $uri = "/services/networking/reservedips/$ReservedIPName/operations/disassociate"

        $body = 
@"
        <ReservedIPAssociation xmlns="http://schemas.microsoft.com/windowsazure">
          <ServiceName>$($ServiceName)</ServiceName>
          <DeploymentName>$($deploymentName)</DeploymentName>
        </ReservedIPAssociation>
"@
                
        InvokeAsmMethod -Uri $uri -Method Post -body $body
    }
    catch
    {
        HandleException -exception $_
    }
}

function Remove-AzureRmReservedIP
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]
        $ReservedIPName
    )

    try
    {
        $uri = "/services/networking/reservedips/$ReservedIPName"        
        InvokeAsmMethod -Uri $uri -Method Delete
    }
    catch
    {
        HandleException -exception $_
    }
}

Export-ModuleMember -Function "Get-*"
Export-ModuleMember -Function "New-*"
Export-ModuleMember -Function "Remove-*"


