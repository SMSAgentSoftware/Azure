#############################################################
##                AZURE AUTOMATION RUNBOOK                 ##
##                                                         ##
## Retrieves activity log events for an Azure subscription ##
## and sends a summary email                               ##
#############################################################

# Parameters
$TenantId = "<tenantId>"
$SubscriptionId = "<subscriptionId>"
$SubscriptionName = "<subscriptionName>"
$TimespanHours = 24
$EmailParams = @{
    To         = 'joe.bloggs@contoso.com'
    From       = 'AzureReports@contoso.com'
    Smtpserver = 'contoso-com.mail.protection.outlook.com'
    Port       = 25
    Subject    = "Azure Subscription Activity Log Summary  |  $SubscriptionName  |  $(Get-Date -Format 'dd-MMM-yyyy HH:mm')"
}

# Html CSS style 
$Style = @"
<style>
table { 
    border-collapse: collapse;
    font-family: sans-serif
    font-size: 10px
}
td, th { 
    border: 1px solid #ddd;
    padding: 6px;
}
th {
    padding-top: 8px;
    padding-bottom: 8px;
    text-align: left;
    background-color: #3700B3;
    color: #03DAC6
}
</style>
"@

# Function to get the activity log events for the subscription
Function Get-AzSubscriptionActivityLog {
    [CmdletBinding(HelpUri = 'https://docs.smsagent.blog/powershell-scripts-online-help/get-azsubscriptionactivitylog')]
    Param
    (       
        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=0)]
        [ValidateScript({[guid]::TryParse($_, $([ref][guid]::Empty)) -eq $true})]
        [string]$TenantId,
  
        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true,Position=1)]
        [ValidateScript({[guid]::TryParse($_, $([ref][guid]::Empty)) -eq $true})]
        [string]$SubscriptionID,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=2)]
        [int]$TimespanHours = 6,
        
        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=3)]
        [switch]$IncludeProperties,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=4)]
        [switch]$IncludeListAndGetOperations,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=5)]
        [ValidateSet("Application","ManagedIdentity","Service","User",$null)]
        [string[]]$IdentityType,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=6)]
        [ValidateSet("Informational","Warning","Error","Critical")]
        [string[]]$Level,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=7)]
        [string[]]$Category,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=8)]
        [string[]]$Caller,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=9)]
        [string[]]$ResourceGroupName,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=10)]
        [string[]]$ResourceProviderName,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=11)]
        [string]$ResourceIdMatch,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=12)]
        [string[]]$ResourceType,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=13)]
        [string[]]$OperationName,

        [Parameter(Mandatory=$false,ValueFromPipelineByPropertyName=$true,Position=14)]
        [ValidateSet("Accepted","Started","Succeeded","Failed")]
        [string[]]$Status
    )

    # Suppress progress bar to speed up web requests
    $ProgressPreference = 'SilentlyContinue'
    
    # Check for the Az.Accounts module
    $AzAccountsModule = Get-Module Az.Accounts -ListAvailable -ErrorAction SilentlyContinue
    If ($null -eq $AzAccountsModule)
    {
        throw "Please install the Az.Accounts module"
    }

    # Function to invoke a web request with error handling
    Function script:Invoke-WebRequestPro {
        Param ($URL,$Headers,$Method)
        try 
        {
            $WebRequest = Invoke-WebRequest -Uri $URL -Method $Method -Headers $Headers -UseBasicParsing
        }
        catch 
        {
            $Response = $_
            $WebRequest = [PSCustomObject]@{
                Message = $response.Exception.Message
                StatusCode = $response.Exception.Response.StatusCode
                StatusDescription = $response.Exception.Response.StatusDescription
            }
        }
        Return $WebRequest
    }

    # Get an access token for the management API
    try 
    {
        # requires 'reader' role or 'monitoring contributer' role or custom role.
        $Token = Get-AzAccessToken -ResourceUrl "https://management.azure.com" -TenantId $TenantId -ErrorAction Stop
        $AccessToken = $Token.Token  
    }
    catch 
    {
        throw $_
    }
    
    # Call the management API to retrieve the events   
    # ref: https://docs.microsoft.com/en-us/rest/api/monitor/activity-logs/list?tabs=HTTP
    $ApiVersion = "2017-03-01-preview"
    $EndDate = (Get-Date).ToUniversalTime() | Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $StartDate = (Get-Date).AddHours(-$TimespanHours).ToUniversalTime() | Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $filter = "eventTimestamp ge '$StartDate' and eventTimestamp le '$EndDate' and eventChannels eq 'Admin, Operation' and levels eq 'Critical,Error,Warning,Informational'" 
    If ($Level)
    {
        $filter = "eventTimestamp ge '$StartDate' and eventTimestamp le '$EndDate' and eventChannels eq 'Admin, Operation' and levels eq '$level'"
    }
    
    If ($IncludeProperties)
    {
        $select = "caller,channels,correlationId,eventDataId,eventName,category,httpRequest,level,resourceGroupName,resourceProviderName,resourceId,resourceType,operationName,properties,status,subStatus,eventTimestamp,submissionTimestamp"
    }
    else 
    {
        $select = "caller,channels,correlationId,eventDataId,eventName,category,httpRequest,level,resourceGroupName,resourceProviderName,resourceId,resourceType,operationName,status,subStatus,eventTimestamp,submissionTimestamp"
    }
    
    $URL = "https://management.azure.com/subscriptions/$SubscriptionId/providers/microsoft.insights/eventtypes/management/values?api-version=$ApiVersion&`$filter=$filter&`$select=$select"

    $headers = @{'Authorization'="Bearer " + $AccessToken}
    $WebRequest = Invoke-WebRequestPro -URL $URL -Headers $headers -Method GET
    If ($WebRequest.StatusCode -eq 200)
    {
        $Content = $WebRequest.Content | ConvertFrom-JSON
        If ($Content.value.length -gt 0)
        {
            [array]$Events += $Content.value
            # loop if there are more events to get
            If ($Content.nextLink)
            {
                do {
                    $URL = $Content.nextLink
                    $headers = @{'Authorization'="Bearer " + $AccessToken}
                    $WebRequest = Invoke-WebRequestPro -URL $URL -Headers $headers -Method GET
                    If ($WebRequest.StatusCode -eq 200)
                    {
                        $Content = $WebRequest.Content | ConvertFrom-Json
                        [array]$Events += $Content.value
                    }
                    else 
                    {
                        throw $WebRequest    
                    }                 
                } until ($null -eq $Content.nextLink)
            }
            else 
            {
                [array]$Events = $Content.value
            }   
        }
        ElseIf ($Content.value -and $Content.value.length -eq 0)
        {
            [array]$Events = $null
        }
        Else
        {
            [array]$Events = $Content
        }
    }
    else 
    {
        throw $WebRequest    
    }

    If ($Events)
    {
        # Filter out "List" and "Get Token" events unless asked not to
        If ($IncludeListAndGetOperations)
        {
            $FilteredEvents = $Events | Sort -Property eventTimestamp -Descending
        }
        Else
        {
            $FilteredEvents = $Events | where {$_.operationName -notmatch "List" -and $_.operationName -notmatch "Get Token"} | Sort -Property eventTimestamp -Descending
        }
            
        # Find caller identities with a GUID
        [array]$Identities = $FilteredEvents.caller | group-object -NoElement | Select -ExpandProperty name | Where {[guid]::TryParse($_, $([ref][guid]::Empty)) -eq $true} | Sort-Object

        # Now let's get the servicePrincipal friendly names from their GUIDs
        If ($Identities.Count -ge 1)
        {
            # Get an access token for Microsoft Graph
            try 
            {
                # requires Directory.Read.All permission
                $Token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId -ErrorAction Stop
                $AccessToken = $Token.Token  
            }
            catch 
            {
                throw $_
            }

            foreach ($Identity in $Identities)
            {
                # ref https://docs.microsoft.com/en-us/graph/api/serviceprincipal-list?view=graph-rest-beta&tabs=http
                $URL = "https://graph.microsoft.com/beta/servicePrincipals?`$filter=id eq '$Identity'&`$select=id,displayName,servicePrincipalType"
                $headers = @{'Authorization'="Bearer " + $AccessToken}
                $WebRequest = Invoke-WebRequestPro -URL $URL -Headers $headers -Method GET
                If ($WebRequest.StatusCode -eq 200)
                {
                    $Content = $WebRequest.Content | ConvertFrom-JSON
                    If ($Content.value.length -gt 0)
                    {
                        [array]$servicePrincipals += $Content.value
                    }
                }
                else 
                {
                    throw $WebRequest    
                }
            }
        }

        # Suppress console errors temporarily in case some events have no resourceId
        $ErrorActionPreferenceCurrent = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'

        # Process each event into more meaningful objects
        $EventArray = @()
        foreach ($FilteredEvent in $FilteredEvents)
        {
            # Translate the identity GUID into a friendly name
            If ([guid]::TryParse($FilteredEvent.caller, $([ref][guid]::Empty)) -eq $true)
            {
                $Identity = $servicePrincipals.Where({$_.id -eq $FilteredEvent.caller})
                $callerString = $Identity.displayName
                $identityTypeString = $Identity.servicePrincipalType
            }
            ElseIf ($FilteredEvent.caller -match "@")
            {
                $callerString = $FilteredEvent.caller
                $identityTypeString = "User"
            }
            ElseIf  ($null -eq $FilteredEvent.caller)
            {
                $callerString = $null
                $identityTypeString = $null
            }
            Else
            {
                $callerString = $FilteredEvent.caller
                $identityTypeString = "Service"
            }

            $resourceProviderNameString = $FilteredEvent.resourceProviderName.localizedValue
            $eventObject = [PSCustomObject]@{
                caller = $callerString
                identityType = $identityTypeString
                channels = $FilteredEvent.channels
                eventName = $FilteredEvent.eventName.localizedValue
                category = $FilteredEvent.category.localizedValue
                level = $FilteredEvent.level
                resourceGroupName = $FilteredEvent.resourceGroupName
                resourceProviderName = $resourceProviderNameString
                resourceId = $FilteredEvent.resourceId.Substring($FilteredEvent.resourceId.IndexOf($resourceProviderNameString)).Replace($resourceProviderNameString,"")
                resourceType = $FilteredEvent.resourceType.localizedValue
                operationName = $FilteredEvent.operationName.localizedValue
                status = $FilteredEvent.status.localizedValue
                subStatus = $FilteredEvent.subStatus.localizedValue
                eventTimestamp = $FilteredEvent.eventTimestamp
                submissionTimestamp = $FilteredEvent.submissionTimestamp
               }
            If ($IncludeProperties)
            {
                $eventObject | Add-Member -MemberType NoteProperty -Name properties -Value $FilteredEvent.properties
            }
            $EventArray += $eventObject
        }
        $ErrorActionPreference = $ErrorActionPreferenceCurrent

        # Apply any requested filters to the results
        If ($IdentityType)
        {
            $EventArray = $EventArray | Where-Object {$_.identityType -in $IdentityType}
        }
        If ($Category)
        {
            $EventArray = $EventArray | Where-Object {$_.category -in $Category}
        }
        If ($Caller)
        {
            $EventArray = $EventArray | Where-Object {$_.caller -in $Caller}
        }
        If ($ResourceGroupName)
        {
            $EventArray = $EventArray | Where-Object {$_.resourceGroupName -in $ResourceGroupName}
        }
        If ($ResourceProviderName)
        {
            $EventArray = $EventArray | Where-Object {$_.resourceProviderName -in $ResourceProviderName}
        }
        If ($ResourceIdMatch)
        {
            $EventArray = $EventArray | Where-Object {$_.resourceId -match $ResourceIdMatch}
        }
        If ($ResourceType)
        {
            $EventArray = $EventArray | Where-Object {$_.resourceType -in $ResourceType}
        }
        If ($OperationName)
        {
            $EventArray = $EventArray | Where-Object {$_.operationName -in $OperationName}
        }
        If ($Status)
        {
            $EventArray = $EventArray | Where-Object {$_.status -in $Status}
        }

        return $EventArray
    }
}

