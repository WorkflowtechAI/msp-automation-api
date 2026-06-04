# Mail Zapper (Compliance Search & Delete)
# Requires Exchange Online Management module (for compliance operations)
# Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global variables
$global:CurrentSearchName = $null

function Search-And-DeleteMail {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AdminEmail,
        [string]$Subject,
        [string]$SenderEmail,
        [string]$RecipientEmail,
        [string]$AttachmentName,
        [string]$MessageKind,
        [string]$HasAttachment,
        [string]$SizeOperator,
        [long]$SizeValue,
        [string]$TargetUser,
        [switch]$AllUsers,
        [switch]$HardDelete,
        [switch]$DryRun,
        [datetime]$StartDate,
        [datetime]$EndDate,
        [string]$LogFile = ".\MailDeleteLog.txt"
    )

    function Log {
        param ($msg)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$ts - $msg" | Out-File $LogFile -Append
        if ($global:OutputTextBox) {
            $global:OutputTextBox.AppendText("$ts - $msg`r`n")
            $global:OutputTextBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    try {
        Log "Connecting to Security & Compliance Center with Global Admin credentials..."
        Log "Admin Email: $AdminEmail"

        # Connect to Security & Compliance Center using REST API (modern approach)
        try {
            Log "Using modern REST-based API connection (Microsoft's recommended approach since July 2023)..."

            # Force REST API usage by using the modern connection method
            Connect-IPPSSession -UserPrincipalName $AdminEmail -UseRPSSession:$false -ErrorAction Stop
            Log "Connected successfully to Security & Compliance Center via REST API."

            # Test connection by getting compliance search info
            Get-ComplianceSearch -ResultSize 1 -ErrorAction SilentlyContinue | Out-Null
            Log "Connection verified - REST-based compliance search cmdlets are available."

        } catch {
            Log "REST API connection failed: $($_.Exception.Message)"
            Log "Attempting fallback connection method..."

            try {
                # Fallback to standard connection (should still use REST with modern module)
                Connect-IPPSSession -UserPrincipalName $AdminEmail -ErrorAction Stop
                Log "Connected successfully using fallback method."

                # Test connection
                Get-ComplianceSearch -ResultSize 1 -ErrorAction SilentlyContinue | Out-Null
                Log "Connection verified - compliance search cmdlets are available."

            } catch {
                Log "All connection attempts failed: $($_.Exception.Message)"
                throw "Failed to connect to Security & Compliance Center. Please ensure you have Global Admin or Compliance Admin permissions and the latest ExchangeOnlineManagement module is installed."
            }
        }

        # Create compliance security filter (only needs to be done once, but safe to repeat)
        Log "Creating/updating compliance security filter..."
        try {
            # Check if filter already exists
            $existingFilter = Get-ComplianceSecurityFilter -FilterName "EXO_Only" -ErrorAction SilentlyContinue
            if (-not $existingFilter) {
                New-ComplianceSecurityFilter -FilterName "EXO_Only" -Users $AdminEmail -Filters "SiteContent_Path -notlike '*sharepoint.com*'" -Action All -ErrorAction Stop
                Log "Compliance security filter created successfully."
            } else {
                Log "Compliance security filter already exists (this is normal)."
            }
        } catch {
            Log "Note: Compliance security filter creation skipped: $($_.Exception.Message)"
        }

        # Determine search scope for compliance search
        $searchLocations = @()
        if ($AllUsers) {
            Log "Targeting all mailboxes in the organization..."
            $searchLocations = @("All")
        } elseif (![string]::IsNullOrWhiteSpace($TargetUser)) {
            Log "Targeting specific user: $TargetUser"
            $searchLocations = @($TargetUser)
        } else {
            throw "Must specify either a target user or select 'All Users'"
        }

        # Build advanced search query for compliance search
        $queryParts = @()

        # Basic search criteria
        if (![string]::IsNullOrWhiteSpace($Subject)) {
            $queryParts += "subject:`"$Subject`""
        }
        if (![string]::IsNullOrWhiteSpace($SenderEmail)) {
            $queryParts += "from:`"$SenderEmail`""
        }
        if (![string]::IsNullOrWhiteSpace($RecipientEmail)) {
            $queryParts += "recipients:`"$RecipientEmail`""
        }

        # Message type filter
        if (![string]::IsNullOrWhiteSpace($MessageKind) -and $MessageKind -ne "Any") {
            switch ($MessageKind) {
                "Email" { $queryParts += "kind:email" }
                "Teams Chat" { $queryParts += "kind:microsoftteams" }
                "Meetings" { $queryParts += "kind:meetings" }
                "Voice Mail" { $queryParts += "kind:voicemail" }
                "Instant Messages" { $queryParts += "kind:im" }
            }
        }

        # Attachment filters
        if (![string]::IsNullOrWhiteSpace($HasAttachment) -and $HasAttachment -ne "Any") {
            switch ($HasAttachment) {
                "Has Attachments" { $queryParts += "hasattachment:true" }
                "No Attachments" { $queryParts += "hasattachment:false" }
            }
        }
        if (![string]::IsNullOrWhiteSpace($AttachmentName)) {
            $queryParts += "attachmentnames:`"$AttachmentName`""
        }

        # Size filter
        if (![string]::IsNullOrWhiteSpace($SizeOperator) -and $SizeOperator -ne "Any" -and $SizeValue -gt 0) {
            switch ($SizeOperator) {
                "Greater than" { $queryParts += "size>$SizeValue" }
                "Less than" { $queryParts += "size<$SizeValue" }
                "Equal to" { $queryParts += "size=$SizeValue" }
            }
        }

        # Add date range if specified
        if ($StartDate -and $EndDate) {
            $startDateStr = $StartDate.ToString("yyyy-MM-dd")
            $endDateStr = $EndDate.ToString("yyyy-MM-dd")
            $queryParts += "received:$startDateStr..$endDateStr"
            Log "Date range filter: $startDateStr to $endDateStr"
        }

        if ($queryParts.Count -eq 0) {
            throw "Must specify at least one search criteria"
        }

        $contentQuery = $queryParts -join " AND "
        Log "Search query: $contentQuery"

        # Generate unique search name
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $searchName = "MailPurge_$timestamp"
        # Store search name globally for cancel functionality
        $global:CurrentSearchName = $searchName
        Log "Current search name set to: $global:CurrentSearchName"

        # Create compliance search
        Log "Creating compliance search: $searchName"
        if ($AllUsers) {
            New-ComplianceSearch -Name $searchName -ExchangeLocation all -ContentMatchQuery $contentQuery -ErrorAction Stop
        } else {
            New-ComplianceSearch -Name $searchName -ExchangeLocation $searchLocations -ContentMatchQuery $contentQuery -ErrorAction Stop
        }
        Log "Compliance search created."

        # Start the search
        Log "Starting compliance search..."
        Start-ComplianceSearch -Identity $searchName -ErrorAction Stop
        Log "Search started. Waiting for completion..."

        # Now that search is actually running, show the cancel button
        $btnCancel.Visible = $true
        $btnCancel.Enabled = $true

        # Wait for search to complete with improved status checking and stuck detection
        $maxWaitMinutes = 30
        $waitCount = 0
        $maxWaitCount = ($maxWaitMinutes * 60) / 10  # 10 second intervals
        $stuckThreshold = 12  # 2 minutes in 10-second intervals
        $stuckCount = 0
        $lastStatus = ""

        do {
            # Use shorter sleep intervals for more responsive cancellation
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Seconds 1
                [System.Windows.Forms.Application]::DoEvents()  # Allow UI to process events

                # Check if search was cancelled (check every second)
                if ($global:CurrentSearchName -eq $null) {
                    Log "Search was cancelled by user."
                    return
                }
            }

            $waitCount++

            try {
                $searchStatus = Get-ComplianceSearch -Identity $searchName -ErrorAction Stop
                # Only show item counts when search is completed or if items are found
                if ($searchStatus.Status -eq "Completed" -or $searchStatus.Items -gt 0) {
                    Log "Search status: $($searchStatus.Status) - Items found: $($searchStatus.Items) - Size: $($searchStatus.Size)"
                } else {
                    Log "Search status: $($searchStatus.Status) - Searching..."
                }
                [System.Windows.Forms.Application]::DoEvents()

                # Detect if search is stuck in same status
                if ($searchStatus.Status -eq $lastStatus -and $searchStatus.Status -eq "Starting") {
                    $stuckCount++
                    if ($stuckCount -ge $stuckThreshold) {
                        Log "WARNING: Search appears stuck in 'Starting' status for over 2 minutes."
                        Log "This is a known issue with compliance searches. Attempting recovery..."

                        # Try to restart the search
                        try {
                            Stop-ComplianceSearch -Identity $searchName -Confirm:$false -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 5
                            Start-ComplianceSearch -Identity $searchName -ErrorAction Stop
                            Log "Search restarted. Continuing to monitor..."
                            $stuckCount = 0  # Reset stuck counter
                        } catch {
                            Log "Failed to restart search: $($_.Exception.Message)"
                            Log "You may need to manually delete the search '$searchName' in the Security & Compliance Center and try again."
                            throw "Search appears to be permanently stuck. Manual intervention required."
                        }
                    }
                } else {
                    $stuckCount = 0  # Reset if status changed
                }
                $lastStatus = $searchStatus.Status

                # Check for timeout
                if ($waitCount -ge $maxWaitCount) {
                    throw "Search timed out after $maxWaitMinutes minutes. Current status: $($searchStatus.Status)"
                }

                # Check for failed status
                if ($searchStatus.Status -eq "Failed" -or $searchStatus.Status -eq "PartiallyFailed") {
                    throw "Search failed with status: $($searchStatus.Status). Error: $($searchStatus.Errors)"
                }

            } catch {
                Log "Error checking search status: $($_.Exception.Message)"
                throw "Failed to check search status: $($_.Exception.Message)"
            }

        } while ($searchStatus.Status -in @("Starting", "InProgress", "Stopping"))

        if ($searchStatus.Status -ne "Completed") {
            throw "Search failed with status: $($searchStatus.Status). Errors: $($searchStatus.Errors)"
        }

        Log "Search completed. Found $($searchStatus.Items) items in $($searchStatus.Size)"

        if ($searchStatus.Items -eq 0) {
            Log "No items found matching the search criteria."
            if ($DryRun) {
                Log "DRY RUN COMPLETE: No messages found to delete."
            }
            return
        }

        if ($DryRun) {
            Log "DRY RUN: Would purge $($searchStatus.Items) items. No action taken."
            Log "To see detailed results, check the compliance search '$searchName' in the Security & Compliance Center."
            return
        }

        # Perform the purge
        $purgeType = if ($HardDelete) { "HardDelete" } else { "SoftDelete" }
        Log "Starting $purgeType purge of $($searchStatus.Items) items..."

        $purgeAction = New-ComplianceSearchAction -SearchName $searchName -Purge -PurgeType $purgeType -Confirm:$false -ErrorAction Stop
        Log "Purge action created: $($purgeAction.Name)"

        # Monitor purge progress
        do {
            Start-Sleep -Seconds 15
            $purgeStatus = Get-ComplianceSearchAction -Identity $purgeAction.Name
            Log "Purge status: $($purgeStatus.Status)"
            [System.Windows.Forms.Application]::DoEvents()
        } while ($purgeStatus.Status -eq "InProgress")

        if ($purgeStatus.Status -eq "Completed") {
            Log "Purge completed successfully!"
        } else {
            Log "Purge finished with status: $($purgeStatus.Status)"
        }

        Log "Operation complete. Search name: $searchName"
        $global:CurrentSearchName = $null

        # Operation completed in the compliance search logic above

    } catch {
        Log "ERROR: $_"
        $global:CurrentSearchName = $null
        throw $_
    }
}

