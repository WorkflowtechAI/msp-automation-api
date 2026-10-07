# Pester tests for the six scripts added from field notes:
#   endpoint-inventory/Get-DirectoryJoinInfo.ps1
#   maintenance/Update-Sysmon.ps1
#   patch-management/Invoke-Windows11Upgrade.ps1
#   user-management/Restore-DeletedADUser.ps1
#   m365-azure/Set-UserPrimarySmtpAddress.ps1
#   m365-azure/Enable-HybridRemoteMailbox.ps1
#
# How the scripts are tested without a domain, Exchange or an elevated Windows box:
#
# 1. Pure functions (join-type decision, proxyAddresses transformation, signature check, LDAP
#    escaping, routing address) are lifted out of the script file with the PowerShell parser and
#    dot-sourced here. The script body never runs, so there are no side effects.
# 2. Behaviour (-WhatIf does nothing, a bad state exits 1, an apply calls the right cmdlet with the
#    right arguments) runs the real script by path. The cmdlets that would touch a domain, Exchange
#    or the system are replaced with Pester mocks. Where a cmdlet does not exist on the test host
#    (CI is Linux), an empty stand-in function is created so the mock has something to replace,
#    and removed afterwards.
# 3. Anything that needs the real thing is tagged RequiresHost and is excluded in CI.

BeforeDiscovery {
    $script:RunnerIsElevated = $false
    if ($IsWindows) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $script:RunnerIsElevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    # Returns the source text of the named functions from a script file, without running the script.
    function Get-ScriptFunctionText {
        param([string]$Path, [string[]]$Name)
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "Parse errors in ${Path}: $($errors[0].Message)" }
        $found = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $Name }, $true)
        if ($found.Count -ne $Name.Count) { throw "Expected $($Name.Count) functions in $Path, found $($found.Count)." }
        ($found | ForEach-Object { $_.Extent.Text }) -join "`n"
    }

    # Runs a script by path and returns its exit code and output. A script's `exit` ends only the script.
    function Invoke-ScriptFile {
        param([string]$Path, [hashtable]$Params)
        $global:LASTEXITCODE = $null
        $output = & $Path @Params *>&1
        [pscustomobject]@{ ExitCode = $global:LASTEXITCODE; Output = $output }
    }

    # Creates an empty stand-in for each command that does not exist on this host, so it can be mocked.
    function New-CommandStub {
        param([hashtable]$Stubs)
        $made = @()
        foreach ($name in $Stubs.Keys) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($Stubs[$name]))
                $made += $name
            }
        }
        $made
    }
}

