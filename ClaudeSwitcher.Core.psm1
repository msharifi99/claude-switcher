Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not ('ClaudeSwitcher.DesktopSqlite' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'DesktopSqlite.cs') }
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData }
    catch { Add-Type -AssemblyName System.Security }
}
$script:AuthKeys = @('oauth:tokenCache','oauth:tokenCacheV2','lastKnownAccountUuid')

function Read-JsonText {
    param([string]$Text)
    # Recent PowerShell versions otherwise turn ISO strings into DateTime values when round-tripping preferences.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { ConvertFrom-Json -InputObject $Text -DateKind String }
    else { ConvertFrom-Json -InputObject $Text }
}
function Read-OptionalText { param([string]$Path) if ([IO.File]::Exists($Path)) { [IO.File]::ReadAllText($Path) } else { $null } }
function Write-AtomicText {
    param([string]$Path,[string]$Text)
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temp = Join-Path (Split-Path $Path -Parent) ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllText($temp,$Text,(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Restore-Text { param([string]$Path,$Text) if ($null -eq $Text) { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } } else { Write-AtomicText $Path $Text } }
function Protect-Data {
    param($Data)
    # SecureString is limited to 65,536 characters. Recovery journals include complete
    # before/after config files and can easily exceed that; DPAPI accepts byte arrays.
    $plain = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Data -Depth 100 -Compress))
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
        'CCD-DPAPI-1:' + [Convert]::ToBase64String($encrypted)
    } finally { [Array]::Clear($plain,0,$plain.Length) }
}
function Read-ProtectedData {
    param([string]$Path)
    $secure = $null; $ptr = [IntPtr]::Zero; $plain = $null
    try {
        $encoded = [IO.File]::ReadAllText($Path)
        if ($encoded.StartsWith('CCD-DPAPI-1:',[StringComparison]::Ordinal)) {
            $encrypted = [Convert]::FromBase64String($encoded.Substring(12))
            $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser)
            return Read-JsonText ([Text.Encoding]::UTF8.GetString($plain))
        }
        # Keep the original SecureString-based accounts and backups readable.
        $secure = ConvertTo-SecureString $encoded
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        Read-JsonText ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr))
    } catch { throw "Cannot read encrypted storage: $Path. Use the Windows user and machine that saved it. Keep this file for recovery." }
    finally {
        if ($plain) { [Array]::Clear($plain,0,$plain.Length) }
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        if ($secure) { $secure.Dispose() }
    }
}
function Get-TextHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) } finally { $sha.Dispose() }
}
function Assert-UUID { param([string]$Value) if ($Value -notmatch '^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$') { throw 'Account and organization IDs must be UUIDs.' } }
function Assert-Name { param([string]$Name) if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64 -or $Name -match '[\x00-\x1f]') { throw 'Choose an account label between 1 and 64 characters.' } }
function Assert-NoLinks {
    param([string]$Path)
    $itemPath = [IO.Path]::GetFullPath($Path)
    while ($itemPath) {
        if (Test-Path -LiteralPath $itemPath) {
            $item = Get-Item -LiteralPath $itemPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing a linked storage path: $itemPath" }
        }
        $itemPath = Split-Path $itemPath -Parent
    }
}
function New-SwitcherContext {
    param([string]$DesktopDataDirectory,[string]$GlobalConfigPath,[string]$StoreDirectory)
    if ($env:OS -ne 'Windows_NT') { throw 'This tool requires Windows.' }
    if (-not $DesktopDataDirectory) {
        $candidates = @()
        $standard = Join-Path $env:APPDATA 'Claude'
        if (Test-Path -LiteralPath (Join-Path $standard 'config.json')) { $candidates += $standard }
        $local = Join-Path $env:LOCALAPPDATA 'Claude'
        if (Test-Path -LiteralPath (Join-Path $local 'config.json')) { $candidates += $local }
        $localData = Join-Path $env:LOCALAPPDATA 'Claude-Data'
        if (Test-Path -LiteralPath $localData) {
            foreach ($profile in @(Get-ChildItem -LiteralPath $localData -Directory -Filter 'claude_*')) {
                if (Test-Path -LiteralPath (Join-Path $profile.FullName 'config.json')) { $candidates += $profile.FullName }
            }
        }
        $packages = Join-Path $env:LOCALAPPDATA 'Packages'
        if (Test-Path -LiteralPath $packages) {
            foreach ($package in @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'Claude_*')) {
                $path = Join-Path $package.FullName 'LocalCache\Roaming\Claude'
                if (Test-Path -LiteralPath (Join-Path $path 'config.json')) { $candidates += $path }
            }
        }
        if ($candidates.Count -ne 1) { throw 'Could not identify one Claude Desktop profile. Pass -DesktopDataDirectory with the folder containing config.json and Network\Cookies.' }
        $DesktopDataDirectory = $candidates[0]
    }
    if (-not $GlobalConfigPath) { $GlobalConfigPath = Join-Path $env:USERPROFILE '.claude.json' }
    if (-not $StoreDirectory) { $StoreDirectory = Join-Path $env:LOCALAPPDATA 'ClaudeDesktopSwitcher' }
    $data = [IO.Path]::GetFullPath($DesktopDataDirectory)
    [pscustomobject]@{
        DataDirectory = $data; ConfigPath = Join-Path $data 'config.json'; CookiePath = Join-Path $data 'Network\Cookies'
        LocalStatePath = Join-Path $data 'Local State'; SessionsPath = Join-Path $data 'claude-code-sessions'
        GlobalConfigPath = [IO.Path]::GetFullPath($GlobalConfigPath); StoreDirectory = [IO.Path]::GetFullPath($StoreDirectory)
        VaultPath = Join-Path ([IO.Path]::GetFullPath($StoreDirectory)) 'desktop-accounts.dpapi'
        JournalPath = Join-Path ([IO.Path]::GetFullPath($StoreDirectory)) 'recovery.dpapi'
        LoginPath = Join-Path ([IO.Path]::GetFullPath($StoreDirectory)) 'pending-login.dpapi'
    }
}
function Get-ClaudeProcesses {
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match '^claude(\.exe)?$' -or ($_.Name -match '^node(\.exe)?$' -and $_.CommandLine -match '@anthropic-ai[\\/]claude-code')
    })
}
function Assert-ClaudeClosed { if (@(Get-ClaudeProcesses).Count) { throw 'Close Claude Desktop completely, including its tray icon, and any running Claude Code sessions before continuing. No process will be stopped automatically.' } }
function Read-Vault {
    param($Context)
    if (-not [IO.File]::Exists($Context.VaultPath)) { return [pscustomobject]@{ Version=2; DataDirectory=$Context.DataDirectory; GlobalConfigPath=$Context.GlobalConfigPath; Accounts=@() } }
    $vault = Read-ProtectedData $Context.VaultPath
    if ($vault.Version -ne 2 -or $vault.DataDirectory -ne $Context.DataDirectory -or $vault.GlobalConfigPath -ne $Context.GlobalConfigPath) { throw 'This vault belongs to a different Desktop profile or format. Use its original paths or a separate StoreDirectory.' }
    $vault
}
function Save-Vault { param($Context,$Vault) Write-AtomicText $Context.VaultPath (Protect-Data $Vault) }
function Get-AuthCookies { param($Context) @([ClaudeSwitcher.DesktopSqlite]::Query($Context.CookiePath,'SELECT * FROM cookies WHERE ' + [ClaudeSwitcher.DesktopSqlite]::AuthPredicate + ' ORDER BY host_key,name,path,creation_utc')) }
function ConvertTo-NativeRows {
    param($Rows)
    $result = New-Object 'Collections.Generic.List[ClaudeSwitcher.SqlRow]'
    foreach ($row in @($Rows)) {
        $cells = New-Object 'Collections.Generic.List[ClaudeSwitcher.SqlCell]'
        foreach ($cell in $row.Cells) {
            $value = New-Object ClaudeSwitcher.SqlCell
            $value.Name = $cell.Name; $value.Type = $cell.Type; $value.Value = $cell.Value
            $cells.Add($value)
        }
        $native = New-Object ClaudeSwitcher.SqlRow; $native.Cells = $cells.ToArray(); $result.Add($native)
    }
    return ,$result.ToArray()
}
function Set-AuthCookies { param($Context,$Rows) [ClaudeSwitcher.DesktopSqlite]::ReplaceAuthCookies($Context.CookiePath,(ConvertTo-NativeRows $Rows)) }
function Get-CookieKeyHash {
    param($Context)
    $state = Read-JsonText ([IO.File]::ReadAllText($Context.LocalStatePath))
    if (-not $state.PSObject.Properties['os_crypt'] -or -not $state.os_crypt.PSObject.Properties['encrypted_key']) { throw 'Unsupported Desktop cookie encryption metadata. Local State must contain os_crypt.encrypted_key.' }
    Get-TextHash $state.os_crypt.encrypted_key
}
function Get-DesktopIdentity {
    param($Context,[string]$OrganizationId)
    $config = Read-JsonText ([IO.File]::ReadAllText($Context.ConfigPath))
    if (-not $config.PSObject.Properties['lastKnownAccountUuid']) { throw 'No Desktop account identity found. Sign in to Claude Desktop first.' }
    $accountId = [string]$config.lastKnownAccountUuid; Assert-UUID $accountId
    $metadata = $null
    $raw = Read-OptionalText $Context.GlobalConfigPath
    if ($raw) {
        $globalState = Read-JsonText $raw
        if ($globalState.PSObject.Properties['oauthAccount'] -and $globalState.oauthAccount -and
            $globalState.oauthAccount.PSObject.Properties['accountUuid'] -and $globalState.oauthAccount.accountUuid -eq $accountId) {
            $metadata = $globalState.oauthAccount
            if (-not $OrganizationId -and $metadata.PSObject.Properties['organizationUuid']) { $OrganizationId = $metadata.organizationUuid }
        }
    }
    if (-not $OrganizationId) { throw 'Cannot establish the current Desktop organization. Open the Code tab once, close Claude, and try again; or supply -OrganizationId explicitly.' }
    Assert-UUID $OrganizationId
    if ($metadata -and $metadata.organizationUuid -ne $OrganizationId) { throw 'Organization override does not match the current account metadata.' }
    [pscustomobject]@{ AccountId=$accountId; OrganizationId=$OrganizationId; Metadata=$metadata; Config=$config }
}
function Get-AccountSnapshot {
    param($Context,[string]$Name,[string]$OrganizationId)
    $identity = Get-DesktopIdentity $Context $OrganizationId
    $cookies = @(Get-AuthCookies $Context)
    $sessionCookies = @($cookies | Where-Object { @($_.Cells | Where-Object { $_.Name -eq 'name' -and $_.Value -in @('sessionKey','sessionKeyV2','sessionKeyV3') }).Count })
    if (-not $sessionCookies.Count) { throw 'No Desktop sign-in cookie found. Sign in using the Desktop app before saving.' }
    $fields = @()
    foreach ($key in $script:AuthKeys) {
        $p = $identity.Config.PSObject.Properties[$key]
        if ($p) { $fields += [pscustomobject]@{ Name=$key; Value=$p.Value } }
    }
    [pscustomobject]@{ Name=$Name; AccountId=$identity.AccountId; OrganizationId=$identity.OrganizationId; OAuthAccount=$identity.Metadata
        AuthFields=$fields; Cookies=$cookies; CookieKeyHash=(Get-CookieKeyHash $Context); SavedAt=[DateTime]::UtcNow.ToString('o') }
}
function Get-SwitcherStatus {
    param($Context)
    $vault = Read-Vault $Context
    $identity = $null
    try { $identity = Get-DesktopIdentity $Context } catch { $identity = $null }
    $active = $null
    if ($identity) {
        $matches = @($vault.Accounts | Where-Object { $_.AccountId -eq $identity.AccountId -and $_.OrganizationId -eq $identity.OrganizationId })
        if ($matches.Count) { $active = $matches[0].Name }
    }
    [pscustomobject]@{ Active=$active; AccountId=$(if ($identity) {$identity.AccountId} else {$null}); OrganizationId=$(if ($identity) {$identity.OrganizationId} else {$null})
        RecoveryPending=[IO.File]::Exists($Context.JournalPath); LoginPending=[IO.File]::Exists($Context.LoginPath)
        Accounts=@($vault.Accounts | ForEach-Object { [pscustomobject]@{ Name=$_.Name; AccountId=$_.AccountId; OrganizationId=$_.OrganizationId; SavedAt=$_.SavedAt; Active=($_.Name -eq $active) } }) }
}
function Enter-Lock {
    param($Context)
    Assert-NoLinks $Context.DataDirectory; Assert-NoLinks $Context.StoreDirectory; Assert-NoLinks $Context.GlobalConfigPath
    [IO.Directory]::CreateDirectory($Context.StoreDirectory) | Out-Null
    $first = $null
    try {
        $first = [IO.File]::Open((Join-Path $Context.StoreDirectory 'vault.lock'),'OpenOrCreate','ReadWrite','None')
        $second = [IO.File]::Open((Join-Path $Context.DataDirectory '.desktop-switcher.lock'),'OpenOrCreate','ReadWrite','None')
        @($first,$second)
    } catch { if ($first) { $first.Dispose() }; throw 'Another operation is using this Desktop profile, or its storage path is unavailable.' }
}
function Compare-Cookies { param($First,$Second) (ConvertTo-Json -InputObject @($First) -Depth 100 -Compress) -ceq (ConvertTo-Json -InputObject @($Second) -Depth 100 -Compress) }
function Repair-PendingSwitch {
    param($Context)
    if (-not [IO.File]::Exists($Context.JournalPath)) { return }
    Assert-ClaudeClosed
    $journal = Read-ProtectedData $Context.JournalPath
    if ($journal.DataDirectory -ne $Context.DataDirectory -or $journal.GlobalConfigPath -ne $Context.GlobalConfigPath) { throw 'Recovery backup belongs to a different Desktop profile.' }
    foreach ($file in $journal.Files) {
        $current = Read-OptionalText $file.Path
        if ($current -cne $file.Old -and $current -cne $file.New) { throw 'Desktop files changed after an interrupted operation. Recovery stopped to preserve newer data. Keep recovery.dpapi.' }
    }
    $cookies = @(Get-AuthCookies $Context)
    if (-not (Compare-Cookies $cookies $journal.OldCookies) -and -not (Compare-Cookies $cookies $journal.NewCookies)) { throw 'Desktop cookies changed after an interrupted operation. Recovery stopped. Keep recovery.dpapi.' }
    Set-AuthCookies $Context $journal.OldCookies
    foreach ($file in $journal.Files) { Restore-Text $file.Path $file.Old }
    [IO.File]::Delete($Context.JournalPath)
}
function Invoke-LockedOperation {
    param($Context,[scriptblock]$Operation)
    $locks = @(Enter-Lock $Context)
    try { Assert-ClaudeClosed; Repair-PendingSwitch $Context; & $Operation }
    finally { foreach ($lock in $locks) { $lock.Dispose() } }
}
function Invoke-DesktopTransaction {
    param($Context,$Cookies,$Files)
    $journal = [pscustomobject]@{ DataDirectory=$Context.DataDirectory; GlobalConfigPath=$Context.GlobalConfigPath
        OldCookies=@(Get-AuthCookies $Context); NewCookies=@($Cookies); Files=@($Files) }
    Write-AtomicText $Context.JournalPath (Protect-Data $journal)
    try {
        Set-AuthCookies $Context $Cookies
        foreach ($file in $Files) { Restore-Text $file.Path $file.New }
        [IO.File]::Delete($Context.JournalPath)
    } catch {
        Repair-PendingSwitch $Context
        throw 'Operation failed and was rolled back. Previous Desktop authentication and local records were restored.'
    }
}
function New-FileChange { param([string]$Path,$New) Assert-NoLinks $Path; [pscustomobject]@{ Path=$Path; Old=(Read-OptionalText $Path); New=$New } }
function Get-AuthFileChanges {
    param($Context,$Snapshot)
    $raw = [IO.File]::ReadAllText($Context.ConfigPath)
    $config = Read-JsonText $raw
    foreach ($key in $script:AuthKeys) { $config.PSObject.Properties.Remove($key) }
    foreach ($field in $Snapshot.AuthFields) { $config | Add-Member -NotePropertyName $field.Name -NotePropertyValue $field.Value -Force }
    New-FileChange $Context.ConfigPath (ConvertTo-Json -InputObject $config -Depth 100)
    $globalRaw = Read-OptionalText $Context.GlobalConfigPath
    if ($globalRaw) {
        $globalState = Read-JsonText $globalRaw
        if ($Snapshot.OAuthAccount) { $globalState | Add-Member -NotePropertyName oauthAccount -NotePropertyValue $Snapshot.OAuthAccount -Force }
        else { $globalState.PSObject.Properties.Remove('oauthAccount') }
        New-FileChange $Context.GlobalConfigPath (ConvertTo-Json -InputObject $globalState -Depth 100)
    }
}
function Get-SessionChanges {
    param($Context,$Snapshot)
    Assert-UUID $Snapshot.AccountId; Assert-UUID $Snapshot.OrganizationId
    $targetDir = Join-Path (Join-Path $Context.SessionsPath $Snapshot.AccountId) $Snapshot.OrganizationId
    Assert-NoLinks $Context.SessionsPath; Assert-NoLinks $targetDir
    if (-not [IO.Directory]::Exists($Context.SessionsPath)) { return }
    $best = @{}
    # Only local Code descriptors. No cloud sessions, Cowork data, schedules, tombstones or transcripts.
    foreach ($account in @(Get-ChildItem -LiteralPath $Context.SessionsPath -Directory)) {
        if ($account.Name -notmatch '^[a-fA-F0-9-]{36}$') { continue }
        Assert-NoLinks $account.FullName
        foreach ($org in @(Get-ChildItem -LiteralPath $account.FullName -Directory)) {
            if ($org.Name -notmatch '^[a-fA-F0-9-]{36}$') { continue }
            Assert-NoLinks $org.FullName
            foreach ($file in @(Get-ChildItem -LiteralPath $org.FullName -File -Filter 'local_*.json')) {
                Assert-NoLinks $file.FullName
                $raw = [IO.File]::ReadAllText($file.FullName)
                $record = Read-JsonText $raw
                if (-not $record.PSObject.Properties['sessionId'] -or $record.sessionId -cne [IO.Path]::GetFileNameWithoutExtension($file.Name)) { throw "Unrecognized local Code session descriptor: $($file.Name)" }
                if (-not $record.PSObject.Properties['cwd'] -or -not $record.cwd) { continue }
                if (($record.PSObject.Properties['remoteTarget'] -and $record.remoteTarget) -or
                    ($record.PSObject.Properties['remoteHost'] -and $record.remoteHost) -or
                    ($record.PSObject.Properties['sshHost'] -and $record.sshHost)) { continue }
                $activity = 0
                if ($record.PSObject.Properties['lastActivityAt']) { $activity = [double]$record.lastActivityAt }
                if (-not $best.ContainsKey($file.Name) -or $activity -gt $best[$file.Name].Activity -or
                    ($activity -eq $best[$file.Name].Activity -and $file.LastWriteTimeUtc -gt $best[$file.Name].Time)) {
                    $best[$file.Name] = [pscustomobject]@{ Raw=$raw; Activity=$activity; Time=$file.LastWriteTimeUtc }
                }
            }
        }
    }
    foreach ($name in @($best.Keys | Sort-Object)) {
        $target = Join-Path $targetDir $name
        # Respect explicit deletions by the selected account.
        $tombstone = Join-Path $targetDir ('deleted_' + $name.Substring(6,$name.Length-11))
        if ([IO.File]::Exists($tombstone)) { continue }
        if ((Read-OptionalText $target) -cne $best[$name].Raw) { New-FileChange $target $best[$name].Raw }
    }
}
function Save-SwitcherAccount {
    param($Context,[string]$Name,[string]$OrganizationId)
    Assert-Name $Name
    Invoke-LockedOperation $Context {
        $snapshot = Get-AccountSnapshot $Context $Name $OrganizationId
        $vault = Read-Vault $Context
        $existing = @($vault.Accounts | Where-Object Name -eq $Name)
        if ($existing.Count -and ($existing[0].AccountId -ne $snapshot.AccountId -or $existing[0].OrganizationId -ne $snapshot.OrganizationId)) { throw 'That label belongs to a different Desktop account. Choose a new label.' }
        $vault.Accounts = @($vault.Accounts | Where-Object Name -ne $Name) + @($snapshot)
        Save-Vault $Context $vault
    }
}
function Switch-ClaudeAccount {
    param($Context,[string]$Name,[switch]$SessionsOnly)
    Assert-Name $Name
    Invoke-LockedOperation $Context {
        if ([IO.File]::Exists($Context.LoginPath)) { throw 'Finish or cancel the pending account registration first (FinishLogin or CancelLogin).' }
        $vault = Read-Vault $Context
        $target = @($vault.Accounts | Where-Object Name -eq $Name)
        if ($target.Count -ne 1) { throw "No saved Desktop account named '$Name'." }
        if ($target[0].CookieKeyHash -cne (Get-CookieKeyHash $Context)) { throw 'Desktop cookie encryption key changed. Sign in and save this account again; the original Local State is never overwritten.' }
        $status = Get-SwitcherStatus $Context
        if (-not $status.Active) { throw 'Save the current Desktop login before switching; it must not be lost.' }
        if ($SessionsOnly -and $status.Active -ne $Name) { throw 'SyncSessions requires the currently signed-in saved account.' }
        $current = Get-AccountSnapshot $Context $status.Active
        $vault.Accounts = @($vault.Accounts | Where-Object Name -ne $status.Active) + @($current)
        $target = @($vault.Accounts | Where-Object Name -eq $Name)[0]
        $files = @()
        $cookies = $current.Cookies
        if (-not $SessionsOnly) { $files += @(Get-AuthFileChanges $Context $target); $cookies = $target.Cookies }
        $files += @(Get-SessionChanges $Context $target)
        $files += New-FileChange $Context.VaultPath (Protect-Data $vault)
        Invoke-DesktopTransaction $Context $cookies $files
    }
}
function Start-SwitcherLogin {
    param($Context,[string]$Name)
    Assert-Name $Name
    Invoke-LockedOperation $Context {
        if ([IO.File]::Exists($Context.LoginPath)) { throw 'There is already a pending login. FinishLogin or CancelLogin first.' }
        $vault = Read-Vault $Context
        if (@($vault.Accounts | Where-Object Name -eq $Name).Count) { throw 'That label already exists. Use another label.' }
        $current = $null
        $cookies = @(Get-AuthCookies $Context)
        if ($cookies.Count) {
            $status = Get-SwitcherStatus $Context
            if (-not $status.Active) { throw 'Save your current Desktop account under a label before adding another account.' }
            $current = Get-AccountSnapshot $Context $status.Active
            $vault.Accounts = @($vault.Accounts | Where-Object Name -ne $status.Active) + @($current)
        }
        $empty = [pscustomobject]@{ AuthFields=@(); OAuthAccount=$null }
        $files = @(Get-AuthFileChanges $Context $empty)
        $pending = [pscustomobject]@{ Name=$Name; Previous=$current; DataDirectory=$Context.DataDirectory }
        $files += New-FileChange $Context.LoginPath (Protect-Data $pending)
        $files += New-FileChange $Context.VaultPath (Protect-Data $vault)
        # Clear only local login state. Never call logout: Desktop logout revokes the saved web session.
        Invoke-DesktopTransaction $Context @() $files
    }
}
function Complete-SwitcherLogin {
    param($Context,[string]$OrganizationId)
    Invoke-LockedOperation $Context {
        if (-not [IO.File]::Exists($Context.LoginPath)) { throw 'No account registration is pending.' }
        $pending = Read-ProtectedData $Context.LoginPath
        if ($pending.DataDirectory -ne $Context.DataDirectory) { throw 'Pending login belongs to another Desktop profile.' }
        $snapshot = Get-AccountSnapshot $Context $pending.Name $OrganizationId
        if ($pending.Previous -and $pending.Previous.AccountId -eq $snapshot.AccountId -and $pending.Previous.OrganizationId -eq $snapshot.OrganizationId) { throw 'You signed back into the original account. Choose the intended account, or CancelLogin.' }
        $vault = Read-Vault $Context
        $vault.Accounts = @($vault.Accounts | Where-Object Name -ne $snapshot.Name) + @($snapshot)
        $files = @(Get-SessionChanges $Context $snapshot)
        $files += New-FileChange $Context.VaultPath (Protect-Data $vault)
        $files += New-FileChange $Context.LoginPath $null
        Invoke-DesktopTransaction $Context $snapshot.Cookies $files
    }
}
function Undo-SwitcherLogin {
    param($Context)
    Invoke-LockedOperation $Context {
        if (-not [IO.File]::Exists($Context.LoginPath)) { throw 'No account registration is pending.' }
        $pending = Read-ProtectedData $Context.LoginPath
        if ($pending.DataDirectory -ne $Context.DataDirectory) { throw 'Pending login belongs to another Desktop profile.' }
        $snapshot = $pending.Previous
        if ($snapshot) {
            if ($snapshot.CookieKeyHash -cne (Get-CookieKeyHash $Context)) { throw 'Cookie encryption key changed; original saved login cannot be restored to this profile.' }
        } else { $snapshot = [pscustomobject]@{ AuthFields=@(); OAuthAccount=$null; Cookies=@() } }
        $files = @(Get-AuthFileChanges $Context $snapshot)
        $files += New-FileChange $Context.LoginPath $null
        Invoke-DesktopTransaction $Context $snapshot.Cookies $files
    }
}
function Remove-SwitcherAccount {
    param($Context,[string]$Name)
    Invoke-LockedOperation $Context {
        if ([IO.File]::Exists($Context.LoginPath)) { throw 'Finish or cancel pending registration before removing accounts.' }
        $vault = Read-Vault $Context
        if (-not @($vault.Accounts | Where-Object Name -eq $Name).Count) { throw "No saved account named '$Name'." }
        $vault.Accounts = @($vault.Accounts | Where-Object Name -ne $Name)
        Save-Vault $Context $vault
    }
}
Export-ModuleMember -Function New-SwitcherContext,Get-SwitcherStatus,Save-SwitcherAccount,Switch-ClaudeAccount,Start-SwitcherLogin,Complete-SwitcherLogin,Undo-SwitcherLogin,Remove-SwitcherAccount
