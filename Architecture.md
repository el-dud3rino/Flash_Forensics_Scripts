# Flash Forensics Technical Architecture (Deep Dive)

This document provides a highly technical, end-to-end breakdown of how Flash Forensics operates. It covers the complete lifecycle of data collection using specific OS-level APIs across Windows and Linux, local dataset serialization, HTML dashboard compilation, and the client-side JavaScript execution environment powering the UI.

---

## 1. High-Level Architecture Overview

Flash Forensics operates on a hub-and-spoke model where a central **Orchestrator** (`Invoke-DFIRCollection.ps1`) pushes ephemeral payloads to remote targets (the spokes). It strictly adheres to an **agentless** and **fileless** (on the target) methodology. 

1. **Orchestrator**: Executes locally on the analyst's machine. Manages concurrency, remote connections (`WinRM` / `OpenSSH`), and payload injection.
2. **Payloads**: Dedicated, standalone scripts (`Get-DFIRSystemData.ps1` and `Get-LinuxDFIRSystemData.py`) that perform the actual OS-level API calls and binary executions.
3. **Data Return**: Data is serialized as JSON (`ConvertTo-Json -Depth 5` or `json.dumps()`), returned via remote runspace output streams or `stdout`, and saved to disk.
4. **Compilation**: The orchestrator iterates through the `FlashForensics_Output` folder, parsing all historical `*-DFIR_Data.json` files and injecting them into a localized `data.js` payload. This file acts as the database for the standalone `index.html` Single-Page Application (SPA).

---

## 2. Windows Data Collection Engine

The orchestrator leverages PowerShell Remoting (`Invoke-Command`) to pass the script block of `Get-DFIRSystemData.ps1` to the target. It executes entirely in memory within the `wsmprovhost.exe` (WinRM Provider Host) process.

### Explicit Collection Mechanisms
*   **System Information**: Uses WMI/CIM classes: `Get-CimInstance Win32_OperatingSystem` and `Win32_ComputerSystem`. IP addresses are pulled via `Get-NetIPAddress -AddressFamily IPv4`.
*   **Processes**: Uses `Get-CimInstance Win32_Process`. For each process path, it calculates a cryptographic hash via `Get-FileHash -Algorithm SHA256` and verifies the digital signature using `Get-AuthenticodeSignature`.
*   **Services**: Uses `Get-CimInstance Win32_Service`.
*   **Scheduled Tasks**: Leverages the native ScheduledTasks module (`Get-ScheduledTask` and `Get-ScheduledTaskInfo`).
*   **Network Connections**: Uses `Get-NetTCPConnection` and `Get-NetUDPEndpoint`. Connections are internally mapped back to their owning processes by joining against the previously collected `Win32_Process` array based on `OwningProcess` / `ProcessId`.
*   **Local Users**: Uses `Get-LocalUser` and `Get-LocalGroupMember` (for the "Administrators" and "Remote Desktop Users" groups).
*   **System Persistence**:
    *   Iterates through standard registry hives: `HKLM:\Software\Microsoft\Windows\CurrentVersion\Run` and `RunOnce`.
    *   Mounts the `HKEY_USERS` drive dynamically via `New-PSDrive` to read startup keys for actively loaded user profiles (`S-1-5-21-*`).
    *   Mounts unloaded offline hives by locating `NTUSER.DAT` files in `C:\Users\*`, temporarily loading them via `reg.exe load HKU\TEMP_...`, reading the `Run` keys, and safely unloading them.
    *   Extracts `BootExecute`, `Userinit`, and `Shell` strings from `Winlogon` and `Session Manager`.
    *   Reads the cleartext source of all known local PowerShell profile locations (e.g., `Microsoft.PowerShell_profile.ps1`).
    *   Polls `Get-BitsTransfer -AllUsers` for persistence via BITS jobs.
*   **Execution Evidence**: Parses the `C:\Windows\Prefetch\*.pf` directory metadata and reads the `ConsoleHost_history.txt` (PSReadLine history) for every user profile.
*   **Firewall Rules**: Uses `netsh advfirewall firewall show rule name=all verbose` and parses the output via Regex grouping, specifically filtering for `Enabled = "Yes"`.
*   **RDP Connections**:
    *   **Inbound**: Queries `Microsoft-Windows-TerminalServices-LocalSessionManager/Operational` (Event IDs `21`, `24`, `25`).
    *   **Outbound**: Queries `Microsoft-Windows-TerminalServices-RDPClient/Operational` (Event ID `1024`) and parses the `Terminal Server Client\Servers` registry key for all users.
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
*   **Services**: Parses `systemctl list-unit-files` for all `enabled` or `active` services.
*   **Network Connections**: Parses `ss -tupan` or fallbacks to `netstat -tupan`.
*   **Local Users**: Directly reads `/etc/passwd`.
*   **System Persistence**: Reads the raw contents of `rc.local`, `.bashrc`, `.bash_profile`, and `.ssh/authorized_keys` for all users in `/home/` and `/root/`. Parses `crontab -l` for users and dumps `/etc/cron.*` directories.
*   **Execution Evidence**: Reads `.bash_history` for all users and parses `/var/log/auth.log` or `/var/log/secure` for `sudo` command executions.
*   **Installed Software**: Uses `dpkg-query -W` (Debian/Ubuntu), `rpm -qa` (RHEL/CentOS), and `snap list`.
*   **Firewall Rules**: Checks for `ufw status`, `firewall-cmd --list-all`, or dumps raw `iptables -S`.

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
3.  **Persistence**: This string is pushed into the browser's native `localStorage.getItem('ff_flags')` array. This ensures the flags persist even if the browser is closed or the page is refreshed.
4.  **Export Engine**: The "Export Flags" logic iterates through `localStorage`, parses the stringified data back into CSV format, generates a virtual Blob URL (`URL.createObjectURL(blob)`), and dynamically clicks a hidden anchor tag to trigger the browser download of `FFS_Flagged_Items.csv`.