# Create the main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Mail Zapper - Advanced Compliance Search & Delete"
$form.Size = New-Object System.Drawing.Size(950, 1050)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

# Admin Email Configuration
$lblAdmin = New-Object System.Windows.Forms.Label
$lblAdmin.Location = New-Object System.Drawing.Point(10, 20)
$lblAdmin.Size = New-Object System.Drawing.Size(100, 20)
$lblAdmin.Text = "Admin Email:"
$lblAdmin.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblAdmin)

$txtAdminEmail = New-Object System.Windows.Forms.TextBox
$txtAdminEmail.Location = New-Object System.Drawing.Point(120, 18)
$txtAdminEmail.Size = New-Object System.Drawing.Size(550, 20)
$txtAdminEmail.Text = "admin@yourdomain.com"
$form.Controls.Add($txtAdminEmail)

# Admin info note
$lblAdminNote = New-Object System.Windows.Forms.Label
$lblAdminNote.Location = New-Object System.Drawing.Point(120, 45)
$lblAdminNote.Size = New-Object System.Drawing.Size(550, 15)
$lblAdminNote.Text = "Enter your Global Admin or Exchange Admin email address"
$lblAdminNote.ForeColor = [System.Drawing.Color]::DarkBlue
$lblAdminNote.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($lblAdminNote)

