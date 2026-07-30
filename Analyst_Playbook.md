# DFIR Junior Analyst Playbook

This playbook provides a checklist of commands and locations used to manually gather forensic artifacts, mirroring the automated collection performed by the Flash Forensics scripts.

## Table of Contents
- [Windows Commands](#windows-commands)
  - [System Information](#system-information)
  - [Processes](#processes)
  - [Services](#services)
  - [Scheduled Tasks](#scheduled-tasks)
  - [Network Connections](#network-connections)
  - [Local Users and Privileged Access](#local-users-and-privileged-access)
  - [System Persistence](#system-persistence)
  - [Startup Files](#startup-files)
  - [Execution Evidence](#execution-evidence)
  - [USB History](#usb-history)
  - [Installed Software](#installed-software)
  - [Firewall Rules](#firewall-rules)
  - [Event Logs](#event-logs)
  - [Super Timeline Generation (Plaso)](#super-timeline-generation-plaso)
- [Linux Commands](#linux-commands)
  - [System Information](#system-information-1)
  - [Processes](#processes-1)
  - [Services](#services-1)
  - [Scheduled Tasks](#scheduled-tasks-1)
  - [Network Connections](#network-connections-1)
  - [Kernel Modules](#kernel-modules)
  - [Local Users and Privileged Access](#local-users-and-privileged-access-1)
  - [System Persistence and Startup Files](#system-persistence-and-startup-files)
  - [Execution Evidence](#execution-evidence-1)
  - [Installed Software](#installed-software-1)
  - [Firewall Rules](#firewall-rules-1)
  - [Event Logs](#event-logs-1)

## Windows Commands

### System Information
- **Goal**: Gather basic system information including OS version, hostname, and uptime.
- **Description**: Uses WMI to extract OS and Computer System details, and enumerates IPv4 addresses.
- **Commands**:
  - `Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, LastBootUpTime, OSArchitecture`
  - `Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain`
  - `Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -notmatch "Loopback"`

### Processes
- **Goal**: Enumerate currently running processes.
- **Description**: Uses WMI to list running processes and retrieves their file paths and parent process IDs.
- **External Tools**: [Sysinternals Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer) for advanced process tree visualization and malware analysis.
- **Commands**:
  - `Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, Path, CommandLine`

### Services
- **Goal**: Enumerate installed Windows services.
- **Description**: Lists all services, their state, and the executable path.
- **Commands**:
  - `Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId`

### Scheduled Tasks
- **Goal**: Enumerate configured scheduled tasks.
- **Description**: Lists scheduled tasks and their associated actions/commands.
- **Commands**:
  - `Get-ScheduledTask | Select-Object TaskName, TaskPath, State, Author`
  - `(Get-ScheduledTask).Actions`

### Network Connections
- **Goal**: Enumerate active network connections.
- **Description**: Lists listening and established TCP and UDP endpoints, mapping them to process IDs.
- **External Tools**: [Sysinternals TCPView](https://learn.microsoft.com/en-us/sysinternals/downloads/tcpview) for a live GUI view of all network endpoints and their owning processes.
- **Commands**:
  - `Get-NetTCPConnection | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess`
  - `Get-NetUDPEndpoint | Select-Object LocalAddress, LocalPort, OwningProcess`

### Local Users and Privileged Access
- **Goal**: Enumerate local user accounts and administrative group members.
- **Description**: Lists all local users and the members of the Administrators and Remote Desktop Users groups.
- **Commands**:
  - `Get-LocalUser | Select-Object Name, Enabled, Description, LastLogon`
  - `Get-LocalGroupMember -Group "Administrators"`
  - `Get-LocalGroupMember -Group "Remote Desktop Users"`

### System Persistence
- **Goal**: Identify common registry-based persistence mechanisms.
- **Description**: Checks standard Run, RunOnce, BootExecute keys and enumerates BITS transfer jobs.
- **External Tools**: [Sysinternals Autoruns](https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns) is the gold standard for comprehensively identifying persistence mechanisms across the entire OS (Registry, Services, Scheduled Tasks, WMI, etc).
  - *Example*: `autorunsc.exe -a * -c -h -m -v > autoruns_output.csv` (Exports all locations to CSV with VirusTotal hashes)
- **Commands**:
  - `Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"`
  - `Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"`
  - `Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "BootExecute"`
  - `Get-BitsTransfer -AllUsers`

### Startup Files
- **Goal**: Enumerate files in startup folders.
- **Description**: Lists executables and scripts configured to run on user login.
- **Commands**:
  - `Get-ChildItem -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\*" -File -Force`
  - `Get-ChildItem -Path "C:\Users\*\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\*" -File -Force`

### Execution Evidence
- **Goal**: Identify evidence of recent program execution.
- **Description**: Collects Windows Prefetch files and the PowerShell command history file.
- **External Tools**: 
  - [Eric Zimmerman's PECmd](https://ericzimmerman.github.io/#!index.md) to deeply parse and extract execution timestamps from `.pf` Prefetch files.
    - *Example*: `PECmd.exe -d "C:\Windows\Prefetch" --csv "C:\temp" --csvf prefetch_output.csv`
  - [Eric Zimmerman's JLECmd](https://ericzimmerman.github.io/#!index.md) to parse Jump Lists for file access evidence.
    - *Example*: `JLECmd.exe -d "C:\Users\<User>\AppData\Roaming\Microsoft\Windows\Recent" --csv "C:\temp" --csvf jumplists_output.csv`
- **Commands**:
  - `Get-ChildItem -Path "C:\Windows\Prefetch\*.pf" -File`
  - `Get-Content (Get-PSReadLineOption).HistorySavePath`

### USB History
- **Goal**: Enumerate historically connected USB devices.
- **Description**: Queries the USBSTOR registry key to identify previously connected thumb drives.
- **Commands**:
  - `Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR" | Get-ChildItem | Get-ItemProperty`

### Installed Software
- **Goal**: Enumerate installed applications.
- **Description**: Queries Uninstall registry keys across HKLM and HKCU for installed programs.
- **Commands**:
  - `Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"`
  - `Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"`
  - `Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"`

### Firewall Rules
- **Goal**: Enumerate active Windows Firewall rules.
- **Description**: Extracts enabled inbound and outbound firewall rules.
- **Commands**:
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallAddressFilter`
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallPortFilter`
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallApplicationFilter`

### Event Logs
- **Goal**: Extract key security and operational event logs.
- **Description**: Queries critical Event IDs (Logons, Process Creation, Services, Tasks) from the System, Security, and Microsoft-Windows-TerminalServices logs.
- **External Tools**: [Eric Zimmerman's EvtxECmd](https://ericzimmerman.github.io/#!index.md) to bulk-parse raw `.evtx` files and output normalized CSV timelines of critical OS events.
  - *Example*: `EvtxECmd.exe -d "C:\Windows\System32\winevt\Logs" --csv "C:\temp" --csvf eventlogs_timeline.csv`
- **Commands**:
  - `Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624, 4625, 4688}`
  - `Get-WinEvent -FilterHashtable @{LogName='System'; Id=7045}`

### Super Timeline Generation (Plaso)
- **Goal**: Create an integrated, chronological super-timeline of all system activity.
- **Description**: After gathering raw artifacts (Prefetch, Event Logs, Registry Hives, MFT, etc.), you can ingest them into [Plaso (log2timeline)](https://plaso.readthedocs.io/en/latest/) to correlate events across different sources into a single unified timeline.
- **External Tools**: 
  - Plaso suite (`log2timeline.py` for extraction, `psort.py` for filtering and CSV generation).
  - [Eric Zimmerman's Timeline Explorer](https://ericzimmerman.github.io/#!index.md) is the industry standard GUI for viewing, filtering, and color-coding large CSV timelines generated by Plaso.
- **Commands**:
  - *Extract artifacts into a Plaso storage file*:
    `log2timeline.py --parsers "winreg,winevtx,prefetch,pe" system_timeline.plaso "C:\Path\To\Extracted\Artifacts"`
  - *Filter and output to a chronological CSV (e.g., filtering for a specific date range)*:
    `psort.py -o l2tcsv -w timeline_output.csv "date > '2023-01-01 00:00:00' AND date < '2023-12-31 23:59:59'" system_timeline.plaso`

---

## Linux Commands

### System Information
- **Goal**: Gather basic system information including OS version, kernel, and uptime.
- **Description**: Reads OS release files, uname, and uptime utilities.
- **Commands**:
  - `uname -a`
  - `cat /etc/os-release | grep PRETTY_NAME`
  - `uptime -p`
  - `ip -4 addr show`

### Processes
- **Goal**: Enumerate currently running processes.
- **Description**: Uses `ps` to list running processes with parent IDs and start times.
- **Commands**:
  - `ps -eo pid,ppid,user,start_time,command`

### Services
- **Goal**: Enumerate installed systemd services.
- **Description**: Lists all services and their active states using systemctl or service.
- **Commands**:
  - `systemctl list-units --type=service --all --no-pager --no-legend`
  - `service --status-all`

### Scheduled Tasks
- **Goal**: Enumerate configured cron jobs and systemd timers.
- **Description**: Reads user crontabs, system crontabs, and systemd timers.
- **Commands**:
  - `cat /etc/crontab /etc/cron.d/*`
  - `for u in $(cat /etc/passwd | cut -d: -f1); do crontab -u $u -l; done`
  - `systemctl list-timers --all --no-pager --no-legend`

### Network Connections
- **Goal**: Enumerate active network connections.
- **Description**: Lists listening and established TCP and UDP endpoints using `ss` or `netstat`.
- **Commands**:
  - `ss -tupan`
  - `netstat -tupan`

### Kernel Modules
- **Goal**: Enumerate loaded kernel modules.
- **Description**: Lists actively loaded kernel modules using `lsmod`.
- **Commands**:
  - `lsmod`

### Local Users and Privileged Access
- **Goal**: Enumerate local user accounts and users with sudo privileges.
- **Description**: Parses `/etc/passwd` for users and checks `/etc/sudoers` and `wheel/sudo` groups.
- **Commands**:
  - `cat /etc/passwd`
  - `cat /etc/sudoers | grep -v '^#'`
  - `cat /etc/group | grep -E '^(sudo|wheel):'`

### System Persistence and Startup Files
- **Goal**: Identify common persistence mechanisms and startup scripts.
- **Description**: Reads shell profiles, `rc.local`, systemd generators, and init scripts.
- **Commands**:
  - `cat /etc/rc.local ~/.bash_profile ~/.bashrc ~/.profile /etc/profile`
  - `cat ~/.ssh/authorized_keys /root/.ssh/authorized_keys`
  - `ls -la /etc/init.d/ /etc/rc*.d/`

### Execution Evidence
- **Goal**: Identify evidence of recent program execution and commands.
- **Description**: Reads shell history files and sudo execution logs.
- **Commands**:
  - `cat ~/.bash_history ~/.zsh_history`
  - `cat /var/log/auth.log | grep sudo`

### Installed Software
- **Goal**: Enumerate installed packages.
- **Description**: Queries dpkg, rpm, or snap for installed software based on the package manager.
- **Commands**:
  - `dpkg-query -W -f='${binary:Package}|${Version}|${Maintainer}\n'`
  - `rpm -qa --qf '%{NAME}|%{VERSION}|%{VENDOR}\n'`
  - `snap list`

### Firewall Rules
- **Goal**: Enumerate active firewall rules.
- **Description**: Extracts configuration from ufw, firewalld, or raw iptables.
- **Commands**:
  - `ufw status numbered`
  - `firewall-cmd --list-all`
  - `iptables -S`

### Event Logs
- **Goal**: Extract key authentication and system event logs.
- **Description**: Reads the tail of common syslog and authentication logs.
- **Commands**:
  - `tail -n 500 /var/log/auth.log /var/log/secure`
  - `tail -n 500 /var/log/syslog /var/log/messages`
