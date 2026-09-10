# Host Analyst Playbook

This playbook provides a checklist of commands and locations used to manually gather forensic artifacts, mirroring the automated collection performed by the Flash Forensics scripts.

Each section includes a **Why / Abuse** note: the analytic reason we collect the artifact and how attackers commonly abuse it, with the relevant [MITRE ATT&CK](https://attack.mitre.org/) technique IDs so findings can be mapped to adversary behavior. Techniques are shown as `Txxxx` / `Txxxx.yyy`.

A recurring theme below is **file trust triage**. Wherever the collector records a file path (Processes, Startup Files, Drivers), it also computes three trust signals:
- **SHA256 hash** - a stable identity for the file that can be checked against threat-intel and known-good baselines (e.g. VirusTotal, NSRL). Two files with the same hash are byte-identical; a hash that shows up on nothing legitimate is worth a look.
- **Authenticode signature** - whether the binary carries a valid embedded code signature and who signed it. `Invalid/NotSigned` on something running from a user-writable path is a classic red flag. Note that many legitimate inbox binaries are **catalog-signed** (`.cat`) rather than embedded-signed, so unsigned is a lead to review, not proof of malice.
- **Mark-of-the-Web (MOTW)** - Windows records where a downloaded file came from in a `Zone.Identifier` alternate data stream. Its presence means the file was downloaded (from the internet or an email/zone), and it often preserves the source URL. Attackers rely on users running downloaded payloads and on **MOTW-bypass** tricks (containers/ISO/7z that strip the mark) to defeat SmartScreen (T1553.005, T1204).

## Table of Contents
- [Windows Commands](#windows-commands)
  - [System Information](#system-information)
  - [File Hashing, Code Signing & Mark-of-the-Web](#file-hashing-code-signing--mark-of-the-web)
  - [Processes](#processes)
  - [Services](#services)
  - [Scheduled Tasks](#scheduled-tasks)
  - [Network Connections & ARP](#network-connections--arp)
  - [Local Users and Privileged Access](#local-users-and-privileged-access)
  - [Active Logged In Users](#active-logged-in-users)
  - [System Persistence](#system-persistence)
  - [Startup Files](#startup-files)
  - [Execution Evidence](#execution-evidence)
  - [Recycle Bin](#recycle-bin)
  - [USB History](#usb-history)
  - [Installed Software](#installed-software)
  - [Firewall Rules](#firewall-rules)
  - [RDP Connections](#rdp-connections)
  - [Docker Containers](#docker-containers)
  - [DNS Cache](#dns-cache)
  - [SMB Sessions](#smb-sessions)
  - [SMB Shares](#smb-shares)
  - [Loaded Kernel Drivers](#loaded-kernel-drivers)
  - [Microsoft Defender Security Posture](#microsoft-defender-security-posture)
  - [Event Logs](#event-logs)
  - [Super Timeline Generation (Plaso)](#super-timeline-generation-plaso)
- [Linux Commands](#linux-commands)
  - [System Information](#system-information-1)
  - [Processes](#processes-1)
  - [Services](#services-1)
  - [Scheduled Tasks](#scheduled-tasks-1)
  - [Network Connections & ARP](#network-connections--arp-1)
  - [Kernel Modules](#kernel-modules)
  - [Local Users and Privileged Access](#local-users-and-privileged-access-1)
  - [Active Logged In Users](#active-logged-in-users-1)
  - [System Persistence and Startup Files](#system-persistence-and-startup-files)
  - [Execution Evidence](#execution-evidence-1)
  - [Recycle Bin](#recycle-bin-1)
  - [Installed Software](#installed-software-1)
  - [Firewall Rules](#firewall-rules-1)
  - [Docker Containers](#docker-containers-1)
  - [DNS Configuration](#dns-configuration)
  - [Event Logs](#event-logs-1)

## Windows Commands

### System Information
- **Goal**: Gather basic system information including OS version, hostname, and uptime.
- **Description**: Uses WMI to extract OS and Computer System details, and enumerates IPv4 addresses.
- **Why / Abuse**: Establishes the ground truth every other artifact is interpreted against - OS build (patch level), domain membership, and the host's own IP(s) so you can tell local from remote in the network data. Uptime bounds the incident: a boot time that lines up with the suspected compromise, or a suspiciously short uptime, can indicate a reboot used to load a driver or clear volatile state.
- **Commands**:
  - `Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, LastBootUpTime, OSArchitecture`
  - `Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain`
  - `Get-NetIPAddress -AddressFamily IPv4 | Where-Object InterfaceAlias -notmatch "Loopback"`

### File Hashing, Code Signing & Mark-of-the-Web
- **Goal**: Attach trust signals (hash, signature, download origin) to every file-backed artifact.
- **Description**: For each unique file path referenced by Processes, Startup Files, and Drivers, the collector records a SHA256 hash, the Authenticode signer (or `Invalid/NotSigned`), and any Mark-of-the-Web download origin. Results are cached per path so repeated binaries (dozens of `svchost.exe`) are only computed once.
- **Why / Abuse**: This is the fastest triage lever on a host. Malware frequently runs unsigned from user-writable paths (`%TEMP%`, `%APPDATA%`, `C:\Users\Public`), masquerades under trusted names (T1036), or is a downloaded payload the user was tricked into executing (T1204). Signature abuse and MOTW-bypass (T1553.005) let adversaries defeat SmartScreen/WDAC trust checks. Hashes let you pivot to threat-intel and separate known-good from unknown in seconds.
- **Commands**:
  - `Get-FileHash -Path <file> -Algorithm SHA256`
  - `Get-AuthenticodeSignature -FilePath <file> | Select-Object Status, SignerCertificate`
  - `Get-Content -Path <file> -Stream Zone.Identifier`   *(the ADS holds `ZoneId`, `HostUrl`, `ReferrerUrl`; absence means no download marker)*
  - *List a file's alternate data streams*: `Get-Item -Path <file> -Stream *`

### Processes
- **Goal**: Enumerate currently running processes.
- **Description**: Uses WMI to list running processes with file path, command line, and parent PID, then attaches hash/signature/MOTW trust signals per path.
- **External Tools**: [Sysinternals Process Explorer](https://learn.microsoft.com/en-us/sysinternals/downloads/process-explorer) for advanced process tree visualization and malware analysis.
- **Why / Abuse**: Running processes are where active intrusions live. Analysts hunt for unsigned binaries in odd paths, name masquerading (T1036 - e.g. `svch0st.exe`, or a real name running from the wrong directory), and anomalous parent/child lineage (T1055 process injection, T1059 - Office or a browser spawning `powershell.exe`/`cmd.exe`). The command line often exposes encoded PowerShell, LOLBins (`rundll32`, `mshta`, `regsvr32`), and C2 arguments.
- **Commands**:
  - `Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, Path, CommandLine`

### Services
- **Goal**: Enumerate installed Windows services.
- **Description**: Lists all services, their state, start mode, and the executable path.
- **Why / Abuse**: Services are a durable, SYSTEM-level persistence and execution mechanism (T1543.003). Look for services with binaries in user-writable paths, unquoted service paths (T1574.009), recently created or oddly named services, and `cmd.exe`/`powershell.exe` set as the ImagePath. Auto-start services surviving reboot are a hallmark of established footholds.
- **Commands**:
  - `Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName, ProcessId`

### Scheduled Tasks
- **Goal**: Enumerate configured scheduled tasks.
- **Description**: Lists scheduled tasks and their associated actions/commands, run times, and author.
- **Why / Abuse**: Scheduled tasks are one of the most common persistence and execution techniques (T1053.005), used for boot/logon startup, periodic C2 beaconing, and time-delayed payloads. Hunt for tasks that launch script interpreters or files from temp paths, tasks with blank/spoofed authors, and hidden tasks (created directly in the registry to evade `schtasks`).
- **Commands**:
  - `Get-ScheduledTask | Select-Object TaskName, TaskPath, State, Author`
  - `(Get-ScheduledTask).Actions`

### Network Connections & ARP
- **Goal**: Enumerate active network connections and the ARP cache.
- **Description**: Lists listening and established TCP and UDP endpoints, mapping them to process IDs, and dumps the ARP table.
- **External Tools**: [Sysinternals TCPView](https://learn.microsoft.com/en-us/sysinternals/downloads/tcpview) for a live GUI view of all network endpoints and their owning processes.
- **Why / Abuse**: Connections reveal command-and-control, lateral movement, and exfiltration in real time (T1071, T1571 non-standard ports). Correlate the owning PID back to the Processes list: a signed system process talking to an unknown external IP, or a listener on an unexpected port, is a strong lead. The ARP cache shows which hosts this machine recently talked to on the LAN, useful for scoping lateral movement.
- **Commands**:
  - `Get-NetTCPConnection | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess`
  - `Get-NetUDPEndpoint | Select-Object LocalAddress, LocalPort, OwningProcess`
  - `Get-NetNeighbor` or `arp -a`

### Local Users and Privileged Access
- **Goal**: Enumerate local user accounts and administrative group members.
- **Description**: Lists all local users and the members of the Administrators and Remote Desktop Users groups.
- **Why / Abuse**: Adversaries create accounts for persistence (T1136.001) and add accounts to privileged groups for privilege escalation and durable access (T1098, T1078 valid accounts). Look for unexpected local admins, recently created or renamed accounts, disabled accounts that were re-enabled, and unfamiliar members of Remote Desktop Users (which grants interactive remote logon).
- **Commands**:
  - `Get-LocalUser | Select-Object Name, Enabled, Description, LastLogon`
  - `Get-LocalGroupMember -Group "Administrators"`
  - `Get-LocalGroupMember -Group "Remote Desktop Users"`

### Active Logged In Users
- **Goal**: Enumerate currently active interactive or RDP sessions.
- **Description**: Bypasses WMI to directly execute `quser.exe` and identify active console or RDP sessions.
- **Why / Abuse**: Shows who is on the box right now. An unexpected active RDP session, a logged-on service account, or a session from an unfamiliar source can be an attacker's live hands-on-keyboard access (T1021.001). Cross-check session start times against the incident window and the RDP event logs.
- **Commands**:
  - `quser.exe` or `query user`

### System Persistence
- **Goal**: Identify common registry-based persistence mechanisms.
- **Description**: Checks standard Run/RunOnce keys, Winlogon Shell/Userinit, BootExecute, BITS transfer jobs, and the higher-signal hijack points below.
- **External Tools**: [Sysinternals Autoruns](https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns) is the gold standard for comprehensively identifying persistence mechanisms across the entire OS (Registry, Services, Scheduled Tasks, WMI, etc).
  - *Example*: `autorunsc.exe -a * -c -h -m -v > autoruns_output.csv` (Exports all locations to CSV with VirusTotal hashes)
- **Why / Abuse**: The registry offers dozens of "run this automatically" hooks that survive reboot. Each mechanism below is a documented ATT&CK sub-technique; a value pointing at a script interpreter or a file in a user-writable path is the tell.
  - **Run / RunOnce keys** (T1547.001): the classic autostart. `HKLM` runs for all users, `HKCU` per user.
  - **Winlogon Shell / Userinit** (T1547.004): `Shell` should be `explorer.exe` and `Userinit` should be `...\userinit.exe,` - anything appended launches at every logon.
  - **BootExecute** (T1547.001): native apps run by the Session Manager before the shell loads; should normally be only `autocheck autochk *`.
  - **Image File Execution Options (IFEO) Debugger / SilentProcessExit** (T1546.012): a `Debugger` value under a program's IFEO key silently launches the attacker's binary whenever that program (or its exit) is triggered - often paired with accessibility binaries (`sethc.exe`, `utilman.exe`).
  - **AppInit_DLLs** (T1546.010): DLLs listed here are injected into nearly every user-mode process that loads `user32.dll` - global code injection. Legitimately almost always empty; a populated value with `LoadAppInit_DLLs=1` is highly suspicious.
  - **Winlogon Notify** (T1547.004): legacy logon notification packages load a DLL at logon/logoff/lock events.
  - **BITS Jobs** (T1197): Background Intelligent Transfer Service jobs can download payloads and re-trigger, persisting outside the usual autostart locations.
- **Commands**:
  - `Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"`
  - `Get-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"`
  - `Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name Shell, Userinit`
  - `Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "BootExecute"`
  - *IFEO debuggers*: `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options" | ForEach-Object { Get-ItemProperty $_.PSPath -Name Debugger -ErrorAction SilentlyContinue }`
  - *SilentProcessExit monitors*: `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SilentProcessExit" | ForEach-Object { Get-ItemProperty $_.PSPath -Name MonitorProcess -ErrorAction SilentlyContinue }`
  - *AppInit_DLLs*: `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows" -Name AppInit_DLLs, LoadAppInit_DLLs`
  - *Winlogon Notify*: `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\Notify" | ForEach-Object { Get-ItemProperty $_.PSPath -Name DllName -ErrorAction SilentlyContinue }`
  - `Get-BitsTransfer -AllUsers`

### Startup Files
- **Goal**: Enumerate files in startup folders.
- **Description**: Lists executables and scripts configured to run on user login, with trust signals (hash/signature/MOTW) attached.
- **Why / Abuse**: The Startup folder is a low-effort, high-reliability autostart (T1547.001) that does not require registry or admin access - a shortcut or script dropped here runs at logon. A downloaded (MOTW-tagged) or unsigned item in Startup is a strong indicator of a foothold.
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
- **Why / Abuse**: Prefetch and shell history prove a program *ran* and *when*, even if the binary was later deleted - critical for reconstructing attacker activity and defeating anti-forensics. Attackers try to clear PowerShell history (`ConsoleHost_history.txt`) to hide tooling (T1070.003), and the presence/absence of expected artifacts is itself evidence. Prefetch records first/last run times and run counts.
- **Commands**:
  - `Get-ChildItem -Path "C:\Windows\Prefetch\*.pf" -File`
  - `Get-Content (Get-PSReadLineOption).HistorySavePath`

### Recycle Bin
- **Goal**: Enumerate deleted files and their original paths.
- **Description**: Parses the binary `$I` files stored in `C:\$Recycle.Bin` across all user SIDs to reconstruct deleted files and deletion timestamps.
- **Why / Abuse**: The Recycle Bin preserves the original path, size, and deletion time of "deleted" files. Attackers stage data for exfiltration and then delete it, or discard tools after use (T1070.004 indicator removal); the `$I` metadata recovers what was removed and when, per user SID.
- **Commands**:
  - `Get-ChildItem -Path 'C:\$Recycle.Bin' -Recurse -Filter '$I*'`

### USB History
- **Goal**: Enumerate historically connected USB devices.
- **Description**: Queries the USBSTOR registry key to identify previously connected thumb drives.
- **Why / Abuse**: Removable media is a vector for initial access/malware delivery (T1091) and for data exfiltration or physical theft (T1052.001). USBSTOR records device vendor/product/serial and first/last-connect times, letting you tie an unauthorized device to a timeframe and, via the serial, to a specific piece of hardware.
- **Commands**:
  - `Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR" | Get-ChildItem | Get-ItemProperty`

### Installed Software
- **Goal**: Enumerate installed applications.
- **Description**: Queries Uninstall registry keys across HKLM and HKCU for installed programs.
- **Why / Abuse**: Reveals attacker-installed tooling (remote-access tools like AnyDesk/TeamViewer, tunnelers, "hacktools"), unwanted/unauthorized software, and vulnerable versions an adversary could exploit. Per-user (HKCU) installs are a common way to drop RATs without admin rights. Also useful for spotting supply-chain-risky or outdated packages.
- **Commands**:
  - `Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"`
  - `Get-ItemProperty "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"`
  - `Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"`

### Firewall Rules
- **Goal**: Enumerate active Windows Firewall rules.
- **Description**: Extracts enabled inbound and outbound firewall rules.
- **Why / Abuse**: Attackers weaken host firewalls to enable C2, lateral movement, or inbound remote access (T1562.004 Impair Defenses: Disable or Modify System Firewall). Hunt for newly added allow rules opening RDP/SMB/WinRM or high/unusual ports, rules permitting a suspicious binary, and blanket allow-any rules that shouldn't exist.
- **Commands**:
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallAddressFilter`
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallPortFilter`
  - `Get-NetFirewallRule -Enabled True | Get-NetFirewallApplicationFilter`
  - `netsh advfirewall firewall show rule name=all verbose`

### RDP Connections
- **Goal**: Identify historical inbound and outbound RDP connections.
- **Description**: Queries Terminal Services event logs and the registry to map Source/Destination IPs for RDP activity.
- **Why / Abuse**: RDP is a top lateral-movement and hands-on-keyboard access technique (T1021.001). Inbound Terminal Services events (IDs 21/24/25) reveal who connected to this host and from where; the outbound `Terminal Server Client\Servers` registry key shows which hosts *this* machine RDP'd to - a direct map of an operator pivoting through the environment.
- **Commands**:
  - *Inbound*: `Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"` (IDs 21, 24, 25)
  - *Outbound*: `Get-ItemProperty "HKCU:\Software\Microsoft\Terminal Server Client\Servers\*"`

### Docker Containers
- **Goal**: Enumerate running Docker containers and port mappings.
- **Description**: Runs Docker CLI commands to extract container status.
- **Why / Abuse**: Containers can be deployed to run malicious workloads or evade host controls (T1610), and misconfigured mounts/privileges enable container escape to the host (T1611). Review unexpected images, containers exposing ports to the network, and anything running with `--privileged` or the host filesystem mounted.
- **Commands**:
  - `docker ps -a`

### DNS Cache
- **Goal**: Identify recently resolved domains and their IPs.
- **Description**: Pulls the local DNS resolver cache to track potential C2 or data exfiltration domains.
- **Why / Abuse**: The resolver cache is a short-lived record of the domains this host recently looked up - a fast way to spot C2 domains, DGA/algorithmically-generated names, DNS-tunneling endpoints (T1071.004), and dynamic-resolution infrastructure (T1568) before the entries expire.
- **Commands**:
  - `Get-DnsClientCache`
  - `ipconfig /displaydns`

### SMB Sessions
- **Goal**: Identify active inbound SMB network sessions.
- **Description**: Extracts connected clients and the shares they are accessing over SMB.
- **Why / Abuse**: Active SMB sessions show remote hosts currently authenticated to this machine's shares - a direct signal of lateral movement or exfiltration over SMB (T1021.002). An unexpected client accessing `C$`/`ADMIN$` is a hallmark of remote admin-share abuse.
- **Commands**:
  - `Get-SmbSession`

### SMB Shares
- **Goal**: Enumerate the shares this host is exposing.
- **Description**: Lists configured SMB shares, their scope, filesystem path, and description.
- **Why / Abuse**: Attackers create new shares to move tools in and stage data out, and abuse the built-in administrative shares (`C$`, `ADMIN$`, `IPC$`) for lateral movement and remote execution (T1021.002, T1039 data from network shares). Review any non-default share, shares pointing at unusual paths, and overly permissive exposure.
- **Commands**:
  - `Get-SmbShare | Select-Object Name, ScopeName, Path, Description`
  - *Review share permissions*: `Get-SmbShareAccess -Name <ShareName>`

### Loaded Kernel Drivers
- **Goal**: Enumerate loaded kernel-mode drivers and flag unsigned or odd-path images.
- **Description**: Lists system drivers with state, start mode, and image path, attaching a signature verdict and SHA256. Drivers whose Authenticode signature cannot be verified are marked `Unverified` (not "unsigned"), because many legitimate inbox drivers are catalog-signed and would otherwise be false-flagged.
- **Why / Abuse**: Kernel drivers run at the highest privilege on the host. Adversaries load malicious drivers for rootkit-level stealth and tamper-resistance (T1014), and increasingly bring a legitimately-signed-but-vulnerable driver to disable EDR/AV from the kernel - "Bring Your Own Vulnerable Driver" (T1543.003 / T1068). Hunt for drivers with image paths outside `System32\drivers`, `Unverified` signatures, unfamiliar names, or recent creation times.
- **Commands**:
  - `Get-CimInstance Win32_SystemDriver | Select-Object Name, DisplayName, State, StartMode, PathName`
  - *Verify a driver image*: `Get-AuthenticodeSignature -FilePath <driver.sys> | Select-Object Status, SignerCertificate`
  - *Hash it for intel lookup*: `Get-FileHash -Path <driver.sys> -Algorithm SHA256`

### Microsoft Defender Security Posture
- **Goal**: Capture the endpoint's own defensive state: exclusions, real-time protection status, and detection history.
- **Description**: Records Defender exclusions (Path/Process/Extension/IP), key status flags (RealTimeProtectionEnabled, AntivirusEnabled, IsTamperProtected, signature age), and any recorded threat detections.
- **Why / Abuse**: The AV configuration is a prime attacker target and a rich source of leads. Adding an exclusion for their working directory or payload, or disabling real-time protection/tamper protection, is a standard evasion step (T1562.001 Impair Defenses: Disable or Modify Tools; T1562.006). Exclusion paths often point *directly at* where the attacker staged tooling. Recorded detections (even remediated ones) and stale signatures are strong indicators of activity to pivot on.
- **Commands**:
  - *Exclusions*: `Get-MpPreference | Select-Object ExclusionPath, ExclusionProcess, ExclusionExtension, ExclusionIpAddress`
  - *Protection status*: `Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled, AntivirusEnabled, IsTamperProtected, AntivirusSignatureLastUpdated`
  - *Detection history*: `Get-MpThreat` and `Get-MpThreatDetection`

### Event Logs
- **Goal**: Extract key security and operational event logs.
- **Description**: Queries critical Event IDs (Logons, Process Creation, Services, Tasks) from the System, Security, and Microsoft-Windows-TerminalServices logs.
- **External Tools**: [Eric Zimmerman's EvtxECmd](https://ericzimmerman.github.io/#!index.md) to bulk-parse raw `.evtx` files and output normalized CSV timelines of critical OS events.
  - *Example*: `EvtxECmd.exe -d "C:\Windows\System32\winevt\Logs" --csv "C:\temp" --csvf eventlogs_timeline.csv`
- **Why / Abuse**: Event logs are the backbone of host timelining: logon success/failure (4624/4625) exposes brute force (T1110) and use of valid accounts (T1078), process creation (4688) captures execution, and 7045 flags new service installs. Adversaries clear or tamper with logs to cover tracks (T1070.001) - a cleared Security log (event 1102) or a suspicious gap is itself an indicator.
- **Commands**:
  - `Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624, 4625, 4688}`
  - `Get-WinEvent -FilterHashtable @{LogName='System'; Id=7045}`

### Super Timeline Generation (Plaso)
- **Goal**: Create an integrated, chronological super-timeline of all system activity.
- **Description**: After gathering raw artifacts (Prefetch, Event Logs, Registry Hives, MFT, etc.), you can ingest them into [Plaso (log2timeline)](https://plaso.readthedocs.io/en/latest/) to correlate events across different sources into a single unified timeline.
- **Why / Abuse**: Individual artifacts each tell part of the story; a super-timeline stitches file, registry, log, and execution events into one chronological view so you can see cause and effect - the download, then the execution, then the persistence, then the lateral movement - and spot timestomping (T1070.006) where filesystem times disagree with corroborating artifacts.
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
- **Why / Abuse**: Sets the baseline for interpreting every other Linux artifact - distro/kernel version (exploit and vulnerable-driver context), hostname, and the host's own IPs to separate local from remote in network data. Uptime bounds the incident and can reveal a reboot used to load a kernel module or clear volatile state.
- **Commands**:
  - `uname -a`
  - `cat /etc/os-release | grep PRETTY_NAME`
  - `uptime -p`
  - `ip -4 addr show`

### Processes
- **Goal**: Enumerate currently running processes.
- **Description**: Uses `ps` to list running processes with parent IDs and start times.
- **Why / Abuse**: Active processes expose running implants, miners, and reverse shells (T1057 process discovery for the defender's view of the attacker). Hunt for processes running from `/tmp`, `/dev/shm`, or a user's home; deleted-binary processes (the executable shows as `(deleted)` in `/proc/<pid>/exe`); masquerading names; and interpreters (`bash -i`, `python -c`, `nc`) with network-facing command lines.
- **Commands**:
  - `ps -eo pid,ppid,user,start_time,command`

### Services
- **Goal**: Enumerate installed systemd services.
- **Description**: Lists all services and their active states using systemctl or service.
- **Why / Abuse**: systemd units are the primary Linux service-persistence mechanism (T1543.002). Look for unit files in writable or non-standard locations, recently modified units, `ExecStart` pointing at scripts in `/tmp` or a home directory, and enabled-but-unfamiliar services that will restart the payload on boot.
- **Commands**:
  - `systemctl list-units --type=service --all --no-pager --no-legend`
  - `service --status-all`

### Scheduled Tasks
- **Goal**: Enumerate configured cron jobs and systemd timers.
- **Description**: Reads user crontabs, system crontabs, and systemd timers.
- **Why / Abuse**: Cron and timers are the most common Linux scheduled-execution/persistence technique (T1053.003). Attackers add entries to re-launch C2, re-establish reverse shells, or run miners. Check per-user crontabs, `/etc/crontab`, the `/etc/cron.*` drop-in directories, and systemd timers for jobs invoking interpreters, `curl|bash` one-liners, or files in temp/home paths.
- **Commands**:
  - `cat /etc/crontab /etc/cron.d/*`
  - `for u in $(cat /etc/passwd | cut -d: -f1); do crontab -u $u -l; done`
  - `systemctl list-timers --all --no-pager --no-legend`

### Network Connections & ARP
- **Goal**: Enumerate active network connections and the ARP cache.
- **Description**: Lists listening and established TCP and UDP endpoints using `ss` or `netstat`, and dumps the ARP table.
- **Why / Abuse**: Reveals C2, reverse shells, and exfiltration channels with their owning process/PID (T1071, T1571). A listener on an unexpected port, or an established connection from a shell/interpreter to an external IP, is a strong lead; the ARP/neighbor table scopes recent LAN peers for lateral-movement analysis.
- **Commands**:
  - `ss -tupan`
  - `netstat -tupan`
  - `ip neigh` or `arp -a`

### Kernel Modules
- **Goal**: Enumerate loaded kernel modules.
- **Description**: Lists actively loaded kernel modules using `lsmod`.
- **Why / Abuse**: Loadable kernel modules run in ring 0 and are the classic Linux rootkit vector (T1547.006 Kernel Modules and Extensions; T1014). Malicious LKMs hide processes, files, and connections and hook syscalls to blind userland tools. Compare loaded modules against a known-good baseline; unfamiliar or unsigned modules, and discrepancies between `lsmod` and `/proc/modules`, warrant deep inspection.
- **Commands**:
  - `lsmod`

### Local Users and Privileged Access
- **Goal**: Enumerate local user accounts and users with sudo privileges.
- **Description**: Parses `/etc/passwd` for users and checks `/etc/sudoers` and `wheel/sudo` groups.
- **Why / Abuse**: Attackers add accounts (T1136.001), grant themselves sudo, or create hidden UID 0 accounts for persistence and privilege escalation (T1548.003 sudo/setuid; T1098). Hunt for unexpected UID 0 users (a non-`root` account with UID 0), new entries in `sudoers`/`sudoers.d`, `NOPASSWD` grants, and unfamiliar members of the `sudo`/`wheel` groups.
- **Commands**:
  - `cat /etc/passwd`
  - `cat /etc/sudoers | grep -v '^#'`
  - `cat /etc/group | grep -E '^(sudo|wheel):'`

### Active Logged In Users
- **Goal**: Enumerate active SSH and console sessions.
- **Description**: Identifies active PTY/TTY and SSH sessions with remote host IPs.
- **Why / Abuse**: Shows current interactive access, including live attacker SSH sessions (T1021.004) and their source IPs. An unexpected session, a login from an unfamiliar address, or a session outside normal hours is a direct hands-on-keyboard indicator; cross-check against the auth logs.
- **Commands**:
  - `who`
  - `w -h`

### System Persistence and Startup Files
- **Goal**: Identify common persistence mechanisms and startup scripts.
- **Description**: Reads shell profiles, `rc.local`, systemd generators, init scripts, and SSH authorized_keys.
- **Why / Abuse**: Beyond cron and services, Linux offers many quiet autostart hooks. Shell init files (`.bashrc`, `.bash_profile`, `/etc/profile`) run attacker commands on every login/shell (T1546.004 Unix Shell Configuration Modification); `rc.local` and init scripts run at boot; and - most abused of all - an attacker-controlled key appended to `~/.ssh/authorized_keys` grants passwordless, persistent remote access that survives password changes (T1098.004 SSH Authorized Keys). Review each for unexpected commands or unfamiliar keys.
- **Commands**:
  - `cat /etc/rc.local ~/.bash_profile ~/.bashrc ~/.profile /etc/profile`
  - `cat ~/.ssh/authorized_keys /root/.ssh/authorized_keys`
  - `ls -la /etc/init.d/ /etc/rc*.d/`

### Execution Evidence
- **Goal**: Identify evidence of recent program execution and commands.
- **Description**: Reads shell history files and sudo execution logs.
- **Why / Abuse**: Shell history is often the richest record of hands-on-keyboard activity - the exact commands an operator typed, tooling they pulled down, and hosts they pivoted to. Attackers frequently truncate or unset history to hide this (T1070.003 Clear Command History; unset `HISTFILE`), so both its contents *and* suspicious gaps/emptiness are evidence. sudo entries in the auth log tie privileged commands to accounts and times.
- **Commands**:
  - `cat ~/.bash_history ~/.zsh_history`
  - `cat /var/log/auth.log | grep sudo`

### Recycle Bin
- **Goal**: Enumerate deleted files and their original paths.
- **Description**: Parses `.trashinfo` files in user home directories to reconstruct deleted files and deletion timestamps.
- **Why / Abuse**: The freedesktop Trash preserves the original path and deletion time of GUI-deleted files (T1070.004). It can recover staged-then-discarded tooling or data an attacker tried to remove, per user.
- **Commands**:
  - `cat ~/.local/share/Trash/info/*.trashinfo`

### Installed Software
- **Goal**: Enumerate installed packages.
- **Description**: Queries dpkg, rpm, or snap for installed software based on the package manager.
- **Why / Abuse**: Surfaces attacker-installed tooling, unauthorized packages, and vulnerable versions that could be exploited or that indicate supply-chain risk. Compare against a baseline; recently installed packages around the incident window, or tools with no business purpose (network scanners, tunnelers), are leads.
- **Commands**:
  - `dpkg-query -W -f='${binary:Package}|${Version}|${Maintainer}\n'`
  - `rpm -qa --qf '%{NAME}|%{VERSION}|%{VENDOR}\n'`
  - `snap list`

### Firewall Rules
- **Goal**: Enumerate active firewall rules.
- **Description**: Extracts configuration from ufw, firewalld, or raw iptables.
- **Why / Abuse**: Adversaries modify host firewall rules to permit C2, open listeners for inbound access, or allow exfiltration (T1562.004). Review for newly added allow rules, opened high/unusual ports, and rules that permit a suspicious process or source - and note that raw `iptables -S` can reveal rules the higher-level tools (ufw/firewalld) do not display.
- **Commands**:
  - `ufw status numbered`
  - `firewall-cmd --list-all`
  - `iptables -S`

### Docker Containers
- **Goal**: Enumerate running Docker containers and port mappings.
- **Description**: Runs Docker CLI commands to extract container status.
- **Why / Abuse**: Containers can host malicious workloads or provide an escape path to the host when misconfigured (T1610 Deploy Container; T1611 Escape to Host). Review unexpected images, containers publishing ports, and any run with `--privileged`, host networking, or the host filesystem/Docker socket mounted in.
- **Commands**:
  - `docker ps -a`

### DNS Configuration
- **Goal**: Identify local DNS resolver configurations.
- **Description**: Reads the resolv.conf file to find configured upstream nameservers.
- **Why / Abuse**: Repointing DNS is a stealthy way to redirect traffic, enable phishing/MITM, or route resolution through attacker infrastructure (T1071.004 DNS; T1584 hijacked infrastructure). An unexpected nameserver in `resolv.conf` - especially an external or unfamiliar IP - can indicate tampering.
- **Commands**:
  - `cat /etc/resolv.conf`

### Event Logs
- **Goal**: Extract key authentication and system event logs.
- **Description**: Reads the tail of common syslog and authentication logs.
- **Why / Abuse**: `auth.log`/`secure` capture SSH and sudo activity - the core of Linux intrusion timelining: failed logins expose brute force (T1110), accepted logins from unfamiliar IPs expose valid-account abuse (T1078), and sudo entries expose privilege escalation. Attackers delete or edit these logs to cover tracks (T1070.002 Clear Linux or Mac System Logs), so gaps and truncation are themselves indicators.
- **Commands**:
  - `tail -n 500 /var/log/auth.log /var/log/secure`
  - `tail -n 500 /var/log/syslog /var/log/messages`