# Target Selection
$lblTarget = New-Object System.Windows.Forms.Label
$lblTarget.Location = New-Object System.Drawing.Point(10, 75)
$lblTarget.Size = New-Object System.Drawing.Size(100, 20)
$lblTarget.Text = "Target:"
$lblTarget.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTarget)

$radioSpecificUser = New-Object System.Windows.Forms.RadioButton
$radioSpecificUser.Location = New-Object System.Drawing.Point(120, 75)
$radioSpecificUser.Size = New-Object System.Drawing.Size(120, 20)
$radioSpecificUser.Text = "Specific User"
$radioSpecificUser.Checked = $true
$form.Controls.Add($radioSpecificUser)

$radioAllUsers = New-Object System.Windows.Forms.RadioButton
$radioAllUsers.Location = New-Object System.Drawing.Point(250, 75)
$radioAllUsers.Size = New-Object System.Drawing.Size(150, 20)
$radioAllUsers.Text = "All Users (Org-wide)"
$radioAllUsers.ForeColor = [System.Drawing.Color]::Red
$form.Controls.Add($radioAllUsers)

# User Email (only for specific user)
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Location = New-Object System.Drawing.Point(10, 105)
$lblUser.Size = New-Object System.Drawing.Size(100, 20)
$lblUser.Text = "User Email:"
$form.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(120, 103)
$txtUser.Size = New-Object System.Drawing.Size(550, 20)
$txtUser.Text = "user@yourdomain.com"
$form.Controls.Add($txtUser)

# Search Criteria Section
$lblCriteria = New-Object System.Windows.Forms.Label
$lblCriteria.Location = New-Object System.Drawing.Point(10, 140)
$lblCriteria.Size = New-Object System.Drawing.Size(120, 20)
$lblCriteria.Text = "Search Criteria:"
$lblCriteria.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblCriteria)

# Subject
$lblSubject = New-Object System.Windows.Forms.Label
$lblSubject.Location = New-Object System.Drawing.Point(10, 170)
$lblSubject.Size = New-Object System.Drawing.Size(100, 20)
$lblSubject.Text = "Subject Contains:"
$form.Controls.Add($lblSubject)

$txtSubject = New-Object System.Windows.Forms.TextBox
$txtSubject.Location = New-Object System.Drawing.Point(120, 168)
$txtSubject.Size = New-Object System.Drawing.Size(600, 20)
$form.Controls.Add($txtSubject)

# Sender
$lblSender = New-Object System.Windows.Forms.Label
$lblSender.Location = New-Object System.Drawing.Point(10, 200)
$lblSender.Size = New-Object System.Drawing.Size(100, 20)
$lblSender.Text = "Sender Email:"
$form.Controls.Add($lblSender)

$txtSender = New-Object System.Windows.Forms.TextBox
$txtSender.Location = New-Object System.Drawing.Point(120, 198)
$txtSender.Size = New-Object System.Drawing.Size(600, 20)
$form.Controls.Add($txtSender)

