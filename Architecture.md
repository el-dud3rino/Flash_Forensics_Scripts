# Flash Forensics Technical Architecture (Deep Dive)

This document provides a highly technical, end-to-end breakdown of how Flash Forensics operates. It covers the complete lifecycle of data collection using specific OS-level APIs across Windows and Linux, local dataset serialization, HTML dashboard compilation, and the client-side JavaScript execution environment powering the UI.

---

## 1. High-Level Architecture Overview

Flash Forensics operates on a hub-and-spoke model where a central **Orchestrator** (`Invoke-DFIRCollection.ps1`) pushes ephemeral payloads to remote targets (the spokes). It strictly adheres to an **agentless** and **fileless** (on the target) methodology. 

1. **Orchestrator**: Executes locally on the analyst's machine. Manages concurrency, remote connections (`WinRM` / `OpenSSH`), and payload injection.
2. **Payloads**: Dedicated, standalone scripts (`Get-DFIRSystemData.ps1` and `Get-LinuxDFIRSystemData.py`) that perform the actual OS-level API calls and binary executions.
3. **Data Return**: Data is serialized as JSON (`ConvertTo-Json -Depth 5` or `json.dumps()`), returned via remote runspace output streams or `stdout`, and saved to disk.
4. **Compilation & Storage**: The orchestrator writes the standalone JSON payload to `FlashForensics_Output`. Simultaneously, it implements an **O(1) String Concatenation** regex algorithm to directly append the raw JSON payload into a localized `data.js` database. This eliminates O(n) disk I/O parsing and maintains a persistent standalone `index.html` Single-Page Application (SPA).
5. **Analyst Collection Log**: Maintains a daily CSV (`Analyst_Collection_Log_YYYY-MM-DD.csv`) mapping hostnames, OS, and statuses.

---

## 2. Windows Data Collection Engine

The orchestrator leverages PowerShell Remoting (`Invoke-Command -AsJob`) to pass the script block of `Get-DFIRSystemData.ps1` to the target. To prevent WinRM connection timeouts from silently hanging the script on offline or Linux endpoints, the orchestrator implements a lightning-fast pre-flight TCP socket check on ports 5985 and 5986 with a 1-second timeout. Execution is handled via **Parallel Background Jobs** (`Start-Job` and `Invoke-Command -AsJob`), allowing asynchronous data collection across hundreds of nodes simultaneously with live CLI progress tracking.

### Dynamic Collection Windows
The orchestrator parses the existing `data.js` payload to identify previously scanned hosts. It implements a smart temporal filter, requesting **5 days** of historical data (Event Logs, Prefetch, PS History) for new hosts, and only **2 days** for repeat hosts, drastically improving collection speed.

### Explicit Collection Mechanisms
*   **System Information**: Uses WMI/CIM classes: `Get-CimInstance Win32_OperatingSystem` and `Win32_ComputerSystem`. IP addresses are pulled via `Get-NetIPAddress -AddressFamily IPv4`.
*   **Processes**: Uses `Get-CimInstance Win32_Process`. For each process path, it calculates a cryptographic hash via `Get-FileHash -Algorithm SHA256`, verifies the digital signature using `Get-AuthenticodeSignature`, and reads the `Zone.Identifier` alternate data stream to detect a **Mark-of-the-Web** (download origin URL and zone). These three expensive per-file operations are **cached by path**, so a system running dozens of identical binaries (e.g. many `svchost.exe`) inspects each unique image only once. The same cache is reused for Startup Files and Loaded Drivers.
*   **Services**: Uses `Get-CimInstance Win32_Service`.
*   **Scheduled Tasks**: Leverages the native ScheduledTasks module (`Get-ScheduledTask` and `Get-ScheduledTaskInfo`).
*   **Network Connections**: Uses `Get-NetTCPConnection` and `Get-NetUDPEndpoint`. Connections are internally mapped back to their owning processes by joining against the previously collected `Win32_Process` array based on `OwningProcess` / `ProcessId`.
*   **ARP Table**: Leverages `Get-NetNeighbor` to collect IPv4 ARP cache entries.
*   **Local Users**: Uses `Get-LocalUser`.
*   **Privileged Access**: Uses `Get-LocalGroupMember` to enumerate members of the "Administrators" and "Remote Desktop Users" groups.
*   **System Persistence**:
    *   Iterates through standard registry hives: `HKLM:\Software\Microsoft\Windows\CurrentVersion\Run` and `RunOnce`.
    *   Mounts the `HKEY_USERS` drive dynamically via `New-PSDrive` to read startup keys for actively loaded user profiles (`S-1-5-21-*`).
    *   Mounts unloaded offline hives by locating `NTUSER.DAT` files in `C:\Users\*`, temporarily loading them via `reg.exe load HKU\TEMP_...`, reading the `Run` keys, and safely unloading them.
    *   Extracts `BootExecute`, `Userinit`, and `Shell` strings from `Winlogon` and `Session Manager`.
    *   Reads the cleartext source of all known local PowerShell profile locations (e.g., `Microsoft.PowerShell_profile.ps1`).
    *   Polls `Get-BitsTransfer -AllUsers` for persistence via BITS jobs.
    *   Enumerates **Image File Execution Options** `Debugger` values and `SilentProcessExit` `MonitorProcess` handlers (debugger-hijack persistence, MITRE T1546.012).
    *   Reports **AppInit_DLLs** / `LoadAppInit_DLLs` (native and Wow6432Node) only when populated (MITRE T1546.010), and legacy **Winlogon Notify** package `DllName` handlers (MITRE T1547.004).