Describe 'Get-DirectoryJoinInfo' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ScriptFunctionText `
            -Path (Join-Path $script:Repo 'endpoint-inventory' 'Get-DirectoryJoinInfo.ps1') `
            -Name 'Resolve-JoinType', 'ConvertFrom-DsregStatus', 'Get-JoinSummary')))
    }

    It 'decides join type for domain=<PartOfDomain> azure=<Azure>' -ForEach @(
        @{ PartOfDomain = $false; Azure = $false; Expected = 'Workgroup' }
        @{ PartOfDomain = $true;  Azure = $false; Expected = 'LocalAD' }
        @{ PartOfDomain = $false; Azure = $true;  Expected = 'AzureAD' }
        @{ PartOfDomain = $true;  Azure = $true;  Expected = 'Hybrid' }
    ) {
        Resolve-JoinType -PartOfDomain $PartOfDomain -AzureAdJoined $Azure | Should -Be $Expected
    }

    It 'parses dsregcmd output' {
        $text = @(
            '+----------------------------------------------------------------------+'
            '| Device State                                                         |'
            '+----------------------------------------------------------------------+'
            '             AzureAdJoined : YES'
            '          EnterpriseJoined : NO'
            '              DomainJoined : NO'
        )
        $state = ConvertFrom-DsregStatus -Text $text
        $state.AzureAdJoined | Should -BeTrue
        $state.DomainJoined  | Should -BeFalse
    }

    It 'treats empty dsregcmd output as not joined and flags it as unrecognised' {
        $state = ConvertFrom-DsregStatus -Text @()
        $state.AzureAdJoined | Should -BeFalse
        $state.DomainJoined  | Should -BeFalse
        $state.Recognized    | Should -BeFalse
    }

    It 'flags output in another language as unrecognised' {
        (ConvertFrom-DsregStatus -Text @('AzureAdJoined : OUI', 'Estado del dispositivo')).Recognized | Should -BeFalse
    }

    It 'flags parseable output as recognised' {
        (ConvertFrom-DsregStatus -Text @('   AzureAdJoined : NO')).Recognized | Should -BeTrue
    }

    It 'summarises a hybrid machine with a remote sync server' {
        $info = [pscustomobject]@{
            JoinType = 'Hybrid'; DomainName = 'corp.example.com'; PrimaryDC = 'dc1.corp.example.com'
            AdSyncServer = 'sync1.corp.example.com'; AdSyncIsLocal = $false; AdSyncDetectedBy = @('directory service connection point')
        }
        $s = Get-JoinSummary -Info $info
        $s | Should -Match 'Hybrid'
        $s | Should -Match 'dc1\.corp\.example\.com'
        $s | Should -Match 'sync1\.corp\.example\.com'
    }

    It 'says "not detected" instead of guessing when nothing was found' {
        $info = [pscustomobject]@{
            JoinType = 'LocalAD'; DomainName = 'corp.example.com'; PrimaryDC = $null
            AdSyncServer = $null; AdSyncIsLocal = $false; AdSyncDetectedBy = @()
        }
        $s = Get-JoinSummary -Info $info
        $s | Should -Match 'Primary DC: not detected'
        $s | Should -Match 'sync server: not detected'
    }

    It 'does not mention a DC for a workgroup machine' {
        $info = [pscustomobject]@{ JoinType = 'Workgroup'; DomainName = $null; PrimaryDC = $null; AdSyncServer = $null; AdSyncIsLocal = $false; AdSyncDetectedBy = @() }
        Get-JoinSummary -Info $info | Should -Not -Match 'DC'
    }

    It 'reports the real machine' -Tag 'RequiresHost' {
        $info = & (Join-Path $script:Repo 'endpoint-inventory' 'Get-DirectoryJoinInfo.ps1') 6>$null
        $info.JoinType | Should -BeIn 'Workgroup', 'LocalAD', 'AzureAD', 'Hybrid'
    }
}

