
$Start = Get-Date

$NinjaOneInstance = Ninja-Property-Get ninjaoneInstance
$NinjaOneClientID = Ninja-Property-Get ninjaoneClientId
$NinjaOneClientSecret = Ninja-Property-Get ninjaoneClientSecret

$OverviewCompany = 'Global Overview'
$SummaryField = 'deviceAlertSummary'

try {

    if (!(Get-Module -Name "NinjaOneDocs")) {
        $Null = Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
        Install-Module -Name 'NinjaOneDocs' -Force -MinimumVersion 1.1.0
        Import-Module 'NinjaOneDocs'
    } else {
        Update-Module NinjaOneDocs -Force
        Import-Module 'NinjaOneDocs'
    }

    # Fix for PSCustomObjects being broken in 7.4.0
    $ExecutionContext.SessionState.LanguageMode = 'FullLanguage'



    function Get-AlertsTable ($Alerts, $MaxChars) {
        [System.Collections.Generic.List[string]]$ParsedTable = @()
        $ParsedTable.add('<table>')
        $ParsedTable.add('<tr><th>Created</th><th>Device</th><th>Organization</th><th style="white-space: nowrap;">Severity</th><th style="white-space: nowrap;">Priority</th><th style="white-space: nowrap;">Last 30 Days</th><th>Message</th></tr>')

        foreach ($ParsedAlert in $Alerts) {
            $HTML = '<tr class="' + $ParsedAlert.RowClass + '">' +
            '<td style="white-space: nowrap;">' + ($ParsedAlert.Created).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss") + '</td>' +
            '<td style="white-space: nowrap;"><a href="https://' + $NinjaOneInstance + '/#/deviceDashboard/' + $ParsedAlert.DeviceID + '/overview">' + $ParsedAlert.Device + '</a></td>' +
            '<td style="white-space: nowrap;"><a href="https://' + $NinjaOneInstance + '/#/customerDashboard/2/' + $ParsedAlert.OrgID + '/overview">' + $ParsedAlert.OrgName + '</a></td>' +
            '<td style="white-space: nowrap;"><i style="color: ' + $ParsedAlert.SeverityColour + ';" class="' + $ParsedAlert.SeverityIcon + '"></i> ' + (Get-Culture).TextInfo.ToTitleCase($ParsedAlert.Severity.ToLower()) + '</td>' +
            '<td style="white-space: nowrap;"><i style="color: ' + $ParsedAlert.PiorityColour + ';" class="' + $ParsedAlert.PiorityIcon + '"></i> ' + (Get-Culture).TextInfo.ToTitleCase($ParsedAlert.Piority.ToLower()) + '</td>' +
            '<td style="white-space: nowrap;">' + $ParsedAlert.Last30Days + '</td>' +
            '<td>' + ($ParsedAlert.Message).Substring(0, [Math]::Min(($ParsedAlert.Message).Length, $MaxChars)) + '</td>' + '</tr>'

            $ParsedTable.add($HTML)
        }

        $ParsedTable.add('</table>')

        Return $ParsedTable
    }


    Connect-NinjaOne -NinjaOneInstance $NinjaOneInstance -NinjaOneClientID $NinjaOneClientID -NinjaOneClientSecret $NinjaOneClientSecret
    Write-Output "$(Get-Date): Fetching Core Data"
    $Alerts = Invoke-NinjaOneRequest -Method GET -Path 'alerts' -Paginate
    $Devices = Invoke-NinjaOneRequest -Method GET -Path 'devices' -Paginate
    $Organizations = Invoke-NinjaOneRequest -Method GET -Path 'organizations' -Paginate
    $Locations = Invoke-NinjaOneRequest -Method GET -Path 'locations' -Paginate


    Write-Output "$(Get-Date): Fetching Activities"

    $31DaysAgo = Get-NinjaOneTime -Date ((Get-Date).adddays(-31)) -Seconds
    [System.Collections.Generic.List[PSCustomObject]]$Activities = (Invoke-NinjaOneRequest -Method GET -Path 'activities' -QueryParams "status=TRIGGERED&pageSize=1000&after=$31DaysAgo").activities

    $Count = ($Activities.id | measure-object -Minimum).minimum

    $PageSize = 1000

    $Found = $False
 
    do {

        $Result = Invoke-NinjaOneRequest -Method GET -Path 'activities' -QueryParams "status=TRIGGERED&pageSize=$($PageSize)&olderThan=$($Count)&after=$31DaysAgo"

        if (($Result.Activities | Measure-Object).count -gt 0) {
            $Activities.AddRange([System.Collections.Generic.List[PSCustomObject]]$Result.Activities)
            $Count = ($Result.Activities.id | measure-object -Minimum).Minimum
            $Measurement = $($Result.Activities.id | measure-object -Minimum -Maximum)
            Write-Host "Min: $($Measurement.Minimum) Max: $($Measurement.Maximum)"
        } else {
            $Found = $True
        }

    } while ($Found -eq $False)

    [System.Collections.Generic.List[PSCustomObject]]$ParsedAlerts = @()

    Write-Output "$(Get-Date): Processing Organizations"
    foreach ($Org in $Organizations) {
        Write-Host "$(Get-Date): Processing $($Org.name)"
        $OrgDevices = $Devices | where-object { $_.organizationId -eq $Org.id }
        $OrgAlerts = $Alerts | Where-Object { $_.deviceId -in $OrgDevices.id }
        Foreach ($Alert in $OrgAlerts) {
            $CurrentActivity = $Activities | Where-Object { $_.seriesUid -eq $Alert.uid }
            if (($CurrentActivity | Measure-Object).count -ne 1) {
                $AssociatedTriggers = $Null
                $CurrentActivity = (Invoke-NinjaOneRequest -Method GET -Path 'activities' -QueryParams "status=TRIGGERED&seriesUid=$($Alert.uid)").Activities
            }

            $AssociatedTriggers = $Activities | Where-Object { $_.sourceConfigUid -eq $Alert.sourceConfigUid -and $_.deviceId -eq $Alert.deviceId }
            $AlertDevice = $Devices | Where-Object { $_.id -eq $Alert.deviceId }
            $AlertLocation = $Locations | Where-Object { $_.id -eq $AlertDevice.locationId }

            Switch ($CurrentActivity.severity) {
                'CRITICAL' { $SeverityIcon = 'fas fa-circle-xmark'; $SeverityColour = '#D53948'; $SeverityScore = 5; $RowClass = 'danger' }
                'MAJOR' { $SeverityIcon = 'fas fa-triangle-exclamation'; $SeverityColour = '#FAC905'; $SeverityScore = 4; $RowClass = 'warning' }
                'MODERATE' { $SeverityIcon = 'fas fa-circle-exclamation'; $SeverityColour = '#337AB7 '; $SeverityScore = 3; $RowClass = 'other' }
                'MINOR' { $SeverityIcon = 'fas fa-circle-exclamation'; $SeverityColour = '#949597'; $SeverityScore = 2; $RowClass = 'unknown' }
                'NONE' { $SeverityIcon = 'fas fa-circle-info'; $SeverityColour = '#949597'; $SeverityScore = 1; $RowClass = '' }
                default { $SeverityIcon = 'fas fa-circle-info'; $SeverityColour = '#949597'; $SeverityScore = 1; $RowClass = '' }
            }

            Switch ($CurrentActivity.priority) {
                'HIGH' { $PiorityIcon = 'fas fa-circle-arrow-up'; $PiorityColour = '#D53948'; $PiorityScore = 5 }
                'MEDIUM' { $PiorityIcon = 'fas fa-circle-arrow-right'; $PiorityColour = '#FAC905'; $PiorityScore = 4 }
                'LOW' { $PiorityIcon = 'fas fa-circle-arrow-down'; $PiorityColour = '#337AB7'; $PiorityScore = 3 }
                'NONE' { $PiorityIcon = 'fas fa-circle-info'; $PiorityColour = '#949597'; $PiorityScore = 2 }
                default { $PiorityIcon = 'fas fa-circle-info'; $PiorityColour = '#949597'; $PiorityScore = 2 }
            }


            
            $TotalCount = ($AssociatedTriggers | Measure-Object).count
            $Last30DaysAlerts = $AssociatedTriggers | Where-Object { $_.activityTime -gt (Get-NinjaOneTime -Date (Get-Date).AddDays(-30) -Seconds) } | Sort-Object activityTime
        
        
            # Get the current date
            $today = Get-Date

            # Initialize variables to track consecutive days and status
            $consecutiveDays = 0
            $previousStatus = $null
            $HTMLHistory = ''

            # Loop through the last 30 days
            for ($i = 0; $i -le 30; $i++) {
                # Calculate the date to check
                $dateToCheck = $today.AddDays(-$i)

                # Check if any alerts were created on this date
                $alertsOnThisDay = $Last30DaysAlerts | Where-Object { (Get-TimeFromNinjaOne -Date ($_.activityTime) -Seconds).Date -eq $dateToCheck.Date }
                $currentStatus = if ($alertsOnThisDay.Count -gt 0) { "#D53948" } else { "#cccccc" }

                # Check if the status changed or it's the last iteration
                if ($currentStatus -ne $previousStatus -or $i -eq 30) {
                    if ($consecutiveDays -gt 0) {
                        # Calculate width of the span
                        $width = $consecutiveDays * 3  # Example width calculation
                        $color = if ($previousStatus -eq "#D53948") { "#D53948" } else { "#cccccc" }
                        $HTMLHistory = "<div style='background-color: $color; width: ${width}px;'></div>" + $HTMLHistory
                    }

                    # Reset for the new status
                    $consecutiveDays = 0
                }

                # Increment the day count and update the previous status
                $consecutiveDays++
                $previousStatus = $currentStatus
            }

            # End of HTML output
            $HTMLHistory = '<div style="display: flex; height: 20px;">' + $HTMLHistory + '</div>'

            $ParsedAlerts.add([PSCustomObject]@{
                    Created        = Get-TimeFromNinjaOne -Date $Alert.createTime -seconds
                    Updated        = Get-TimeFromNinjaOne -Date $Alert.updateTime -seconds
                    Device         = $AlertDevice.systemName
                    DeviceID       = $AlertDevice.id
                    OrgName        = $Org.name
                    OrgID          = $Org.id
                    LocName        = $AlertLocation.name
                    LocID          = $AlertLocation.id
                    Message        = $Alert.message
                    Severity       = if ($CurrentActivity.severity) { $CurrentActivity.severity } else { 'None' }
                    Piority        = if ($CurrentActivity.priority) { $CurrentActivity.priority } else { 'None' }
                    SeverityIcon   = $SeverityIcon 
                    SeverityColour = $SeverityColour
                    SeverityScore  = $SeverityScore
                    PiorityIcon    = $PiorityIcon
                    PiorityColour  = $PiorityColour
                    PiorityScore   = $PiorityScore
                    RowClass       = $RowClass
                    TotalCount     = $TotalCount
                    Last30Days     = $HTMLHistory
                })


        }

        $ParsedTable = Get-AlertsTable -Alerts ($ParsedAlerts | Where-object { $_.OrgID -eq $Org.id } | Sort-Object SeverityScore, PiorityScore, Created -Descending)  -MaxChars 300
        
        $OrgUpdate = [PSCustomObject]@{
            "$SummaryField" = @{'html' = "$($ParsedTable -join '')" }
        }

        $Null = Invoke-NinjaOneRequest -Method PATCH -Path "organization/$($Org.id)/custom-fields" -InputObject $OrgUpdate

    }

    Write-Output "$(Get-Date): Generating Global View"
    # Set Global View
    $OverviewMatch = $Organizations | Where-Object { $_.name -eq $OverviewCompany }
    $ParsedTable = Get-AlertsTable -Alerts ($ParsedAlerts  | Where-Object { $_.SeverityScore -ge 4 } | Sort-Object SeverityScore, PiorityScore, Created -Descending) -MaxChars 100
    $OrgUpdate = [PSCustomObject]@{
        "$SummaryField" = @{'html' = "$($ParsedTable -join '')" }
    }

    $Null = Invoke-NinjaOneRequest -Method PATCH -Path "organization/$($OverviewMatch.id)/custom-fields" -InputObject $OrgUpdate

    Write-Output "$(Get-Date): Processing Devices"
    # Set Each Device
    Foreach ($UpdateDevice in $Devices) {
        $ParsedTable = Get-AlertsTable -MaxChars 300 -Alerts ($ParsedAlerts | Where-object { $_.DeviceID -eq $UpdateDevice.id } | Sort-Object SeverityScore, PiorityScore, Created -Descending) 
        $DeviceUpdate = [PSCustomObject]@{
            "$SummaryField" = @{'html' = "$($ParsedTable -join '')" }
        }

        $Null = Invoke-NinjaOneRequest -Method PATCH -Path "device/$($UpdateDevice.id)/custom-fields" -InputObject $DeviceUpdate
    }

    Write-Output "$(Get-Date): Complete Total Runtime: $((New-TimeSpan -Start $Start -End (Get-Date)).TotalSeconds) seconds"

} catch {
    Write-Output "Failed to Generate Documentation: $_"
    exit 1
}