*   **USB History**: Enumerates historical USB device connections via the `HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR` registry key.
*   **Execution Evidence**: Parses the `C:\Windows\Prefetch\*.pf` directory metadata, queries BAM (Background Activity Moderator) and UserAssist (decoding ROT13) from the registry, gathers metadata for JumpLists, ShimCache, Amcache, and SRUM, and reads the `ConsoleHost_history.txt` (PSReadLine history) for every user profile.
*   **Recycle Bin**: Enumerates all subdirectories in `C:\$Recycle.Bin` and manually parses the binary `$I` files (supporting both v1 and v2 formats) to extract original file paths, deletion times, and sizes across all user SIDs.
*   **Installed Software**: Queries uninstall registry keys under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` and `Wow6432Node`, as well as `HKCU`.
*   **Firewall Rules**: Uses `netsh advfirewall firewall show rule name=all verbose` and parses the output via Regex grouping, specifically filtering for `Enabled = "Yes"`.
*   **Loaded Drivers**: Enumerates `Get-CimInstance Win32_SystemDriver`, normalizes the driver image path, and runs it through the cached file inspection to record a signature verdict (`Signed` / `Unverified` / `Unknown`) — the dashboard's flat, sortable table lets an analyst isolate unsigned or oddly-pathed kernel drivers.
*   **Microsoft Defender**: Collects antivirus exclusions (`Get-MpPreference` path/process/extension/IP), real-time and tamper-protection status (`Get-MpComputerStatus`), and detection history (`Get-MpThreat`). Grouped in the dashboard into *Defender Exclusions*, *Defender Status*, and *Defender Detections* sections.
*   **RDP Connections**:
    *   **Inbound**: Queries `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` (Event IDs `21`, `24`, `25`).
    *   **Outbound**: Queries `Microsoft-Windows-TerminalServices-RDPClient/Operational` (Event ID `1024`) and parses the `Terminal Server Client\Servers` registry key for all users.
*   **DNS Cache**: Leverages `Get-DnsClientCache`. Implements a graceful fallback to raw text parsing of `ipconfig /displaydns` for older operating systems or constrained remote WinRM runspaces where the cmdlet fails.
*   **SMB Sessions & Shares**: Leverages `Get-SmbSession` and `Get-SmbShare`.
*   **Active Logged In Users**: Bypasses the WMI abstraction layer and directly executes `quser.exe` (checking both `System32` and `sysnative` to support 32-bit remote runspaces), parsing the column output for Interactive/RDP sessions. If no interactive sessions exist (common on headless remote servers), it falls back to querying `Win32_ComputerSystem.UserName` to map the primary console user.
*   **Docker Containers**: Checks for the existence of `docker` and runs `docker ps -a --format '{{json .}}'` to collect container state and port mappings.
*   **Event Logs (High Value Filter)**: Uses `Get-WinEvent` targeting `Security`, `System`, and `PowerShell/Operational` logs. Explicitly extracts:
    *   `4103`, `4104`: PowerShell Script Block/Module Logging
    *   `4624`, `4625`: Logon Success / Failure
    *   `4672`: Special Privileges Assigned
    *   `4688`: Process Creation
    *   `4697`, `7045`: Service Installation
    *   `4698`, `4702`: Scheduled Task Created / Updated
    *   `4720`, `4722`, `4738`: User Account modifications

---

## 3. Linux Data Collection Engine

The orchestrator leverages the native Windows OpenSSH client (`ssh.exe`) to execute `Get-LinuxDFIRSystemData.py`. 
Execution command: `Get-Content $PayloadScript -Raw | ssh.exe -l <user> <ip> "python3 -"`
This pipes the cleartext Python script directly to the `stdin` of the remote `python3` binary. No files touch the remote disk.

### Explicit Collection Mechanisms (Subprocess Parsing)
The Python payload relies heavily on executing native Linux binaries via `subprocess.run(..., capture_output=True)` and applying regex/string manipulation to the `stdout`.
*   **System Info**: Parses `uname -a`, `/etc/os-release`, `uptime`, and `ip -4 addr show`.
*   **Processes**: Parses `ps -eo pid,ppid,user,start_time,command`.
*   **Services**: Parses `systemctl list-units --type=service --all` (falling back to `service --status-all` on SysV systems), extracting the unit name, load/active/sub states, and description.
*   **Network Connections**: Parses `ss -tupan` or fallbacks to `netstat -tupan`.
*   **ARP Table**: Parses `ip neigh show` or fallbacks to `arp -an`.
*   **Local Users**: Directly reads `/etc/passwd`.
*   **Privileged Access**: Parses `/etc/sudoers` for explicit configurations and `/etc/group` for members of the `sudo` and `wheel` groups.
*   **System Persistence**: Reads the raw contents of `rc.local`, `.bashrc`, `.bash_profile`, and `.ssh/authorized_keys` for all users in `/home/` and `/root/`. Parses `crontab -l` for users and dumps `/etc/cron.*` directories.
*   **Execution Evidence**: Reads `.bash_history` for all users and parses `/var/log/auth.log` or `/var/log/secure` for `sudo` command executions.
*   **Recycle Bin**: Parses `.local/share/Trash/info/*.trashinfo` files across all user home directories defined in `/etc/passwd` to extract original file paths and deletion dates.
*   **Installed Software**: Uses `dpkg-query -W` (Debian/Ubuntu), `rpm -qa` (RHEL/CentOS), and `snap list`.
*   **Firewall Rules**: Checks for `ufw status`, `firewall-cmd --list-all`, or dumps raw `iptables -S`.
*   **DNS Configuration**: Reads and parses `/etc/resolv.conf`.
*   **Active Logged In Users**: Executes `who 2>/dev/null` to identify active PTY/TTY and SSH sessions with remote host IPs.
*   **Docker Containers**: Executes `docker ps -a --format '{{json .}}'` to map running images and network ports.

---

## 4. HTML Dashboard Logic & UI Engine

The dashboard (`index.html`) is a Single-Page Application (SPA) built with Vanilla Javascript and CSS. It loads `data.js` into memory via a `<script>` tag mapping to `const dfirData`.

### Global Search & Column Filtering
The filtering engine supports logical operators (`AND`, `OR`, `NOT`).
1.  **Tokenization**: The query string is split via Regex into distinct terms. `AND`/`&`/` ` are intersection requirements. `OR`/`,` are union requirements. `NOT`/`!` are exclusion requirements.
2.  **Evaluation (`evaluateQuery`)**: The Javascript engine flattens a given JSON row object into a single concatenated, lowercase string. It then iterates over the tokenized boolean logic, performing `String.includes()` checks.
3.  **Column Filters**: Functions identically to Global Search, but the string evaluation is strictly bound to the value of the specific column object rather than the entire row.

### Timeline Diffing (Compare Mode)
When a user selects "Diff Timelines", the dashboard dynamically compares a **Base** (older) and **Target** (newer) JSON dataset.

1.  **`hashArtifact(obj, tabName)` Function**: 
    To accurately match artifacts across time, ephemeral data (noise) must be discarded. The Javascript engine defines a specific array of `compareGroupKeys` per tab. 
    *Example: For the `Processes` tab, the engine explicitly only hashes `['Name', 'Path', 'CommandLine', 'SHA256', 'Signer']`. It discards `ProcessId` and `CreationDate`.*
2.  **`computeDiff(baseArr, targetArr, tabName)` Logic**:
    *   Generates the hash for every object in both arrays.
    *   **Added**: Hashes present in `targetMap` but missing from `baseMap`.
    *   **Removed**: Hashes present in `baseMap` but missing from `targetMap`.
    *   **Unchanged**: Hashes present in both maps.
3.  **Rendering**: A virtual `_DiffStatus` property is injected into the row object. The `renderTable()` function checks this property to apply exact CSS rules (`background: rgba(40, 167, 69, 0.1); border-left: 3px solid #28a745;` for Added) and injects the UI badge.

### Triage Flagging (Persistence via LocalStorage)
Users can flag rows for investigation using the 🚩 icon.
1.  **Interaction**: Clicking the icon triggers `toggleFlag(trId)`.
2.  **Identification**: A unique composite string is generated: `Hostname|Timestamp|Tab|StringifiedRowData`.
3.  **Persistence**: This string is pushed into the browser's native `localStorage.getItem('ff_flags')` array. Users can also add **Analyst Notes** in the Flagged Items tab, which are saved back into the exact artifact's object in `localStorage`.
4.  **Export Engine**: The "Export Flags" logic iterates through `localStorage`, parses the stringified data back into CSV format (including the custom Analyst Notes), generates a virtual Blob URL (`URL.createObjectURL(blob)`), and dynamically clicks a hidden anchor tag to trigger the browser download of `FFS_Flagged_Items.csv`.

### Ask AI (Optional GenAI Integration)
The **Ask AI** popover (opened from a top-bar button) is the only component that leaves the local sandbox. It is rendered as a floating panel reparented to `document.body` so it overlays the active data tab without changing `currentTab` — which is what the "current host + current tab" context scope reads. It is fully opt-in and provider-agnostic.

1.  **Configuration (client-side only)**: The analyst selects a provider preset (Anthropic Claude, OpenAI, Google Gemini, or a GenAI.mil / custom OpenAI-compatible gateway) and supplies a Base URL, model id, and API key. Gemini uses its OpenAI-compatible endpoint (`/v1beta/openai/chat/completions`), so it flows through the same OpenAI-format transport rather than a bespoke branch. All four values persist **only** in the browser's `localStorage` (`ff_ai_*` keys); they are never written into `index.html`/`data.js` and never committed. No key or endpoint is embedded in the generated dashboard.
2.  **Context scoping**: Before each question the analyst chooses how much data to attach — the current host + current tab (a minimal slice), the entire current host, or every loaded host. The engine serializes only that slice to JSON and displays an estimated size (chars / tokens) with a warning past ~500K characters, so nothing is sent silently.
3.  **Request transport**: A raw `fetch` is issued directly from the browser. For the Anthropic format it POSTs to `/v1/messages` with `x-api-key`, `anthropic-version: 2023-06-01`, and `anthropic-dangerous-direct-browser-access: true`, and reads the `content[].text` blocks. For the OpenAI-compatible format it POSTs to the gateway's `/chat/completions` with an `Authorization: Bearer` header and reads `choices[0].message.content`. (From a `file://` origin a gateway may block CORS; the UI then advises serving the folder via `python -m http.server`.)
4.  **Prompt-injection hardening**: The system prompt instructs the model that the attached DATA is untrusted evidence from a possibly-compromised host — command lines, filenames, and log messages may contain attacker-controlled text — and that it must analyze the data only, never follow instructions embedded within it.

---

## 5. Commands Executed (Reference)

### Windows Commands
During the Windows data collection process, the following native executables and PowerShell cmdlets are executed (either directly or indirectly via parameters): `Get-CimInstance` (querying classes such as `Win32_OperatingSystem`, `Win32_ComputerSystem`, `Win32_Process`, `Win32_Service`, `Win32_SystemDriver`, `__EventFilter`, and `CommandLineEventConsumer`), `Get-NetIPAddress`, `Get-FileHash`, `Get-AuthenticodeSignature`, `Get-Content -Stream Zone.Identifier`, `Get-ScheduledTask`, `Get-ScheduledTaskInfo`, `Get-NetTCPConnection`, `Get-NetUDPEndpoint`, `Get-LocalUser`, `Get-LocalGroupMember`, `Get-ItemProperty`, `Get-ChildItem`, `Get-Item`, `Get-PSDrive`, `New-PSDrive`, `Start-Process` (invoking `cmd.exe` to run `reg.exe load` and `reg.exe unload`), `Get-BitsTransfer`, `Get-Content`, `Get-WinEvent`, `Get-MpPreference`, `Get-MpComputerStatus`, `Get-MpThreat`, `netsh advfirewall firewall show rule name=all verbose`, `Get-DnsClientCache`, `ipconfig /displaydns`, `Get-SmbSession`, `quser.exe`, and `docker ps -a --format '{{json .}}'`.

### Linux Commands
During the Linux data collection process, the following native binaries and commands are executed as subprocesses: `uname -a`, `cat /etc/os-release`, `uptime -p`, `uptime`, `ip -4 addr show`, `cat /etc/resolv.conf`, `w -h`, `docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}'`, `docker ps -a --format '{{json .}}'`, `ps -eo pid,ppid,user,start_time,command`, `systemctl list-units --type=service --all --no-pager --no-legend`, `service --status-all`, `cat /etc/crontab /etc/cron.d/*`, `crontab -u`, `systemctl list-timers --all --no-pager --no-legend`, `ss -tupan`, `netstat -tupan`, `lsmod`, `tail -n 100`, `journalctl -u ssh -n 100 --no-pager`, `tail -n 50`, `cat /etc/sudoers`, `cat /etc/group`, `dpkg-query -W -f='${binary:Package}|${Version}|${Maintainer}\n'`, `rpm -qa --qf '%{NAME}|%{VERSION}|%{VENDOR}\n'`, `snap list`, `ufw status numbered`, `firewall-cmd --list-all`, `iptables -S`, and `who`.
