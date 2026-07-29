[CmdletBinding()]
param(
    [int[]]$AdditionalEventCodes = @()
)

<#
.SYNOPSIS
    Gathers DFIR artifacts from a Windows system.
.DESCRIPTION
    This script is designed to be executed remotely via Invoke-Command. It collects processes, services, scheduled tasks, network connections, local users, and common registry persistence mechanisms.
.OUTPUTS
    PSCustomObject containing the collected datasets.
#>

$Results = @{
    Processes = @()
    Services = @()
    ScheduledTasks = @()
    NetworkConnections = @()
    LocalUsers = @()
    SystemPersistence = @()
    StartupFiles = @()
    EventLogs = @()
    SystemInfo = @()
    ExecutionEvidence = @()
    PrivilegedAccess = @()
    USBHistory = @()
    InstalledSoftware = @()
    FirewallRules = @()
    RDPConnections = @()
    ComputerName = $env:COMPUTERNAME
    Timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
}

try {
    # 0. System Info
    $OS_Cim = Get-CimInstance Win32_OperatingSystem
    $Comp_Cim = Get-CimInstance Win32_ComputerSystem
    $Results.SystemInfo += [PSCustomObject]@{ Property = "OS Version"; Value = "$($OS_Cim.Caption) ($($OS_Cim.Version))" }
    $Results.SystemInfo += [PSCustomObject]@{ Property = "Architecture"; Value = $OS_Cim.OSArchitecture }
    $Results.SystemInfo += [PSCustomObject]@{ Property = "Domain"; Value = $Comp_Cim.Domain }
    $Uptime_Ts = (Get-Date) - $OS_Cim.LastBootUpTime
    $Results.SystemInfo += [PSCustomObject]@{ Property = "Uptime"; Value = "$($Uptime_Ts.Days) days, $($Uptime_Ts.Hours) hours, $($Uptime_Ts.Minutes) minutes" }
    $IPv4s = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object InterfaceAlias -notmatch "Loopback").IPAddress -join ", "
    if ($IPv4s) { $Results.SystemInfo += [PSCustomObject]@{ Property = "IP Addresses (IPv4)"; Value = $IPv4s } }

    # 1. Processes
    $Procs = Get-CimInstance Win32_Process
    $ProcessDetails = @()
    foreach ($P in $Procs) {
        $Hash = ""
        $Sign = ""
        if ($P.Path -and (Test-Path $P.Path)) {
            try { $Hash = (Get-FileHash -Path $P.Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } catch { }
            try { 
                $Sig = Get-AuthenticodeSignature -FilePath $P.Path -ErrorAction SilentlyContinue
                if ($Sig.Status -eq "Valid") { $Sign = $Sig.SignerCertificate.Subject }
                else { $Sign = "Invalid/NotSigned" }
            } catch { }
        }
        $ProcessDetails += [PSCustomObject]@{
            ProcessId = $P.ProcessId
            Name = $P.Name
            Path = $P.Path
            CommandLine = $P.CommandLine
            ParentProcessId = $P.ParentProcessId
            CreationDate = $P.CreationDate
            SHA256 = $Hash
            Signer = $Sign
        }
    }
    $Results.Processes = $ProcessDetails
} catch {
    Write-Warning "Failed to collect Processes: $_"
}

try {
    # 2. Services
    $Results.Services = Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId
} catch {
    Write-Warning "Failed to collect Services: $_"
}

try {
    # 3. Scheduled Tasks
    $Tasks = Get-ScheduledTask
    $TaskDetails = @()
    foreach ($Task in $Tasks) {
        $Info = Get-ScheduledTaskInfo -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction SilentlyContinue
        $TaskDetails += [PSCustomObject]@{
            TaskName = $Task.TaskName
            TaskPath = $Task.TaskPath
            State = $Task.State
            Author = $Task.Author
            Command = ($Task.Actions | Where-Object { $_.Execute } | Select-Object -ExpandProperty Execute) -join ";"
            Arguments = ($Task.Actions | Where-Object { $_.Arguments } | Select-Object -ExpandProperty Arguments) -join ";"
            LastRunTime = $Info.LastRunTime
            NextRunTime = $Info.NextRunTime
        }
    }
    $Results.ScheduledTasks = $TaskDetails
} catch {
    Write-Warning "Failed to collect Scheduled Tasks: $_"
}