# Date Range Section
$lblDateRange = New-Object System.Windows.Forms.Label
$lblDateRange.Location = New-Object System.Drawing.Point(10, 230)
$lblDateRange.Size = New-Object System.Drawing.Size(100, 20)
$lblDateRange.Text = "Date Range:"
$form.Controls.Add($lblDateRange)

$lblStartDate = New-Object System.Windows.Forms.Label
$lblStartDate.Location = New-Object System.Drawing.Point(120, 230)
$lblStartDate.Size = New-Object System.Drawing.Size(60, 20)
$lblStartDate.Text = "From:"
$form.Controls.Add($lblStartDate)

$dtpStartDate = New-Object System.Windows.Forms.DateTimePicker
$dtpStartDate.Location = New-Object System.Drawing.Point(180, 228)
$dtpStartDate.Size = New-Object System.Drawing.Size(120, 20)
$dtpStartDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpStartDate.Value = (Get-Date).AddDays(-30)  # Default to 30 days ago
$form.Controls.Add($dtpStartDate)

$lblEndDate = New-Object System.Windows.Forms.Label
$lblEndDate.Location = New-Object System.Drawing.Point(320, 230)
$lblEndDate.Size = New-Object System.Drawing.Size(30, 20)
$lblEndDate.Text = "To:"
$form.Controls.Add($lblEndDate)

$dtpEndDate = New-Object System.Windows.Forms.DateTimePicker
$dtpEndDate.Location = New-Object System.Drawing.Point(350, 228)
$dtpEndDate.Size = New-Object System.Drawing.Size(120, 20)
$dtpEndDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
$dtpEndDate.Value = Get-Date  # Default to today
$form.Controls.Add($dtpEndDate)

$chkUseDateRange = New-Object System.Windows.Forms.CheckBox
$chkUseDateRange.Location = New-Object System.Drawing.Point(490, 230)
$chkUseDateRange.Size = New-Object System.Drawing.Size(200, 20)
$chkUseDateRange.Text = "Enable Date Range Filter"
$chkUseDateRange.Checked = $false
$form.Controls.Add($chkUseDateRange)

# Advanced Search Options Section
$lblAdvanced = New-Object System.Windows.Forms.Label
$lblAdvanced.Location = New-Object System.Drawing.Point(10, 270)
$lblAdvanced.Size = New-Object System.Drawing.Size(150, 20)
$lblAdvanced.Text = "Advanced Options:"
$lblAdvanced.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblAdvanced)

# Recipient field
$lblRecipient = New-Object System.Windows.Forms.Label
$lblRecipient.Location = New-Object System.Drawing.Point(10, 300)
$lblRecipient.Size = New-Object System.Drawing.Size(100, 20)
$lblRecipient.Text = "Recipient Email:"
$form.Controls.Add($lblRecipient)

$txtRecipient = New-Object System.Windows.Forms.TextBox
$txtRecipient.Location = New-Object System.Drawing.Point(120, 298)
$txtRecipient.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($txtRecipient)

# Message Kind dropdown
$lblKind = New-Object System.Windows.Forms.Label
$lblKind.Location = New-Object System.Drawing.Point(440, 300)
$lblKind.Size = New-Object System.Drawing.Size(80, 20)
$lblKind.Text = "Message Type:"
$form.Controls.Add($lblKind)

$cmbKind = New-Object System.Windows.Forms.ComboBox
$cmbKind.Location = New-Object System.Drawing.Point(530, 298)
$cmbKind.Size = New-Object System.Drawing.Size(150, 20)
$cmbKind.DropDownStyle = "DropDownList"
$cmbKind.Items.AddRange(@("Any", "Email", "Teams Chat", "Meetings", "Voice Mail", "Instant Messages"))
$cmbKind.SelectedIndex = 0
$form.Controls.Add($cmbKind)

# Attachment options
$lblAttachment = New-Object System.Windows.Forms.Label
$lblAttachment.Location = New-Object System.Drawing.Point(10, 330)
$lblAttachment.Size = New-Object System.Drawing.Size(100, 20)
$lblAttachment.Text = "Attachments:"
$form.Controls.Add($lblAttachment)

$cmbAttachment = New-Object System.Windows.Forms.ComboBox
$cmbAttachment.Location = New-Object System.Drawing.Point(120, 328)
$cmbAttachment.Size = New-Object System.Drawing.Size(150, 20)
$cmbAttachment.DropDownStyle = "DropDownList"
$cmbAttachment.Items.AddRange(@("Any", "Has Attachments", "No Attachments"))
$cmbAttachment.SelectedIndex = 0
$form.Controls.Add($cmbAttachment)

# Attachment name filter
$lblAttachmentName = New-Object System.Windows.Forms.Label
$lblAttachmentName.Location = New-Object System.Drawing.Point(290, 330)
$lblAttachmentName.Size = New-Object System.Drawing.Size(100, 20)
$lblAttachmentName.Text = "Attachment Name:"
$form.Controls.Add($lblAttachmentName)

$txtAttachmentName = New-Object System.Windows.Forms.TextBox
$txtAttachmentName.Location = New-Object System.Drawing.Point(400, 328)
$txtAttachmentName.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($txtAttachmentName)