# Connect to Azure
Connect-AzAccount -Identity -Tenant $TenantId -Subscription $SubscriptionId

# Get the activity log events
$ActivityLog = Get-AzSubscriptionActivityLog -TenantId $TenantId -SubscriptionID $SubscriptionId -TimespanHours $TimespanHours

If ($ActivityLog.Count -ge 1)
{
    # Group events by caller and operation name
    $Group = $ActivityLog | Group-Object -Property caller,operationName -NoElement

    # Convert the array into a table
    $Table = [System.Data.DataTable]::new()
    [void]$Table.Columns.Add('Count',[int])
    [void]$Table.Columns.Add('Caller',[string])
    [void]$Table.Columns.Add('Operation',[string])
    foreach ($Item in $Group)
    {
        $Count = $Item.Count
        If ($Item.Name -match ",")
        {
            $Caller = $Item.Name.Split(',')[0]
            $Operation = $Item.Name.Split(',')[1].Trim()
        }
        Else 
        {
            $Caller = $null
            $Operation = $Item.Name   
        }
        [void]$Table.Rows.Add($Count,$Caller,$Operation)
    }
        
    # Sort the table
    $Table.DefaultView.Sort = "Caller asc, Count desc, Operation asc"
    $Table = $Table.DefaultView.ToTable($true)

    # Prepare the HTML
    $Precontent = "<h3>Summary of Activity Log Events for the last $TimespanHours hours in the Azure subscription '$SubscriptionName'</h3>"
    $HTML = $Table |
    ConvertTo-Html -Property Count,Caller,Operation -Head $Style -PreContent $Precontent |
    Out-String

    # Send email
    Send-MailMessage @EmailParams -Body $HTML -BodyAsHtml 
}