try {
    # 4. Network Connections (Listening and Established)
    $TCP = Get-NetTCPConnection -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess, @{Name="Protocol";Expression={"TCP"}}
    $UDP = Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, @{Name="RemoteAddress";Expression={""}}, @{Name="RemotePort";Expression={""}}, @{Name="State";Expression={"Listening"}}, OwningProcess, @{Name="Protocol";Expression={"UDP"}}
    
    $NetConns = @()
    if ($TCP) { $NetConns += $TCP }
    if ($UDP) { $NetConns += $UDP }
    
    # Map to process name and path
    $MappedConns = @()
    foreach ($Conn in $NetConns) {
        $Proc = $Results.Processes | Where-Object { $_.ProcessId -eq $Conn.OwningProcess }
        $Conn | Add-Member -MemberType NoteProperty -Name ProcessName -Value ($Proc.Name) -PassThru -ErrorAction SilentlyContinue | Out-Null
        $Conn | Add-Member -MemberType NoteProperty -Name ProcessPath -Value ($Proc.Path) -PassThru -ErrorAction SilentlyContinue | Out-Null
        $MappedConns += $Conn
    }
    $Results.NetworkConnections = $MappedConns
} catch {
    Write-Warning "Failed to collect Network Connections: $_"
}

try {
    # 5. Local Users and Groups
    $Users = Get-LocalUser -ErrorAction SilentlyContinue | Select-Object Name, Enabled, Description, LastLogon
    $Results.LocalUsers = $Users
} catch {
    Write-Warning "Failed to collect Local Users: $_"
}