# Size filter
$lblSize = New-Object System.Windows.Forms.Label
$lblSize.Location = New-Object System.Drawing.Point(10, 360)
$lblSize.Size = New-Object System.Drawing.Size(100, 20)
$lblSize.Text = "Message Size:"
$form.Controls.Add($lblSize)

$cmbSizeOperator = New-Object System.Windows.Forms.ComboBox
$cmbSizeOperator.Location = New-Object System.Drawing.Point(120, 358)
$cmbSizeOperator.Size = New-Object System.Drawing.Size(80, 20)
$cmbSizeOperator.DropDownStyle = "DropDownList"
$cmbSizeOperator.Items.AddRange(@("Any", "Greater than", "Less than", "Equal to"))
$cmbSizeOperator.SelectedIndex = 0
$form.Controls.Add($cmbSizeOperator)

$txtSizeValue = New-Object System.Windows.Forms.TextBox
$txtSizeValue.Location = New-Object System.Drawing.Point(210, 358)
$txtSizeValue.Size = New-Object System.Drawing.Size(80, 20)
$txtSizeValue.Text = "1"
$form.Controls.Add($txtSizeValue)

$cmbSizeUnit = New-Object System.Windows.Forms.ComboBox
$cmbSizeUnit.Location = New-Object System.Drawing.Point(300, 358)
$cmbSizeUnit.Size = New-Object System.Drawing.Size(60, 20)
$cmbSizeUnit.DropDownStyle = "DropDownList"
$cmbSizeUnit.Items.AddRange(@("MB", "KB", "GB"))
$cmbSizeUnit.SelectedIndex = 0
$form.Controls.Add($cmbSizeUnit)

# Note about search criteria
$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Location = New-Object System.Drawing.Point(120, 390)
$lblNote.Size = New-Object System.Drawing.Size(700, 15)
$lblNote.Text = "Note: At least one search criteria must be specified (Subject, Sender, Recipient, etc.)"
$lblNote.ForeColor = [System.Drawing.Color]::DarkBlue
$lblNote.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($lblNote)

# Options Section
$lblOptions = New-Object System.Windows.Forms.Label
$lblOptions.Location = New-Object System.Drawing.Point(10, 480)
$lblOptions.Size = New-Object System.Drawing.Size(100, 20)
$lblOptions.Text = "Options:"
$lblOptions.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblOptions)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Location = New-Object System.Drawing.Point(120, 510)
$chkDryRun.Size = New-Object System.Drawing.Size(300, 20)
$chkDryRun.Text = "Dry Run (Search Only - No Deletion)"
$chkDryRun.Checked = $true
$chkDryRun.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($chkDryRun)

$chkHardDelete = New-Object System.Windows.Forms.CheckBox
$chkHardDelete.Location = New-Object System.Drawing.Point(120, 540)
$chkHardDelete.Size = New-Object System.Drawing.Size(400, 20)
$chkHardDelete.Text = "Hard Delete (Permanent - Cannot be recovered from Deleted Items)"
$chkHardDelete.ForeColor = [System.Drawing.Color]::Red
$form.Controls.Add($chkHardDelete)

# Modern approach info
$lblModern = New-Object System.Windows.Forms.Label
$lblModern.Location = New-Object System.Drawing.Point(120, 570)
$lblModern.Size = New-Object System.Drawing.Size(550, 30)
$lblModern.ForeColor = [System.Drawing.Color]::DarkGreen
$lblModern.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Italic)
$form.Controls.Add($lblModern)

# Query Preview Section
$lblQueryPreview = New-Object System.Windows.Forms.Label
$lblQueryPreview.Location = New-Object System.Drawing.Point(10, 420)
$lblQueryPreview.Size = New-Object System.Drawing.Size(100, 20)
$lblQueryPreview.Text = "Query Preview:"
$lblQueryPreview.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblQueryPreview)

$txtQueryPreview = New-Object System.Windows.Forms.TextBox
$txtQueryPreview.Location = New-Object System.Drawing.Point(10, 445)
$txtQueryPreview.Size = New-Object System.Drawing.Size(720, 20)
$txtQueryPreview.ReadOnly = $true
$txtQueryPreview.BackColor = [System.Drawing.Color]::LightYellow
$txtQueryPreview.Font = New-Object System.Drawing.Font("Consolas", 8)
$form.Controls.Add($txtQueryPreview)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Location = New-Object System.Drawing.Point(740, 443)
$btnPreview.Size = New-Object System.Drawing.Size(100, 24)
$btnPreview.Text = "Build Query"
$btnPreview.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8)
$form.Controls.Add($btnPreview)

# Buttons
$btnExecute = New-Object System.Windows.Forms.Button
$btnExecute.Location = New-Object System.Drawing.Point(120, 610)
$btnExecute.Size = New-Object System.Drawing.Size(140, 40)
$btnExecute.Text = ">> Execute"
$btnExecute.BackColor = [System.Drawing.Color]::LightGreen
$btnExecute.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnExecute)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Location = New-Object System.Drawing.Point(280, 610)
$btnClear.Size = New-Object System.Drawing.Size(120, 40)
$btnClear.Text = "Clear Log"
$btnClear.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$form.Controls.Add($btnClear)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Location = New-Object System.Drawing.Point(420, 610)
$btnCancel.Size = New-Object System.Drawing.Size(120, 40)
$btnCancel.Text = "Cancel Search"
$btnCancel.BackColor = [System.Drawing.Color]::Orange
$btnCancel.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$btnCancel.Visible = $false
$form.Controls.Add($btnCancel)

