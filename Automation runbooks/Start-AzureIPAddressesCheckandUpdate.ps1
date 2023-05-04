#####################################################################################
## Azure Automation Runbook to check, store, update Azure public IP Address ranges ##
## for Azure resources in an Azure Storage Table                                   ##
#####################################################################################

# Storage Account parameters
$Subscription = "<MySubscriptionName"
$ResourceGroupName = "<ResourceGroupName>"
$StorageAccountName = "<StorageAccountName>"
$TableName = "AzureIPRanges"
$AzureServiceTagName = "AzureFrontDoor.Backend" # Could be any Azure service tag

# Email params
$EmailParams = @{
    To         = 'joe.bloggs@contoso.com'
    From       = 'automation@contoso.com'
    Smtpserver = 'contoso.mail.protection.outlook.com'
    Port       = 25
    Subject    = "Azure IP Address Range Changes  |  $(Get-Date -Format dd-MMM-yyyy)"
}

# Html CSS style 
$Style = @"
<style>
table { 
    border-collapse: collapse;
    font-family: sans-serif
    font-size: 12px
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

# Get direct download URL
$ProgressPreference = 'SilentlyContinue'
$URL = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519"
$WebPage = Invoke-WebRequest -Uri $URL -UseBasicParsing
$DownloadURL = ($WebPage.Links | Where {$_.href -match "ServiceTags"} | Select -First 1).href

# Extract some metadata
$FileName = $DownloadURL.Split('/')[-1]
$FileDate = $FileName.Split('_')[-1].Trimend('.json')
$Year = $FileDate.Substring(0,4)
$Month = $FileDate.Substring(4,2)
$Day = $FileDate.Substring(6,2)
$DocumentDate = Get-Date -Year $Year -Month $Month -Day $Day -Format "yyyy-MMM-dd"

# Connect to storage account
$null = Add-AzAccount -Subscription $Subscription -Identity
$sa = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$ctx = $sa.Context

# Get or create the table
try 
{
    $storageTable = Get-AzStorageTable -Name $TableName -Context $ctx -ErrorAction Stop
}
catch [Microsoft.WindowsAzure.Commands.Storage.Common.ResourceNotFoundException]
{
    $storageTable = New-AzStorageTable -Name $TableName -Context $ctx
    Write-Output "Created Azure Storage Table '$TableName'"
    $firstRun = $true
}
$cloudTable = $storageTable.CloudTable

# Not running for the first time - table already exists
if ($firstRun -ne $true)
{
    # Get the current table rows
    $CurrentRows = Get-AzTableRow -table $cloudTable

    # Check Document date
    $CurrentDate = $CurrentRows.Where({$_.PartitionKey -eq "Date" -and $_.RowKey -eq "Document"}) | Select -ExpandProperty Value
    $CurrentChangeNumber = $CurrentRows.Where({$_.PartitionKey -eq "ChangeNumber" -and $_.RowKey -eq "Document"}) | Select -ExpandProperty Value
    If ($CurrentDate -eq $DocumentDate)
    {
        Write-Output "The latest document date is $DocumentDate. There are no updates at this time."
        Exit 0
    }
    else 
    {
        Write-Output "A new document was found with date $DocumentDate. Downloading..."
        # Download the json file
        Invoke-WebRequest -Uri $DownloadURL -OutFile $env:TEMP\$FileName -UseBasicParsing

        # Read the json
        $FileContent = Get-Content -Path $env:TEMP\$FileName
        $Json = $FileContent | ConvertFrom-Json
        $ChangeNumber = $json | where {$_.cloud -eq 'Public'} | Select -ExpandProperty changeNumber
        $ResourceValues = $json | where {$_.cloud -eq 'Public'} | Select -ExpandProperty values

        # Compare changeNumbers
        If ($ChangeNumber -eq $CurrentChangeNumber)
        {
            Write-Output "The change number for the document is the same in the latest document - there are no updates to process."
            Exit 0
        }

        # Get the Azure Front Door backend data
        $AFDResource = $ResourceValues | Where {$_.name -eq "$AzureServiceTagName"}
        $AFDChangeNumber = $AFDResource.properties.changeNumber
        $AFDIPv4AddressPrefixes = $AFDResource.properties.addressPrefixes | where {$_ -notmatch ":"}  
        $CurrentAFDChangeNumber = $CurrentRows.Where({$_.PartitionKey -eq "ChangeNumber" -and $_.RowKey -eq "$AzureServiceTagName"}) | Select -ExpandProperty Value

        # Compare AFD changeNumbers
        If ($AFDChangeNumber -eq $CurrentAFDChangeNumber)
        {
            Write-Output "The change number for $AzureServiceTagName is the same in the latest document - there are no updates to process."
        }
        else 
        {
            # Check for any IPaddress changes
            $NewIPs = @()
            $RetiredIPs = @()
            $CurrentIPRanges = $CurrentRows.Where({$_.PartitionKey -eq "$AzureServiceTagName"}) | Select -ExpandProperty Value
            foreach ($IP in $AFDIPv4AddressPrefixes)
            {
                if ($CurrentIPRanges -notcontains $IP)
                {
                    $NewIPs += $IP
                    Write-Output "New IP address range found: $IP"
                }
            }
            foreach ($IP in $CurrentIPRanges)
            {
                if ($AFDIPv4AddressPrefixes -notcontains $IP)
                {
                    $RetiredIPs += $IP
                    Write-Output "IP address range retired: $IP"
                }
            }

            # Add any new, remove any old
            If ($NewIPs.Count -eq 0 -and $RetiredIPs.Count -eq 0)
            {
                Write-Output "There are no new or retired IP ranges"
            }
            If ($NewIPs.Count -ge 1)
            {
                foreach ($NewIP in $NewIPs)
                {
                    $Result = Add-AzTableRow -Table $cloudTable -PartitionKey "$AzureServiceTagName" -RowKey ([Guid]::NewGuid().Guid.SubString(0,8)) -property @{"Value"="$NewIP"}
                    If ($Result.HttpStatusCode -ne 204)
                    {
                        Write-Warning "Failed to add row for AddressPrefix $NewIP. Status code $($Result.HttpStatusCode) was unexpected"
                        throw
                    }
                    else 
                    {
                        Write-Output "Added new IP range to storage table: $NewIP"    
                    }
                }
            }
            If ($RetiredIPs.Count -ge 1)
            {
                foreach ($RetiredIP in $RetiredIPs)
                {
                    $RowKey = $CurrentRows.Where({$_.PartitionKey -eq "$AzureServiceTagName" -and $_.Value -eq "$RetiredIP"}) | Select -ExpandProperty RowKey
                    $RowToRetire = Get-AzTableRow -Table $cloudTable -PartitionKey "$AzureServiceTagName" -RowKey $RowKey
                    If ($null -ne $RowToRetire)
                    {
                        $result = $RowToRetire | Remove-AzTableRow -Table $cloudTable
                        If ($Result.HttpStatusCode -ne 204)
                        {
                            Write-Warning "Failed to delete row for AddressPrefix $RetiredIP. Status code $($Result.HttpStatusCode) was unexpected"
                            throw
                        }
                        else 
                        {
                            Write-Output "Removed retired IP range from storage table: $RetiredIP"    
                        }
                    }
                }
            }

            If ($NewIPs.Count -ge 1 -or $RetiredIPs.Count -ge 1)
            {
                $DataTable = [System.Data.DataTable]::new()
                [void]$DataTable.Columns.Add("New IP Ranges")
                [void]$DataTable.Columns.Add("Retired IP Ranges")
                [void]$DataTable.Rows.Add("$($NewIPs -join ', ')","$($RetiredIPs -join ', ')")
                $HTML += ($DataTable | 
                        ConvertTo-Html -Property 'New IP Ranges','Retired IP Ranges' -Head $Style -Body "<h2>$AzureServiceTagName</h2>"  | 
                        Out-String)
                try 
                {
                    Send-MailMessage @EmailParams -Body $html -BodyAsHtml -ErrorAction Stop 
                    Write-Output "Changes sent by email"
                }
                catch 
                {
                    Write-Error "Failed to send email: $($_.Exception.Message)"
                } 
            }

        }

        # Update the change numbers and date in the table.
        $DocumentDateRow = Get-AzTableRow -Table $cloudTable -PartitionKey "Date" -RowKey "Document"
        $DocumentDateRow.Value = $DocumentDate
        $Result = $DocumentDateRow | Update-AzTableRow -Table $cloudTable
        If ($Result.HttpStatusCode -ne 204)
        {
            Write-Warning "Failed to update Document Date row. Status code $($Result.HttpStatusCode) was unexpected"
            throw
        }
        else 
        {
            Write-Output "Updated Document Date in Azure table to $DocumentDate"    
        }
        $DocumentChangeNumberRow = Get-AzTableRow -Table $cloudTable -PartitionKey "ChangeNumber" -RowKey "Document"
        $DocumentChangeNumberRow.Value = $ChangeNumber
        $Result = $DocumentChangeNumberRow | Update-AzTableRow -Table $cloudTable
        If ($Result.HttpStatusCode -ne 204)
        {
            Write-Warning "Failed to update Document ChangeNumber row. Status code $($Result.HttpStatusCode) was unexpected"
            throw
        }
        else 
        {
            Write-Output "Updated Document Change Number in Azure table to $ChangeNumber"    
        }
        If ($AFDChangeNumber -ne $CurrentAFDChangeNumber)
        {
            $AFDChangeNumberRow = Get-AzTableRow -Table $cloudTable -PartitionKey "ChangeNumber" -RowKey "$AzureServiceTagName"
            $AFDChangeNumberRow.Value = $AFDChangeNumber
            $Result = $AFDChangeNumberRow | Update-AzTableRow -Table $cloudTable
            If ($Result.HttpStatusCode -ne 204)
            {
                Write-Warning "Failed to update $AzureServiceTagName ChangeNumber row. Status code $($Result.HttpStatusCode) was unexpected"
                throw
            }
            else 
            {
                Write-Output "Updated $AzureServiceTagName Change Number in Azure table to $AFDChangeNumber"    
            }
        }
    }
}
# Running for the first time - table didn't exist, populate the rows
else 
{
    # Download the json file
    Invoke-WebRequest -Uri $DownloadURL -OutFile $env:TEMP\$FileName -UseBasicParsing

    # Read the json
    $FileContent = Get-Content -Path $env:TEMP\$FileName
    $Json = $FileContent | ConvertFrom-Json
    $ChangeNumber = $json | where {$_.cloud -eq 'Public'} | Select -ExpandProperty changeNumber
    $ResourceValues = $json | where {$_.cloud -eq 'Public'} | Select -ExpandProperty values

    # Get the Azure Front Door backend data
    $AFDResource = $ResourceValues | Where {$_.name -eq "$AzureServiceTagName"}
    $AFDChangeNumber = $AFDResource.properties.changeNumber
    $AFDIPv4AddressPrefixes = $AFDResource.properties.addressPrefixes | where {$_ -notmatch ":"}  
    
    # Create the document change number row
      $Result = Add-AzTableRow -Table $cloudTable -PartitionKey "ChangeNumber" -RowKey "Document" -property @{"Value"="$ChangeNumber"}
      If ($Result.HttpStatusCode -ne 204)
      {
          Write-Warning "Failed to add row for document change number. Status code $($Result.HttpStatusCode) was unexpected"
          throw
      }
  
      # Create the document date row
      $Result = Add-AzTableRow -Table $cloudTable -PartitionKey "Date" -RowKey "Document" -property @{"Value"="$DocumentDate"}
      If ($Result.HttpStatusCode -ne 204)
      {
          Write-Warning "Failed to add row for document date. Status code $($Result.HttpStatusCode) was unexpected"
          throw
      }
  
      # Create the AFD change number row
      $Result = Add-AzTableRow -Table $cloudTable -PartitionKey "ChangeNumber" -RowKey "$AzureServiceTagName" -property @{"Value"="$AFDChangeNumber"}
      If ($Result.HttpStatusCode -ne 204)
      {
          Write-Warning "Failed to add row for AFD change number. Status code $($Result.HttpStatusCode) was unexpected"
          throw
      }
  
      # Create the IPv4 Address rows
      foreach ($addressPrefix in $AFDIPv4AddressPrefixes)
      {
          $Result = Add-AzTableRow -Table $cloudTable -PartitionKey "$AzureServiceTagName" -RowKey ([Guid]::NewGuid().Guid.SubString(0,8)) -property @{"Value"="$addressPrefix"}
          If ($Result.HttpStatusCode -ne 204)
          {
              Write-Warning "Failed to add row for AddressPrefix $addressPrefix. Status code $($Result.HttpStatusCode) was unexpected"
              throw
          }
      }
      
      Write-Output "Azure Storage Table has been populated with the current data"
      Exit 0
}