try {
    # 6. Registry Persistence
    $RegPersist = @()

    function Get-RegPersistence {
        param (
            [string]$KeyPath
        )
        $output = @()
        $Item = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue
        if ($Item) {
            $found = $false
            foreach ($Prop in $Item.psobject.properties) {
                if ($Prop.Name -notin @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) {
                    $output += [PSCustomObject]@{ Key=$KeyPath; ValueName=$Prop.Name; Data=$Prop.Value; Source="Registry" }
                    $found = $true
                }
            }
            if (-not $found) {
                $output += [PSCustomObject]@{ Key=$KeyPath; ValueName="null/empty"; Data="null/empty"; Source="Registry" }
            }
        } else {
            $output += [PSCustomObject]@{ Key=$KeyPath; ValueName="null/empty"; Data="null/empty"; Source="Registry" }
        }
        return $output
    }

    function Get-RegValuePersistence {
        param (
            [string]$KeyPath,
            [string]$ValueName
        )
        $Item = Get-ItemProperty -Path $KeyPath -Name $ValueName -ErrorAction SilentlyContinue
        if ($Item -and $null -ne $Item.psobject.properties[$ValueName]) {
            $val = $Item.$ValueName
            if ($val -is [array]) {
                $val = $val -join " "
            }
            if ([string]::IsNullOrWhiteSpace([string]$val)) {
                $val = "null/empty"
            }
            return [PSCustomObject]@{ Key=$KeyPath; ValueName=$ValueName; Data=$val; Source="Registry" }
        } else {
            return [PSCustomObject]@{ Key=$KeyPath; ValueName=$ValueName; Data="null/empty"; Source="Registry" }
        }
    }
    
    $KeysToCheck = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    # Ensure HKU drive is available
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
    }

    # Gather HKU SIDs for currently loaded user hives (excluding defaults and classes)
    $HKU_SIDs = Get-ChildItem -Path "HKU:\" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'S-1-5-21-[\d\-]+$' }
    foreach ($SID in $HKU_SIDs) {
        $KeysToCheck += "HKU:\$($SID.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Run"
        $KeysToCheck += "HKU:\$($SID.PSChildName)\Software\Microsoft\Windows\CurrentVersion\RunOnce"
    }

    # Process all identified keys
    foreach ($Key in $KeysToCheck) {
        $RegPersist += Get-RegPersistence -KeyPath $Key
    }

    # Add specific values
    $RegPersist += Get-RegValuePersistence -KeyPath "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -ValueName "Shell"
    $RegPersist += Get-RegValuePersistence -KeyPath "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -ValueName "Userinit"
    $RegPersist += Get-RegValuePersistence -KeyPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ValueName "BootExecute"

    # Attempt to load unloaded NTUSER.DAT hives
    $UserDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($Dir in $UserDirs) {
        $NTUserPath = Join-Path $Dir.FullName "NTUSER.DAT"
        if (Test-Path $NTUserPath) {
            $TempKeyName = "TEMP_$($Dir.Name)"
            $TempKeyPath = "HKU\$TempKeyName"
            
            # Load hive
            $LoadProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c reg.exe load `"$TempKeyPath`" `"$NTUserPath`" >NUL 2>NUL" -Wait -NoNewWindow -PassThru
            if ($LoadProc.ExitCode -eq 0) {
                $RegPersist += Get-RegPersistence -KeyPath "HKU:\$TempKeyName\Software\Microsoft\Windows\CurrentVersion\Run"
                $RegPersist += Get-RegPersistence -KeyPath "HKU:\$TempKeyName\Software\Microsoft\Windows\CurrentVersion\RunOnce"
                
                # Clean up to release file handle
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                
                # Unload hive
                Start-Process -FilePath "cmd.exe" -ArgumentList "/c reg.exe unload `"$TempKeyPath`" >NUL 2>NUL" -Wait -NoNewWindow | Out-Null
            }
        }
    }

    try {
        $BitsJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue
        foreach ($Job in $BitsJobs) {
            $RegPersist += [PSCustomObject]@{
                Key = "BITS Job"
                ValueName = $Job.DisplayName
                Data = "Owner: $($Job.OwnerAccount) | State: $($Job.JobState) | Source: $($Job.Source) | Dest: $($Job.Destination)"
                Source = "BITS Transfer"
            }
        }
    } catch { }

        $ProfilePaths = @(
            "$env:windir\System32\WindowsPowerShell\v1.0\profile.ps1",
            "$env:windir\System32\WindowsPowerShell\v1.0\Microsoft.PowerShell_profile.ps1",
            "$env:windir\System32\WindowsPowerShell\v1.0\Microsoft.PowerShellISE_profile.ps1"
        )
        try {
            Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $ProfilePaths += "$($_.FullName)\Documents\WindowsPowerShell\profile.ps1"
                $ProfilePaths += "$($_.FullName)\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
                $ProfilePaths += "$($_.FullName)\Documents\WindowsPowerShell\Microsoft.PowerShellISE_profile.ps1"
                $ProfilePaths += "$($_.FullName)\Documents\PowerShell\profile.ps1"
                $ProfilePaths += "$($_.FullName)\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
            }
        } catch {}

        foreach ($Path in $ProfilePaths) {
            if (Test-Path $Path) {
                try {
                    $Content = Get-Content $Path -Raw -ErrorAction SilentlyContinue | Out-String
                    $RegPersist += [PSCustomObject]@{
                        Key = "PowerShell Profile"
                        ValueName = Split-Path $Path -Leaf
                        Data = $Content
                        Source = "PowerShell Profiles"
                    }
                } catch {}
            }
        }

    $Results.SystemPersistence = $RegPersist

} catch {
    Write-Warning "Failed to collect System Persistence: $_"
}