$btnHelp = New-Object System.Windows.Forms.Button
$btnHelp.Location = New-Object System.Drawing.Point(560, 610)
$btnHelp.Size = New-Object System.Drawing.Size(120, 40)
$btnHelp.Text = "Help & Examples"
$btnHelp.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$btnHelp.BackColor = [System.Drawing.Color]::LightBlue
$form.Controls.Add($btnHelp)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Location = New-Object System.Drawing.Point(700, 610)
$btnExit.Size = New-Object System.Drawing.Size(120, 40)
$btnExit.Text = "Exit"
$btnExit.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$form.Controls.Add($btnExit)

# Output text box
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Location = New-Object System.Drawing.Point(10, 665)
$lblOutput.Size = New-Object System.Drawing.Size(100, 20)
$lblOutput.Text = "Output Log:"
$lblOutput.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblOutput)

$global:OutputTextBox = New-Object System.Windows.Forms.TextBox
$global:OutputTextBox.Location = New-Object System.Drawing.Point(10, 685)
$global:OutputTextBox.Size = New-Object System.Drawing.Size(910, 320)
$global:OutputTextBox.Multiline = $true
$global:OutputTextBox.ScrollBars = "Vertical"
$global:OutputTextBox.ReadOnly = $true
$global:OutputTextBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$global:OutputTextBox.BackColor = [System.Drawing.Color]::Black
$global:OutputTextBox.ForeColor = [System.Drawing.Color]::LimeGreen
$form.Controls.Add($global:OutputTextBox)

# Event handlers for radio buttons

# Query Preview Button
$btnPreview.Add_Click({
    try {
        # Build query parts just like in the main function
        $queryParts = @()

        # Basic search criteria
        if (![string]::IsNullOrWhiteSpace($txtSubject.Text)) {
            $queryParts += "subject:`"$($txtSubject.Text.Trim())`""
        }
        if (![string]::IsNullOrWhiteSpace($txtSender.Text)) {
            $queryParts += "from:`"$($txtSender.Text.Trim())`""
        }
        if (![string]::IsNullOrWhiteSpace($txtRecipient.Text)) {
            $queryParts += "recipients:`"$($txtRecipient.Text.Trim())`""
        }

        # Message type filter
        if ($cmbKind.SelectedIndex -gt 0) {
            $messageKind = $cmbKind.SelectedItem.ToString()
            switch ($messageKind) {
                "Email" { $queryParts += "kind:email" }
                "Teams Chat" { $queryParts += "kind:microsoftteams" }
                "Meetings" { $queryParts += "kind:meetings" }
                "Voice Mail" { $queryParts += "kind:voicemail" }
                "Instant Messages" { $queryParts += "kind:im" }
            }
        }

        # Attachment filters
        if ($cmbAttachment.SelectedIndex -gt 0) {
            $hasAttachment = $cmbAttachment.SelectedItem.ToString()
            switch ($hasAttachment) {
                "Has Attachments" { $queryParts += "hasattachment:true" }
                "No Attachments" { $queryParts += "hasattachment:false" }
            }
        }
        if (![string]::IsNullOrWhiteSpace($txtAttachmentName.Text)) {
            $queryParts += "attachmentnames:`"$($txtAttachmentName.Text.Trim())`""
        }

        # Size filter
        if ($cmbSizeOperator.SelectedIndex -gt 0) {
            $sizeInBytes = [int]$txtSizeValue.Text
            switch ($cmbSizeUnit.SelectedItem.ToString()) {
                "KB" { $sizeInBytes *= 1024 }
                "MB" { $sizeInBytes *= 1024 * 1024 }
                "GB" { $sizeInBytes *= 1024 * 1024 * 1024 }
            }
            $sizeOperator = $cmbSizeOperator.SelectedItem.ToString()
            switch ($sizeOperator) {
                "Greater than" { $queryParts += "size>$sizeInBytes" }
                "Less than" { $queryParts += "size<$sizeInBytes" }
                "Equal to" { $queryParts += "size=$sizeInBytes" }
            }
        }

        # Add date range if enabled
        if ($chkUseDateRange.Checked) {
            $startDateStr = $dtpStartDate.Value.Date.ToString("yyyy-MM-dd")
            $endDateStr = $dtpEndDate.Value.Date.ToString("yyyy-MM-dd")
            $queryParts += "received:$startDateStr..$endDateStr"
        }

        if ($queryParts.Count -eq 0) {
            $txtQueryPreview.Text = "(No search criteria specified)"
        } else {
            $txtQueryPreview.Text = $queryParts -join " AND "
        }
    } catch {
        $txtQueryPreview.Text = "Error building query: $($_.Exception.Message)"
    }
})

# Event handlers for radio buttons
$radioSpecificUser.Add_CheckedChanged({
    $txtUser.Enabled = $radioSpecificUser.Checked
    if ($radioSpecificUser.Checked) {
        $txtUser.BackColor = [System.Drawing.Color]::White
    } else {
        $txtUser.BackColor = [System.Drawing.Color]::LightGray
    }
})

$radioAllUsers.Add_CheckedChanged({
    $txtUser.Enabled = $radioSpecificUser.Checked
    if ($radioSpecificUser.Checked) {
        $txtUser.BackColor = [System.Drawing.Color]::White
    } else {
        $txtUser.BackColor = [System.Drawing.Color]::LightGray
    }
})