Describe 'Update-Sysmon' {
    BeforeAll {
        $script:Sysmon = Join-Path $script:Repo 'maintenance' 'Update-Sysmon.ps1'
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:Sysmon -Name 'Test-MicrosoftSignature', 'Get-SysmonBinaryName')))
        $script:Config = Join-Path $TestDrive 'sysmon-config.xml'
        Set-Content -LiteralPath $script:Config -Value '<Sysmon schemaversion="4.90"/>'
    }

    Context 'signature check' {
        It 'accepts a valid Microsoft signature' {
            $sig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }
            Test-MicrosoftSignature -Signature $sig | Should -BeTrue
        }
        It 'rejects a valid signature from someone else' {
            $sig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Software Ltd, O=Example Software Ltd, C=US' } }
            Test-MicrosoftSignature -Signature $sig | Should -BeFalse
        }
        It 'rejects a look-alike subject' {
            $sig = [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Not Microsoft Corporation Inc, O=Example' } }
            Test-MicrosoftSignature -Signature $sig | Should -BeFalse
        }
        It 'rejects status <Status>' -ForEach @(
            @{ Status = 'NotSigned' }, @{ Status = 'HashMismatch' }, @{ Status = 'NotTrusted' }, @{ Status = 'UnknownError' }
        ) {
            $sig = [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation' } }
            Test-MicrosoftSignature -Signature $sig | Should -BeFalse
        }
        It 'rejects a missing signature or certificate' {
            Test-MicrosoftSignature -Signature $null | Should -BeFalse
            Test-MicrosoftSignature -Signature ([pscustomobject]@{ Status = 'Valid'; SignerCertificate = $null }) | Should -BeFalse
        }
    }

    It 'picks a Sysmon binary name' {
        Get-SysmonBinaryName | Should -BeIn 'Sysmon64.exe', 'Sysmon.exe'
    }

    It 'rejects a non-https download URL' {
        { & $script:Sysmon -ConfigPath $script:Config -DownloadUrl 'http://example.com/Sysmon.zip' -LogPath $TestDrive -WhatIf } | Should -Throw
    }

    It 'declares -ConfigPath as mandatory' {
        $attr = (Get-Command $script:Sysmon).Parameters['ConfigPath'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $attr.Mandatory | Should -BeTrue
    }

    It 'rejects a ConfigPath that does not exist' {
        { & $script:Sysmon -ConfigPath (Join-Path $TestDrive 'missing.xml') -LogPath $TestDrive -WhatIf } | Should -Throw
    }

    Context 'behaviour with the network mocked' {
        BeforeEach {
            Mock Invoke-WebRequest { }
            Mock Start-Process { }
        }

        It '-WhatIf downloads nothing, installs nothing and exits 0' {
            $r = Invoke-ScriptFile -Path $script:Sysmon -Params @{ ConfigPath = $script:Config; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'refuses to run when not elevated and downloads nothing' -Skip:$script:RunnerIsElevated {
            $r = Invoke-ScriptFile -Path $script:Sysmon -Params @{ ConfigPath = $script:Config; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-Windows11Upgrade' {
    BeforeAll {
        $script:W11 = Join-Path $script:Repo 'patch-management' 'Invoke-Windows11Upgrade.ps1'
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:W11 -Name 'Get-InstallationAssistantArguments', 'Test-MicrosoftSignature')))
        $script:W11Stubs = New-CommandStub @{
            'Stop-Service'             = 'param($Name, [switch]$Force)'
            'Start-Service'            = 'param($Name, $ErrorAction)'
            'Set-WUSettings'           = 'param([switch]$TargetReleaseVersion, $TargetReleaseVersionInfo, $ProductVersion, $Confirm)'
            'Get-WindowsUpdate'        = 'param([switch]$MicrosoftUpdate, [switch]$AcceptAll, [switch]$Install, [switch]$IgnoreReboot, $KBArticleID)'
            'Get-AuthenticodeSignature' = 'param($FilePath)'
        }
    }
    AfterAll {
        foreach ($n in $script:W11Stubs) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
    }

    Context 'Assistant arguments' {
        It 'does not include /skipcompatcheck by default' {
            Get-InstallationAssistantArguments | Should -Not -Contain '/skipcompatcheck'
        }
        It 'includes /skipcompatcheck only when asked' {
            Get-InstallationAssistantArguments -SkipCompatCheck | Should -Contain '/skipcompatcheck'
        }
        It 'always passes the unattended switches' {
            Get-InstallationAssistantArguments | Should -Contain '/quietinstall'
            Get-InstallationAssistantArguments | Should -Contain '/auto'
        }
    }

    Context 'signature check' {
        It 'accepts Microsoft and rejects others' {
            Test-MicrosoftSignature -Signature ([pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation' } }) | Should -BeTrue
            Test-MicrosoftSignature -Signature ([pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Example Software Ltd' } }) | Should -BeFalse
            Test-MicrosoftSignature -Signature ([pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }) | Should -BeFalse
        }
    }

    Context 'parameter validation' {
        It 'rejects an unknown method' {
            { & $script:W11 -Method Magic -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'rejects a malformed target release' {
            { & $script:W11 -Method WindowsUpdate -TargetReleaseVersion '2024' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'rejects a malformed KB id' {
            { & $script:W11 -Method WindowsUpdate -TargetReleaseVersion 24H2 -KBArticleID 'not-a-kb' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'accepts KB ids with or without the prefix' {
            { & $script:W11 -Method WindowsUpdate -TargetReleaseVersion 24H2 -KBArticleID 'KB5012345', '5012346', 'kb5012347' -LogPath $TestDrive -WhatIf } | Should -Not -Throw
        }
        It 'rejects a non-https Assistant URL' {
            { & $script:W11 -Method InstallationAssistant -AssistantUrl 'http://example.com/a.exe' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'accepts a lower-case release' {
            { & $script:W11 -Method WindowsUpdate -TargetReleaseVersion '24h2' -LogPath $TestDrive -WhatIf } | Should -Not -Throw
        }
    }

    Context 'argument rules (exit 1, even with -WhatIf)' {
        BeforeEach {
            Mock Invoke-WebRequest { }
            Mock Start-Process { }
            Mock Stop-Service { }
            Mock Set-WUSettings { }
            Mock Get-WindowsUpdate { }
        }
        It 'WindowsUpdate needs a target release' {
            (Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'WindowsUpdate'; LogPath = $TestDrive; WhatIf = $true }).ExitCode | Should -Be 1
        }
        It 'WindowsUpdate rejects -SkipCompatCheck' {
            $r = Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'WindowsUpdate'; TargetReleaseVersion = '24H2'; SkipCompatCheck = $true; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-WUSettings -Times 0 -Exactly
        }
        It 'InstallationAssistant rejects a target release' {
            (Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'InstallationAssistant'; TargetReleaseVersion = '24H2'; LogPath = $TestDrive; WhatIf = $true }).ExitCode | Should -Be 1
        }
    }

    Context 'behaviour' {
        BeforeEach {
            Mock Invoke-WebRequest { }
            Mock Start-Process { }
            Mock Copy-Item { }
            Mock Stop-Service { }
            Mock Start-Service { }
            Mock Set-WUSettings { }
            Mock Get-WindowsUpdate { }
        }
        It '-WhatIf with InstallationAssistant changes nothing and exits 0' {
            $r = Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'InstallationAssistant'; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Stop-Service -Times 0 -Exactly
            Should -Invoke Copy-Item -Times 0 -Exactly
        }
        It '-WhatIf with WindowsUpdate changes nothing and exits 0' {
            $r = Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'WindowsUpdate'; TargetReleaseVersion = '24H2'; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Set-WUSettings -Times 0 -Exactly
            Should -Invoke Get-WindowsUpdate -Times 0 -Exactly
        }
        It 'refuses to touch staging while an upgrade process is running' {
            Mock Get-Process { [pscustomobject]@{ ProcessName = 'SetupHost' } }
            $r = Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'InstallationAssistant'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            ($r.Output | Out-String) | Should -Match 'upgrade appears to be running'
            Should -Invoke Stop-Service -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }
        It 'refuses to run when not elevated' -Skip:$script:RunnerIsElevated {
            Mock Get-Process { }
            $r = Invoke-ScriptFile -Path $script:W11 -Params @{ Method = 'InstallationAssistant'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

}

Describe 'Restore-DeletedADUser' {
    BeforeAll {
        $script:Restore = Join-Path $script:Repo 'user-management' 'Restore-DeletedADUser.ps1'
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:Restore -Name 'ConvertTo-LdapFilterValue', 'New-DeletedUserLdapFilter')))
        $script:RestoreStubs = New-CommandStub @{
            'Get-ADObject'     = 'param($LDAPFilter, $Identity, $Properties, $Server, [switch]$IncludeDeletedObjects)'
            'Restore-ADObject' = 'param($Identity, $TargetPath, $Server)'
        }
        $script:Ou = 'OU=Staff,DC=contoso,DC=com'
        $script:Guid = [guid]'11111111-2222-3333-4444-555555555555'
    }
    AfterAll {
        foreach ($n in $script:RestoreStubs) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
    }

    Context 'LDAP filter' {
        It 'escapes filter metacharacters' {
            ConvertTo-LdapFilterValue 'a*b(c)d\e' | Should -Be 'a\2ab\28c\29d\5ce'
        }
        It 'builds a filter for SamAccountName' {
            New-DeletedUserLdapFilter -SamAccountName 'jdoe' | Should -Be '(&(objectClass=user)(isDeleted=TRUE)(sAMAccountName=jdoe))'
        }
        It 'builds a filter for display name' {
            New-DeletedUserLdapFilter -DisplayName 'Jane Doe' | Should -Be '(&(objectClass=user)(isDeleted=TRUE)(displayName=Jane Doe))'
        }
        It 'cannot be widened by injection' {
            New-DeletedUserLdapFilter -SamAccountName 'x)(objectClass=*' | Should -Be '(&(objectClass=user)(isDeleted=TRUE)(sAMAccountName=x\29\28objectClass=\2a))'
        }
        It 'needs a search value' {
            { New-DeletedUserLdapFilter } | Should -Throw
        }
    }

    Context 'parameters' {
        It 'rejects a TargetOU that is not a distinguished name' {
            { & $script:Restore -SamAccountName jdoe -TargetOU 'Staff' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'does not accept both SamAccountName and DisplayName' {
            { & $script:Restore -SamAccountName jdoe -DisplayName 'Jane Doe' -TargetOU $script:Ou -LogPath $TestDrive -WhatIf } | Should -Throw
        }
    }

    Context 'behaviour with AD mocked' {
        BeforeEach {
            $deleted = [pscustomobject]@{
                Name = 'Jane Doe'; sAMAccountName = 'jdoe'; displayName = 'Jane Doe'
                DistinguishedName = 'CN=Jane Doe\0ADEL:11111111-2222-3333-4444-555555555555,CN=Deleted Objects,DC=contoso,DC=com'
                ObjectGUID = $script:Guid; lastKnownParent = 'OU=Old,DC=contoso,DC=com'; whenChanged = (Get-Date)
            }
            $restored = [pscustomobject]@{ sAMAccountName = 'jdoe'; DistinguishedName = "CN=Jane Doe,$($script:Ou)"; ObjectGUID = $script:Guid }
            Mock Restore-ADObject { }
            Mock Get-ADObject { $deleted } -ParameterFilter { $LDAPFilter }
            Mock Get-ADObject { $restored } -ParameterFilter { $Identity }
        }

        It 'exits 1 and restores nothing when no object matches' {
            Mock Get-ADObject { @() } -ParameterFilter { $LDAPFilter }
            $r = Invoke-ScriptFile -Path $script:Restore -Params @{ SamAccountName = 'nobody'; TargetOU = $script:Ou; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Restore-ADObject -Times 0 -Exactly
        }

        It 'exits 1 and restores nothing when several objects match' {
            Mock Get-ADObject { @($deleted, $deleted) } -ParameterFilter { $LDAPFilter }
            $r = Invoke-ScriptFile -Path $script:Restore -Params @{ DisplayName = 'Jane Doe'; TargetOU = $script:Ou; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Restore-ADObject -Times 0 -Exactly
        }

        It '-WhatIf shows the match and restores nothing' {
            $r = Invoke-ScriptFile -Path $script:Restore -Params @{ SamAccountName = 'jdoe'; TargetOU = $script:Ou; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Restore-ADObject -Times 0 -Exactly
            ($r.Output | Out-String) | Should -Match 'jdoe'
        }

        It 'restores the single match to the target OU by GUID' {
            $r = Invoke-ScriptFile -Path $script:Restore -Params @{ SamAccountName = 'jdoe'; TargetOU = $script:Ou; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Should -Invoke Restore-ADObject -Times 1 -Exactly -ParameterFilter { $Identity -eq $script:Guid -and $TargetPath -eq $script:Ou }
        }

        It 'exits 1 when the read-back is not under the target OU' {
            Mock Get-ADObject { [pscustomobject]@{ sAMAccountName = 'jdoe'; DistinguishedName = 'CN=Jane Doe,OU=Elsewhere,DC=contoso,DC=com' } } -ParameterFilter { $Identity }
            $r = Invoke-ScriptFile -Path $script:Restore -Params @{ SamAccountName = 'jdoe'; TargetOU = $script:Ou; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
        }
    }

}

Describe 'Set-UserPrimarySmtpAddress' {
    BeforeAll {
        $script:SetSmtp = Join-Path $script:Repo 'm365-azure' 'Set-UserPrimarySmtpAddress.ps1'
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:SetSmtp -Name 'Get-UpdatedProxyAddresses')))
        $script:SmtpStubs = New-CommandStub @{
            'Get-ADUser' = 'param($LDAPFilter, $Identity, $Properties, $Server)'
            'Set-ADUser' = 'param($Identity, $Replace, $Server)'
        }
        $script:Guid = [guid]'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    }
    AfterAll {
        foreach ($n in $script:SmtpStubs) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
    }

    Context 'proxyAddresses transformation' {
        It 'makes the new address the only SMTP: entry and keeps the old primary as smtp:' {
            $r = Get-UpdatedProxyAddresses -ProxyAddresses @('SMTP:old@contoso.com', 'smtp:alias@contoso.com') -NewPrimary 'new@contoso.com'
            $r | Should -Contain 'SMTP:new@contoso.com'
            $r | Should -Contain 'smtp:old@contoso.com'
            $r | Should -Contain 'smtp:alias@contoso.com'
            @($r | Where-Object { $_ -cmatch '^SMTP:' }).Count | Should -Be 1
            $r.Count | Should -Be 3
        }

        It 'promotes an existing alias without duplicating it' {
            $r = Get-UpdatedProxyAddresses -ProxyAddresses @('SMTP:a@contoso.com', 'smtp:b@contoso.com') -NewPrimary 'b@contoso.com'
            $r | Should -Be @('SMTP:b@contoso.com', 'smtp:a@contoso.com')
        }

        It 'is unchanged in content when the address is already primary' {
            $r = Get-UpdatedProxyAddresses -ProxyAddresses @('SMTP:a@contoso.com', 'smtp:b@contoso.com') -NewPrimary 'a@contoso.com'
            $r | Should -Be @('SMTP:a@contoso.com', 'smtp:b@contoso.com')
        }

        It 'leaves non-SMTP entries alone' {
            $r = Get-UpdatedProxyAddresses -ProxyAddresses @('SMTP:a@contoso.com', 'x500:/o=Org/ou=Group/cn=Recipients/cn=a', 'SIP:a@contoso.com') -NewPrimary 'z@contoso.com'
            $r | Should -Contain 'x500:/o=Org/ou=Group/cn=Recipients/cn=a'
            $r | Should -Contain 'SIP:a@contoso.com'
            $r | Should -Contain 'smtp:a@contoso.com'
        }

        It 'removes duplicates ignoring case' {
            $r = Get-UpdatedProxyAddresses -ProxyAddresses @('smtp:NEW@Contoso.com', 'smtp:a@contoso.com', 'smtp:A@contoso.com') -NewPrimary 'new@contoso.com'
            $r.Count | Should -Be 2
            $r[0] | Should -Be 'SMTP:new@contoso.com'
        }

        It 'works from an empty or null list' {
            Get-UpdatedProxyAddresses -ProxyAddresses @() -NewPrimary 'n@contoso.com' | Should -Be @('SMTP:n@contoso.com')
            Get-UpdatedProxyAddresses -ProxyAddresses $null -NewPrimary 'n@contoso.com' | Should -Be @('SMTP:n@contoso.com')
        }

        It 'always puts the primary first' {
            (Get-UpdatedProxyAddresses -ProxyAddresses @('smtp:x@contoso.com', 'SMTP:y@contoso.com') -NewPrimary 'z@contoso.com')[0] | Should -Be 'SMTP:z@contoso.com'
        }
    }

    Context 'parameters' {
        It 'rejects a malformed address' {
            { & $script:SetSmtp -Identity jdoe -NewPrimarySmtp 'not-an-address' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'rejects an address that carries a prefix' {
            { & $script:SetSmtp -Identity jdoe -NewPrimarySmtp 'SMTP:a@contoso.com' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
    }

    Context 'behaviour with AD mocked' {
        BeforeEach {
            $user = [pscustomobject]@{
                DistinguishedName = 'CN=Jane Doe,OU=Staff,DC=contoso,DC=com'; SamAccountName = 'jdoe'
                UserPrincipalName = 'jdoe@contoso.com'; ObjectGUID = $script:Guid
                proxyAddresses = @('SMTP:old@contoso.com', 'smtp:alias@contoso.com')
            }
            $applied = [pscustomobject]@{ proxyAddresses = @('SMTP:new@contoso.com', 'smtp:old@contoso.com', 'smtp:alias@contoso.com') }
            Mock Get-ADUser { $user }    -ParameterFilter { $LDAPFilter }
            Mock Get-ADUser { $applied } -ParameterFilter { $Identity }
            Mock Set-ADUser { }
        }

        It 'exits 1 when no user matches' {
            Mock Get-ADUser { @() } -ParameterFilter { $LDAPFilter }
            $r = Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'nobody'; NewPrimarySmtp = 'new@contoso.com'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Set-ADUser -Times 0 -Exactly
        }

        It '-WhatIf prints before and after and writes nothing' {
            $r = Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'jdoe'; NewPrimarySmtp = 'new@contoso.com'; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Set-ADUser -Times 0 -Exactly
            ($r.Output | Out-String) | Should -Match 'SMTP:new@contoso.com'
        }

        It 'writes the transformed list and keeps the old primary as an alias' {
            $r = Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'jdoe'; NewPrimarySmtp = 'new@contoso.com'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Should -Invoke Set-ADUser -Times 1 -Exactly -ParameterFilter {
                $Replace.proxyAddresses -ccontains 'SMTP:new@contoso.com' -and
                $Replace.proxyAddresses -ccontains 'smtp:old@contoso.com' -and
                -not $Replace.ContainsKey('mail')
            }
        }

        It 'also sets mail when asked' {
            Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'jdoe'; NewPrimarySmtp = 'new@contoso.com'; UpdateMailAttribute = $true; LogPath = $TestDrive; Confirm = $false } | Out-Null
            Should -Invoke Set-ADUser -Times 1 -Exactly -ParameterFilter { $Replace.mail -eq 'new@contoso.com' }
        }

        It 'does nothing when the address is already primary' {
            $r = Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'jdoe'; NewPrimarySmtp = 'old@contoso.com'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Should -Invoke Set-ADUser -Times 0 -Exactly
        }

        It 'exits 1 when the read-back does not show the new primary' {
            Mock Get-ADUser { [pscustomobject]@{ proxyAddresses = @('SMTP:old@contoso.com') } } -ParameterFilter { $Identity }
            $r = Invoke-ScriptFile -Path $script:SetSmtp -Params @{ Identity = 'jdoe'; NewPrimarySmtp = 'new@contoso.com'; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
        }
    }

}

Describe 'Enable-HybridRemoteMailbox' {
    BeforeAll {
        $script:EnableRm = Join-Path $script:Repo 'm365-azure' 'Enable-HybridRemoteMailbox.ps1'
        . ([scriptblock]::Create((Get-ScriptFunctionText -Path $script:EnableRm -Name 'New-RemoteRoutingAddress', 'Get-DefaultAlias', 'Test-HasRoutingDomainAddress')))
        $script:RmStubs = New-CommandStub @{
            'Get-RemoteMailbox'    = 'param($Identity)'
            'Enable-RemoteMailbox' = 'param($Identity, $Alias, $RemoteRoutingAddress, [switch]$Archive)'
        }
        $script:Routing = 'contoso.mail.onmicrosoft.com'
    }
    AfterAll {
        foreach ($n in $script:RmStubs) { Remove-Item "function:global:$n" -ErrorAction SilentlyContinue }
    }

    Context 'pure helpers' {
        It 'builds the routing address' {
            New-RemoteRoutingAddress -Alias 'jdoe' -RoutingDomain 'contoso.mail.onmicrosoft.com' | Should -Be 'jdoe@contoso.mail.onmicrosoft.com'
        }
        It 'tolerates a leading @ on the domain' {
            New-RemoteRoutingAddress -Alias 'jdoe' -RoutingDomain '@contoso.mail.onmicrosoft.com' | Should -Be 'jdoe@contoso.mail.onmicrosoft.com'
        }
        It 'recognises an address in the routing domain, ignoring case' {
            Test-HasRoutingDomainAddress -Address @('SMTP:a@contoso.com', 'smtp:A@Contoso.Mail.OnMicrosoft.com') -RoutingDomain 'contoso.mail.onmicrosoft.com' | Should -BeTrue
        }
        It 'does not match a different tenant domain or a look-alike suffix' {
            Test-HasRoutingDomainAddress -Address @('SMTP:a@contoso.com', 'smtp:a@fabrikam.mail.onmicrosoft.com') -RoutingDomain 'contoso.mail.onmicrosoft.com' | Should -BeFalse
            Test-HasRoutingDomainAddress -Address @('smtp:a@evilcontoso.mail.onmicrosoft.com') -RoutingDomain 'contoso.mail.onmicrosoft.com' | Should -BeFalse
            Test-HasRoutingDomainAddress -Address @() -RoutingDomain 'contoso.mail.onmicrosoft.com' | Should -BeFalse
        }
        It 'derives the alias from an address or a bare name' {
            Get-DefaultAlias -Identity 'jane.doe@contoso.com' | Should -Be 'jane.doe'
            Get-DefaultAlias -Identity 'jdoe' | Should -Be 'jdoe'
        }
    }

    Context 'parameters' {
        It 'declares -RoutingDomain as mandatory' {
            $attr = (Get-Command $script:EnableRm).Parameters['RoutingDomain'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -BeTrue
        }
        It 'rejects a routing domain that is not a domain name' {
            { & $script:EnableRm -Identity jdoe@contoso.com -RoutingDomain 'notadomain' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
        It 'rejects an alias with spaces' {
            { & $script:EnableRm -Identity jdoe@contoso.com -RoutingDomain $script:Routing -Alias 'j doe' -LogPath $TestDrive -WhatIf } | Should -Throw
        }
    }

    Context 'behaviour with Exchange mocked' {
        BeforeEach {
            $global:RmCalls = 0
            Mock Get-RemoteMailbox {
                $global:RmCalls++
                if ($global:RmCalls -eq 1) { return $null }
                [pscustomobject]@{ Alias = 'jdoe'; EmailAddresses = @('SMTP:jdoe@contoso.com', 'smtp:jdoe@contoso.mail.onmicrosoft.com') }
            }
            Mock Enable-RemoteMailbox { }
        }
        AfterEach { Remove-Variable RmCalls -Scope Global -ErrorAction SilentlyContinue }

        It '-WhatIf enables nothing' {
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; WhatIf = $true }
            $r.ExitCode | Should -Be 0
            Should -Invoke Enable-RemoteMailbox -Times 0 -Exactly
        }

        It 'enables with the derived alias and routing address, then reads back' {
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Should -Invoke Enable-RemoteMailbox -Times 1 -Exactly -ParameterFilter {
                $Identity -eq 'jdoe@contoso.com' -and $Alias -eq 'jdoe' -and $RemoteRoutingAddress -eq 'jdoe@contoso.mail.onmicrosoft.com' -and -not $Archive
            }
            $global:RmCalls | Should -Be 2
        }

        It 'passes -Archive and an explicit alias through' {
            Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; Alias = 'janed'; Archive = $true; LogPath = $TestDrive; Confirm = $false } | Out-Null
            Should -Invoke Enable-RemoteMailbox -Times 1 -Exactly -ParameterFilter { $Alias -eq 'janed' -and $RemoteRoutingAddress -eq 'janed@contoso.mail.onmicrosoft.com' -and $Archive }
        }

        It 'does nothing and exits 0 when a remote mailbox already exists' {
            Mock Get-RemoteMailbox { [pscustomobject]@{ Alias = 'jdoe'; EmailAddresses = @('SMTP:jdoe@contoso.com', 'smtp:jdoe@contoso.mail.onmicrosoft.com') } }
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 0
            Should -Invoke Enable-RemoteMailbox -Times 0 -Exactly
        }

        It 'exits 1 and changes nothing when the existing mailbox has no address in the routing domain' {
            Mock Get-RemoteMailbox { [pscustomobject]@{ Alias = 'jdoe'; EmailAddresses = @('SMTP:jdoe@contoso.com', 'smtp:jdoe@fabrikam.mail.onmicrosoft.com') } }
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
            Should -Invoke Enable-RemoteMailbox -Times 0 -Exactly
        }

        It 'exits 1 when the read-back lacks the routing address' {
            Mock Get-RemoteMailbox {
                $global:RmCalls++
                if ($global:RmCalls -eq 1) { return $null }
                [pscustomobject]@{ Alias = 'jdoe'; EmailAddresses = @('SMTP:jdoe@contoso.com') }
            }
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
        }

        It 'exits 1 when Enable-RemoteMailbox fails' {
            Mock Enable-RemoteMailbox { throw 'boom' }
            $r = Invoke-ScriptFile -Path $script:EnableRm -Params @{ Identity = 'jdoe@contoso.com'; RoutingDomain = $script:Routing; LogPath = $TestDrive; Confirm = $false }
            $r.ExitCode | Should -Be 1
        }
    }

}

Describe 'Scripts copied away from framework/' {
    # A script that cannot load MSPLogger must still honour the exit-code contract (1), not die with
    # whatever the host does for an uncaught error.
    It '<Name> exits 1 when framework/MSPLogger.ps1 is missing' -ForEach @(
        @{ Name = 'Update-Sysmon';            Folder = 'maintenance';      Params = @{ WhatIf = $true } }
        @{ Name = 'Invoke-Windows11Upgrade';  Folder = 'patch-management'; Params = @{ Method = 'InstallationAssistant'; WhatIf = $true } }
        @{ Name = 'Restore-DeletedADUser';    Folder = 'user-management';  Params = @{ SamAccountName = 'jdoe'; TargetOU = 'OU=Staff,DC=contoso,DC=com'; WhatIf = $true } }
        @{ Name = 'Set-UserPrimarySmtpAddress'; Folder = 'm365-azure';     Params = @{ Identity = 'jdoe'; NewPrimarySmtp = 'new@contoso.com'; WhatIf = $true } }
        @{ Name = 'Enable-HybridRemoteMailbox'; Folder = 'm365-azure';     Params = @{ Identity = 'jdoe'; RoutingDomain = 'contoso.mail.onmicrosoft.com'; WhatIf = $true } }
    ) {
        $dir = Join-Path $TestDrive "isolated-$Name" 'scripts'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:Repo $Folder "$Name.ps1") -Destination $dir
        $params = $Params.Clone()
        $params.LogPath = $TestDrive
        if ($Name -eq 'Update-Sysmon') {
            $cfg = Join-Path $TestDrive 'iso-config.xml'
            Set-Content -LiteralPath $cfg -Value '<Sysmon/>'
            $params.ConfigPath = $cfg
        }
        (Invoke-ScriptFile -Path (Join-Path $dir "$Name.ps1") -Params $params).ExitCode | Should -Be 1
    }
}