try {
    # 7. Startup Files
    $StartupFiles = @()
    $StartupPaths = @(
        "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\*",
        "C:\Users\*\Start Menu\Programs\Startup\*",
        "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*"
    )
    
    foreach ($Path in $StartupPaths) {
        $Files = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue
        foreach ($File in $Files) {
            $Hash = ""
            $Sign = ""
            try { $Hash = (Get-FileHash -Path $File.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } catch { }
            try { 
                $Sig = Get-AuthenticodeSignature -FilePath $File.FullName -ErrorAction SilentlyContinue
                if ($Sig.Status -eq "Valid") { $Sign = $Sig.SignerCertificate.Subject }
                else { $Sign = "Invalid/NotSigned" }
            } catch { }
            
            $StartupFiles += [PSCustomObject]@{
                Path = $File.FullName
                CreationTime = $File.CreationTime
                LastWriteTime = $File.LastWriteTime
                Length = $File.Length
                SHA256 = $Hash
                Signer = $Sign
            }
        }
    }
    
    $Results.StartupFiles = $StartupFiles
} catch {
    Write-Warning "Failed to collect Startup Files: $_"
}

try {
    # 8. Event Logs (High Value: Logons, Process Creation, Services, PowerShell, Tasks, Users)
    $TargetIds = @(4103, 4104, 4624, 4625, 4672, 4688, 4697, 4698, 4702, 4720, 4722, 4738, 7045)
    if ($AdditionalEventCodes) {
        $TargetIds += $AdditionalEventCodes
    }
    $Events = Get-WinEvent -FilterHashtable @{LogName='Security','System','Microsoft-Windows-PowerShell/Operational'; Id=$TargetIds} -MaxEvents 300 -ErrorAction SilentlyContinue
    $ParsedEvents = @()
    foreach ($E in $Events) {
        $BaseProps = [ordered]@{
            EventTime = $E.TimeCreated
            EventId   = $E.Id
            Provider  = $E.ProviderName
        }

        try {
            $xml = [xml]$E.ToXml()
            $EventData = @{}
            
            # Map EventData (System and Security logs)
            if ($xml.Event.EventData.Data) {
                foreach ($node in $xml.Event.EventData.Data) {
                    $EventData[$node.Name] = $node.'#text'
                }
            }
            # Map UserData (Some Operational logs)
            elseif ($xml.Event.UserData.EventXML) {
                foreach ($node in $xml.Event.UserData.EventXML.ChildNodes) {
                    $EventData[$node.Name] = $node.InnerText
                }
            }

            switch ($E.Id) {
                { $_ -in 4624, 4625 } {
                    $BaseProps.TargetUserName = $EventData['TargetUserName']
                    $BaseProps.LogonType = $EventData['LogonType']
                    $BaseProps.IpAddress = $EventData['IpAddress']
                    if ($E.Id -eq 4625) { $BaseProps.SubStatus = $EventData['SubStatus'] }
                    $BaseProps.Details = "Target: $($BaseProps.TargetUserName) | LogonType: $($BaseProps.LogonType) | IP: $($BaseProps.IpAddress)"
                }
                4688 {
                    $BaseProps.NewProcessName = $EventData['NewProcessName']
                    $BaseProps.ParentProcessName = $EventData['ParentProcessName']
                    $BaseProps.CommandLine = $EventData['CommandLine']
                    $BaseProps.SubjectUserName = $EventData['SubjectUserName']
                    $BaseProps.Details = "Process: $($BaseProps.NewProcessName) | CmdLine: $($BaseProps.CommandLine) | Parent: $($BaseProps.ParentProcessName)"
                }
                { $_ -in 4697, 7045 } {
                    $BaseProps.ServiceName = $EventData['ServiceName']
                    $BaseProps.ServiceFileName = if ($EventData['ServiceFileName']) { $EventData['ServiceFileName'] } else { $EventData['ImagePath'] }
                    $BaseProps.ServiceAccount = if ($EventData['ServiceAccount']) { $EventData['ServiceAccount'] } else { $EventData['AccountName'] }
                    $BaseProps.Details = "Service: $($BaseProps.ServiceName) | File: $($BaseProps.ServiceFileName) | Account: $($BaseProps.ServiceAccount)"
                }
                { $_ -in 4103, 4104 } {
                    $BaseProps.ScriptBlockText = if ($EventData['ScriptBlockText']) { $EventData['ScriptBlockText'] } else { $EventData['Payload'] }
                    $BaseProps.Path = $EventData['Path']
                    $BaseProps.ContextInfo = $EventData['ContextInfo']
                    $BaseProps.Details = "Path: $($BaseProps.Path) | Content: $($BaseProps.ScriptBlockText)"
                }
                { $_ -in 4698, 4702 } {
                    $BaseProps.TaskName = $EventData['TaskName']
                    $BaseProps.Details = "Task: $($BaseProps.TaskName)"
                }
                { $_ -in 4720, 4722, 4738, 4672 } {
                    $BaseProps.TargetUserName = $EventData['TargetUserName']
                    $BaseProps.SubjectUserName = $EventData['SubjectUserName']
                    $BaseProps.Details = "TargetUser: $($BaseProps.TargetUserName) | SubjectUser: $($BaseProps.SubjectUserName)"
                }
                default {
                    $BaseProps.Message = $E.Message -replace '\s+', ' '
                    $BaseProps.Details = $BaseProps.Message
                }
            }
        } catch {
            $BaseProps.Message = $E.Message -replace '\s+', ' '
            $BaseProps.Details = $BaseProps.Message
        }
        
        $ParsedEvents += [PSCustomObject]$BaseProps
    }
    $Results.EventLogs = $ParsedEvents
} catch {
    Write-Warning "Failed to collect Event Logs: $_"
}

try {
    # 9. Execution Evidence (Prefetch)
    $Prefetch = @()
    $PrefetchFiles = Get-ChildItem -Path "$env:windir\Prefetch\*.pf" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 200
    foreach ($PF in $PrefetchFiles) {
        $Prefetch += [PSCustomObject]@{
            Executable = $PF.Name -replace "-[A-F0-9]+\.pf$",""
            FileName = $PF.Name
            CreationTime = $PF.CreationTime
            LastWriteTime = $PF.LastWriteTime
            Length = $PF.Length
            RunCount = 1
            Source = "Windows Prefetch"
        }
    }
    $Results.ExecutionEvidence = $Prefetch
    
    # PowerShell History
    $UserDirs = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($User in $UserDirs) {
        $HistPath = "$($User.FullName)\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
        if (Test-Path $HistPath) {
            $HistTime = (Get-Item $HistPath).LastWriteTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
            try {
                $Commands = Get-Content $HistPath -ErrorAction SilentlyContinue
                if ($Commands) {
                    $Commands = [array]$Commands
                    [array]::Reverse($Commands)
                    foreach ($Cmd in $Commands) {
                        if (![string]::IsNullOrWhiteSpace($Cmd)) {
                            $Results.ExecutionEvidence += [PSCustomObject]@{
                                Executable = $Cmd.Trim()
                                FileName = $HistPath
                                CreationTime = $null
                                LastWriteTime = $HistTime
                                Length = $null
                                RunCount = 1
                                Source = "PowerShell History"
                            }
                        }
                    }
                }
            } catch { }
        }
    }
} catch {
    Write-Warning "Failed to collect Execution Evidence: $_"
}

try {
    # 10. Privileged Access
    $PrivAccess = @()
    $Groups = @("Administrators", "Remote Desktop Users")
    foreach ($Group in $Groups) {
        try {
            $Members = Get-LocalGroupMember -Group $Group -ErrorAction SilentlyContinue
            foreach ($Mem in $Members) {
                $PrivAccess += [PSCustomObject]@{
                    Group = $Group
                    Name = $Mem.Name
                    ObjectClass = $Mem.ObjectClass
                    PrincipalSource = $Mem.PrincipalSource
                }
            }
        } catch { }
    }
    $Results.PrivilegedAccess = $PrivAccess
} catch {
    Write-Warning "Failed to collect Privileged Access: $_"
}

try {
    # 11. USB History
    $USBHistory = @()
    $USBKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR"
    if (Test-Path $USBKey) {
        $Devices = Get-ChildItem -Path $USBKey -ErrorAction SilentlyContinue
        foreach ($Dev in $Devices) {
            $SubKeys = Get-ChildItem -Path $Dev.PSPath -ErrorAction SilentlyContinue
            foreach ($Sub in $SubKeys) {
                $Props = Get-ItemProperty -Path $Sub.PSPath -ErrorAction SilentlyContinue
                $USBHistory += [PSCustomObject]@{
                    DeviceName = $Props.FriendlyName
                    DeviceID = $Sub.PSChildName
                    HardwareID = ($Props.HardwareID -join ", ")
                    Mfg = $Props.Mfg
                }
            }
        }
    }
    $Results.USBHistory = $USBHistory
} catch { Write-Warning "Failed to collect USB History: $_" }

try {
    # 12. Installed Software
    $Software = @()
    $RegPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($Path in $RegPaths) {
        $Items = Get-ItemProperty $Path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
        foreach ($Item in $Items) {
            $Software += [PSCustomObject]@{
                DisplayName = $Item.DisplayName
                DisplayVersion = $Item.DisplayVersion
                Publisher = $Item.Publisher
                InstallDate = $Item.InstallDate
                InstallLocation = $Item.InstallLocation
            }
        }
    }
    $Results.InstalledSoftware = $Software
} catch { Write-Warning "Failed to collect Installed Software: $_" }

try {
    # 13. Firewall Rules
    $Results.FirewallRules = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' } | Select-Object DisplayName, @{Name='Profile';Expression={$_.Profile.ToString()}}, @{Name='Direction';Expression={$_.Direction.ToString()}}, @{Name='Action';Expression={$_.Action.ToString()}}
} catch { Write-Warning "Failed to collect Firewall Rules: $_" }

try {
    # 14. RDP Connections
    $RDPData = @()
    
    # INBOUND RDP (LocalSessionManager)
    $InboundEvents = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id=21, 24, 25} -MaxEvents 50 -ErrorAction SilentlyContinue
    foreach ($E in $InboundEvents) {
        $xml = [xml]$E.ToXml()
        $EventData = @{}
        if ($xml.Event.UserData.EventXML) {
            foreach ($node in $xml.Event.UserData.EventXML.ChildNodes) {
                $EventData[$node.Name] = $node.InnerText
            }
        }
        $Address = if ($EventData['Address']) { $EventData['Address'] } elseif ($EventData['ClientAddress']) { $EventData['ClientAddress'] } else { $EventData['SourceNetworkAddress'] }
        $RDPData += [PSCustomObject]@{
            TimeCreated = $E.TimeCreated
            Type = "Inbound"
            User = $EventData['User']
            SourceIP = $Address
            Destination = "Local System"
            Source = "Event $($E.Id)"
        }
    }

    # OUTBOUND RDP (Event Logs)
    $OutboundEvents = Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RDPClient/Operational'; Id=1024} -MaxEvents 50 -ErrorAction SilentlyContinue
    foreach ($E in $OutboundEvents) {
        $xml = [xml]$E.ToXml()
        $EventData = @{}
        if ($xml.Event.EventData.Data) {
            foreach ($node in $xml.Event.EventData.Data) {
                $EventData[$node.Name] = $node.'#text'
            }
        } elseif ($xml.Event.UserData.EventXML) {
            foreach ($node in $xml.Event.UserData.EventXML.ChildNodes) {
                $EventData[$node.Name] = $node.InnerText
            }
        }
        $Value = if ($EventData['Value']) { $EventData['Value'] } else { "Unknown" }
        
        $Username = "Unknown"
        if ($E.UserId) {
            try { $Username = $E.UserId.Translate([System.Security.Principal.NTAccount]).Value } catch { }
        }
        
        $RDPData += [PSCustomObject]@{
            TimeCreated = $E.TimeCreated
            Type = "Outbound"
            User = $Username
            SourceIP = "Local System"
            Destination = $Value
            Source = "Event $($E.Id)"
        }
    }

    # OUTBOUND RDP (Registry HKU)
    $HKUPaths = Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'S-1-5-21-[\d\-]+$' }
    foreach ($User in $HKUPaths) {
        $ServersPath = "$($User.PSPath)\Software\Microsoft\Terminal Server Client\Servers"
        if (Test-Path $ServersPath) {
            $Servers = Get-ChildItem -Path $ServersPath -ErrorAction SilentlyContinue
            foreach ($Server in $Servers) {
                $Username = (Get-ItemProperty -Path $Server.PSPath -Name UsernameHint -ErrorAction SilentlyContinue).UsernameHint
                $RDPData += [PSCustomObject]@{
                    TimeCreated = ""
                    Type = "Outbound"
                    User = $Username
                    SourceIP = "Local System"
                    Destination = $Server.PSChildName
                    Source = "Registry (Terminal Server Client)"
                }
            }
        }
    }

    $Results.RDPConnections = $RDPData
} catch { Write-Warning "Failed to collect RDP Connections: $_" }

return [PSCustomObject]$Results