# Main execute button
$btnExecute.Add_Click({
    # Validation
    if ([string]::IsNullOrWhiteSpace($txtAdminEmail.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an admin email address.", "Validation Error", "OK", "Warning")
        return
    }

    if ($radioSpecificUser.Checked -and [string]::IsNullOrWhiteSpace($txtUser.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a user email address.", "Validation Error", "OK", "Warning")
        return
    }

    # Check if at least one search criteria is specified
    $hasSearchCriteria = $false
    if (![string]::IsNullOrWhiteSpace($txtSubject.Text)) { $hasSearchCriteria = $true }
    if (![string]::IsNullOrWhiteSpace($txtSender.Text)) { $hasSearchCriteria = $true }
    if (![string]::IsNullOrWhiteSpace($txtRecipient.Text)) { $hasSearchCriteria = $true }
    if (![string]::IsNullOrWhiteSpace($txtAttachmentName.Text)) { $hasSearchCriteria = $true }
    if ($cmbKind.SelectedIndex -gt 0) { $hasSearchCriteria = $true }
    if ($cmbAttachment.SelectedIndex -gt 0) { $hasSearchCriteria = $true }
    if ($cmbSizeOperator.SelectedIndex -gt 0) { $hasSearchCriteria = $true }
    if ($chkUseDateRange.Checked) { $hasSearchCriteria = $true }

    if (-not $hasSearchCriteria) {
        [System.Windows.Forms.MessageBox]::Show("Please specify at least one search criteria (Subject, Sender, Recipient, Message Type, Attachments, Size, or Date Range).", "Validation Error", "OK", "Warning")
        return
    }

    # Confirmation for non-dry runs
    if (-not $chkDryRun.Checked) {
        $scope = if ($radioAllUsers.Checked) { "ALL USERS in the organization" } else { "the specified user" }
        $deleteType = if ($chkHardDelete.Checked) { "PERMANENTLY DELETE (Hard Delete)" } else { "delete (Soft Delete)" }
        $result = [System.Windows.Forms.MessageBox]::Show(
            "This will $deleteType emails for $scope matching the specified criteria.`n`nAdmin: $($txtAdminEmail.Text)`n`nAre you absolutely sure you want to proceed?",
            "FINAL CONFIRMATION",
            "YesNo",
            "Warning"
        )
        if ($result -eq "No") { return }
    }

    $btnExecute.Enabled = $false
    $originalText = $btnExecute.Text
    $btnExecute.Text = ">> Running..."

    try {
        $params = @{
            AdminEmail = $txtAdminEmail.Text.Trim()
            DryRun = $chkDryRun.Checked
            HardDelete = $chkHardDelete.Checked
            AllUsers = $radioAllUsers.Checked
        }

        if ($radioSpecificUser.Checked) {
            $params.TargetUser = $txtUser.Text.Trim()
        }

        if (![string]::IsNullOrWhiteSpace($txtSubject.Text)) {
            $params.Subject = $txtSubject.Text.Trim()
        }

        if (![string]::IsNullOrWhiteSpace($txtSender.Text)) {
            $params.SenderEmail = $txtSender.Text.Trim()
        }

        if (![string]::IsNullOrWhiteSpace($txtRecipient.Text)) {
            $params.RecipientEmail = $txtRecipient.Text.Trim()
        }

        if (![string]::IsNullOrWhiteSpace($txtAttachmentName.Text)) {
            $params.AttachmentName = $txtAttachmentName.Text.Trim()
        }

        if ($cmbKind.SelectedIndex -gt 0) {
            $params.MessageKind = $cmbKind.SelectedItem.ToString()
        }

        if ($cmbAttachment.SelectedIndex -gt 0) {
            $params.HasAttachment = $cmbAttachment.SelectedItem.ToString()
        }

        if ($cmbSizeOperator.SelectedIndex -gt 0) {
            $sizeInBytes = [int]$txtSizeValue.Text
            switch ($cmbSizeUnit.SelectedItem.ToString()) {
                "KB" { $sizeInBytes *= 1024 }
                "MB" { $sizeInBytes *= 1024 * 1024 }
                "GB" { $sizeInBytes *= 1024 * 1024 * 1024 }
            }
            $params.SizeOperator = $cmbSizeOperator.SelectedItem.ToString()
            $params.SizeValue = $sizeInBytes
        }

        # Add date range if enabled
        if ($chkUseDateRange.Checked) {
            $params.StartDate = $dtpStartDate.Value.Date
            $params.EndDate = $dtpEndDate.Value.Date.AddDays(1).AddSeconds(-1)  # End of selected day
        }

        Search-And-DeleteMail @params

    } catch {
        $global:OutputTextBox.AppendText("ERROR: $($_.Exception.Message)`r`n")
        [System.Windows.Forms.MessageBox]::Show("An error occurred: $($_.Exception.Message)", "Error", "OK", "Error")
    } finally {
        $btnExecute.Enabled = $true
        $btnCancel.Visible = $false
        $btnCancel.Enabled = $false
        $btnExecute.Text = $originalText
    }
})

$btnCancel.Add_Click({
    if ($global:CurrentSearchName) {
        try {
            # Visual feedback - change button appearance
            $originalColor = $btnCancel.BackColor
            $btnCancel.BackColor = [System.Drawing.Color]::Red
            $btnCancel.Text = "Cancelling..."
            $btnCancel.Enabled = $false
            [System.Windows.Forms.Application]::DoEvents()

            $global:OutputTextBox.AppendText("Attempting to cancel search: $global:CurrentSearchName`r`n")

            # Check search status first - only try to cancel if it's actually running
            try {
                $searchStatus = Get-ComplianceSearch -Identity $global:CurrentSearchName -ErrorAction Stop
                if ($searchStatus.Status -eq "Starting") {
                    $global:OutputTextBox.AppendText("Search is still starting - waiting for it to begin before cancelling...`r`n")
                    # Wait a bit for search to actually start
                    Start-Sleep -Seconds 3
                    $searchStatus = Get-ComplianceSearch -Identity $global:CurrentSearchName -ErrorAction Stop
                }

                if ($searchStatus.Status -in @("InProgress", "Starting")) {
                    Stop-ComplianceSearch -Identity $global:CurrentSearchName -Confirm:$false -ErrorAction Stop
                    $global:OutputTextBox.AppendText("Search cancelled successfully.`r`n")
                } else {
                    $global:OutputTextBox.AppendText("Search was already completed or stopped (Status: $($searchStatus.Status)).`r`n")
                }
            } catch {
                # If we can't get status, try to cancel anyway
                Stop-ComplianceSearch -Identity $global:CurrentSearchName -Confirm:$false -ErrorAction Stop
                $global:OutputTextBox.AppendText("Search cancelled successfully.`r`n")
            }

            $global:CurrentSearchName = $null

            # Reset button appearance
            $btnCancel.BackColor = $originalColor
            $btnCancel.Text = "Cancel Search"
        } catch {
            $global:OutputTextBox.AppendText("Failed to cancel search: $($_.Exception.Message)`r`n")
            # Reset button appearance even on error
            $btnCancel.BackColor = $originalColor
            $btnCancel.Text = "Cancel Search"
            $btnCancel.Enabled = $true
        }
    }
})

$btnClear.Add_Click({
    $global:OutputTextBox.Clear()
})

$btnHelp.Add_Click({
    $helpText = @"
ADVANCED COMPLIANCE SEARCH OPTIONS HELP

BASIC SEARCH CRITERIA:
• Subject Contains: Search for emails containing specific text in the subject line
• Sender Email: Search for emails from specific sender(s) - supports wildcards (e.g., *@domain.com)
• Recipient Email: Search for emails sent to specific recipient(s)

ADVANCED OPTIONS:
• Message Type: Filter by specific message types
  - Email: Regular email messages
  - Teams Chat: Microsoft Teams chat messages
  - Meetings: Calendar meetings and invitations
  - Voice Mail: Voice mail messages
  - Instant Messages: Skype for Business conversations

• Attachments: Filter by attachment presence
  - Has Attachments: Only messages with attachments
  - No Attachments: Only messages without attachments
  - Attachment Name: Search for specific attachment file names (supports wildcards)

• Message Size: Filter by message size
  - Greater than/Less than/Equal to specific sizes
  - Units: KB, MB, or GB

• Date Range: Filter by received date range

QUERY EXAMPLES:
• Find large emails: Size > 10 MB
• Find Teams chats about "budget": Message Type = Teams Chat, Subject = budget
• Find emails with PDF attachments: Attachment Name = *.pdf
• Find external emails: Sender = *@external.com
• Find old emails: Date Range = older than 1 year

SAFETY FEATURES:
• Always use "Dry Run" first to preview results
• "Build Query" shows the exact search query that will be executed
• Cancel button allows stopping searches in progress
• Soft Delete moves to Deleted Items (recoverable)
• Hard Delete is permanent (use with extreme caution)

TIPS:
• Use wildcards (*) for partial matches
• Combine multiple criteria for precise targeting
• Check query preview before executing
• Start with narrow searches and expand as needed
"@
    [System.Windows.Forms.MessageBox]::Show($helpText, "Advanced Search Help", "OK", "Information")
})

$btnExit.Add_Click({
    $form.Close()
})

# Initialize the form state
$txtUser.Enabled = $true
$txtUser.BackColor = [System.Drawing.Color]::White

# Show startup information
$global:OutputTextBox.AppendText(">> Mail Zapper - USE WITH CAUTION!`r`n")
$global:OutputTextBox.AppendText("`r`nREQUIREMENTS:`r`n")
$global:OutputTextBox.AppendText("   - Exchange Online Management module (v3.0+ for REST API support)`r`n")
$global:OutputTextBox.AppendText("   - Install/Update: Install-Module ExchangeOnlineManagement -Force -Scope CurrentUser`r`n")
$global:OutputTextBox.AppendText("   - Global Admin or Compliance Admin permissions`r`n")
$global:OutputTextBox.AppendText("`r`nSAFETY:`r`n")
$global:OutputTextBox.AppendText("   - Always run Dry Run first to verify results!`r`n")
$global:OutputTextBox.AppendText("   - Soft delete moves to Deleted Items (recoverable)`r`n")
$global:OutputTextBox.AppendText("   - Hard delete is permanent (use with extreme caution)`r`n")
$global:OutputTextBox.AppendText("`r`n" + "=" * 80 + "`r`n")

# Show the form
[System.Windows.Forms.Application]::Run($form)
