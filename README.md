# Flash Forensics Scripts

A powerful, agentless Digital Forensics and Incident Response (DFIR) collection tool built entirely in PowerShell. This suite gathers critical forensic artifacts from local or remote Windows endpoints—and natively via SSH from Linux endpoints—automatically compiling them into an interactive, sleek HTML dashboard for immediate cross-platform analysis.

## Features

- **Cross-Platform & Agentless**: Collects from Windows (via WinRM `Invoke-Command` or locally) and Linux (via native `ssh.exe` pipe), requiring zero agent installations.
- **Fileless Linux Execution**: The Python payload (`Get-LinuxDFIRSystemData.py`) is piped directly into the remote Linux system's memory over SSH. No scripts are dropped to the disk of the target!
- **Interactive HTML Dashboard**: Automatically generates a dark-themed, premium HTML dashboard (`index.html`) that works completely offline with zero web server requirements. Features a collapsible sidebar to maximize screen real-estate.
- **Triage Flagging (New!)**: Easily bookmark suspicious items directly in the dashboard using the 🚩 icon on any row. Flagged items persist across sessions and are aggregated into an executive summary view, which can be instantly exported to a CSV for your final incident report.
- **Temporal Datasets**: Each run creates a timestamped dataset folder (e.g., `Host-YYYY-MM-DD_HHMMZ`), allowing you to review and compare historical captures of the same system.
- **Global Search**: Search instantly across all categories on a specific system or sweep across all collected systems globally (both latest datasets and all-time history).
- **Raw Data Export**: Also exports standard CSV files for each artifact type per machine, ideal for ingestion into SIEMs or long-term archiving.

## Artifacts Collected

For every targeted system, the script seamlessly maps cross-platform data:
- **Running Processes**: Path, ID, Command Line, etc. (Windows via WMI, Linux via `ps`).
- **Services**: Name, Status, Start Type (Windows via WMI, Linux via `systemctl/service`).
- **Scheduled Tasks**: Task Name, Command, Next Run Time (Windows Tasks, Linux Crontabs).
- **Network Connections**: Local/Remote IP and Port, State (Windows via `NetTCPConnection`, Linux via `ss/netstat`).
- **Local Users**: Username, Enabled Status, Home Dir (Windows SAM, Linux `/etc/passwd`).
- **System Persistence**: Evaluates `Run/RunOnce` keys, BITS jobs, and `BootExecute` on Windows. Evaluates bash profiles, `rc.local`, and `authorized_keys` on Linux. 
- **Startup Files**: Enumerates system and per-user Startup/autostart folders on both OSes.
- **Execution Evidence**: Top 200 Windows Prefetch files, PSReadLine PowerShell History, Linux `sudo` executions, and Linux bash history. Features a built-in Javascript parser to directly import Eric Zimmerman `PECmd` CSV exports!
- **Installed Software**: Name, Version, Publisher, Install Date (Windows via Registry).
- **Firewall Rules**: Display Name, Profile, Direction, Action (Windows).
- **RDP Connections**: Aggregates Inbound RDP (Event Logs 21, 24, 25) and Outbound RDP (Event Log 1024, Terminal Server Client Registry) providing Source/Destination IP mapping.
- **Event Logs (Windows Core Logs)**:
  - `4103`: PowerShell Module Logging
  - `4104`: PowerShell Script Block Logging
  - `4624`: Successful Logon
  - `4625`: Failed Logon
  - `4672`: Special Privileges Assigned (e.g., Admin logon)
  - `4688`: Process Creation
  - `4697`, `7045`: Service Installation
  - `4698`, `4702`: Scheduled Task Created / Updated
  - `4720`, `4722`, `4738`: User Account Created / Enabled / Modified

## Prerequisites

- **Windows Targets**: PowerShell 5.1+ and Administrative Privileges.
- **Linux Targets**: Python 3 installed on the target, and SSH access.
- **Host System**: Windows 10/11 with the native OpenSSH client (`ssh.exe`) installed (built-in by default).

## Usage

### 1. Local Windows Collection
To run a collection on your current Windows machine, simply execute the orchestrator script:
```powershell
# Must be run As Administrator
.\Invoke-DFIRCollection.ps1
```

### 2. Remote Windows Collection
Pass an array of computer names to the `-ComputerName` parameter, or provide a CSV file using `-ComputerCsvPath` (the CSV must have a `ComputerName` column). WinRM must be enabled on the targets.
```powershell
# Remote collection using current user context
.\Invoke-DFIRCollection.ps1 -ComputerName "WIN-SRV01", "WIN-SRV02"

# Remote collection using a CSV file (Requires a 'ComputerName' header)
.\Invoke-DFIRCollection.ps1 -ComputerCsvPath "C:\temp\servers.csv"

# Remote collection with explicit credentials
$cred = Get-Credential
.\Invoke-DFIRCollection.ps1 -ComputerName "WIN-SRV01" -Credential $cred

# Prompt for credentials dynamically
.\Invoke-DFIRCollection.ps1 -ComputerName "WIN-SRV01" -PromptCredential

# Append custom event codes to the collection (e.g., Windows Defender logs)
.\Invoke-DFIRCollection.ps1 -AdditionalEventCodes @(1116, 1117, 5001)
```

### 3. Remote Linux Collection (SSH)
Use the `-OS Linux` flag and provide the SSH username. If you aren't using SSH keys, the native Windows SSH client will securely prompt you for the password in the console.
```powershell
# Remote Linux collection using password prompt or SSH keys
.\Invoke-DFIRCollection.ps1 -OS Linux -ComputerName "172.24.190.155" -SSHUsername "kali"

# Bulk Linux collection using a CSV file
.\Invoke-DFIRCollection.ps1 -OS Linux -ComputerCsvPath "C:\temp\linux_servers.csv" -SSHUsername "root"
```
*(Note: Because of the security architecture of the native Windows SSH client, you must run this interactively in your console if a password is required. For bulk collections, SSH keys are highly recommended to prevent constant password prompting.)*

## Viewing the Results

Every time you run a collection, the data is intelligently appended into your dashboard without overwriting previous hosts. Collections on the same host append a new timestamped dataset.

1. Navigate to the `FlashForensics_Output` folder.
2. Double-click **`index.html`** to open it in your default web browser.
3. Select any Windows or Linux dataset from the left sidebar to view its artifacts. The sidebar can be collapsed via the `☰` icon to maximize table space.

## Directory Structure

```text
📁 FlashForensics_Output\
 ├── 📄 index.html             (The interactive dashboard)
 ├── 📄 data.js                (The JSON payload containing all system data)
 └── 📁 <ComputerName>-<YYYY-MM-DD_HHMMZ>\  (Timestamped folder for each scanned system)
     ├── 📄 <ComputerName>-Processes.csv
     ├── 📄 <ComputerName>-Services.csv
     ├── 📄 <ComputerName>-ScheduledTasks.csv
     ├── 📄 <ComputerName>-NetworkConnections.csv
     ├── 📄 <ComputerName>-LocalUsers.csv
     ├── 📄 <ComputerName>-SystemPersistence.csv
     ├── 📄 <ComputerName>-StartupFiles.csv
     └── 📄 <ComputerName>-EventLogs.csv
```

## Dashboard Data Grouping

Several tabs in the dashboard intelligently merge data from multiple sources. For example:
- **Execution Evidence** groups artifacts by *Source* (e.g., Windows Prefetch, PowerShell History, Linux Bash History). 
- **Users** groups accounts into *Local Users* and *Privileged Access*.
- **System Persistence** groups by artifacts like *Registry Run Keys* or *BITS Transfers*.

Each data source is presented in its own distinct, collapsible section. You can simply click on the section header to cleanly expand or collapse that specific dataset.

## Global Search & Advanced Filtering

The dashboard features a robust query engine that supports logical operators across both Global Search and Column Filters.

### Supported Operators
You can build complex, multi-layered queries by combining terms with operators:
- **AND / Space**: Requires both terms to be present (e.g., `svchost AND system`, `svchost & system`, or `svchost system`).
- **OR**: Requires at least one term to be present (e.g., `chrome OR firefox`, `chrome, firefox`).
- **NOT**: Excludes rows containing the term (e.g., `svchost AND NOT local`, `svchost & !local`).

*Note: You can type the capitalized words (`AND`, `OR`, `NOT`) directly into the search boxes, or use their symbolic equivalents (`&`, `,`, `!`).*

### Global Search Engine (Top Right)
By default, the global search box sweeps across **all** categories on the currently selected dataset, treating each row as a single document.
- **Search Latest (All Systems)**: Performs a cross-system hunt across the most recent dataset for every collected machine.
- **Search All Datasets (All Time)**: Performs a historical hunt across every single dataset ever collected.

### Advanced Column Filters
Every column header in the data tables has a built-in filter text box with an advanced **Filter Builder**.
- Clicking the `▼` icon next to any column filter opens the Filter Builder dropdown.
- This dropdown acts as a quick-select menu to automatically inject **AND**, **OR**, and **NOT** conditions into your current column filter.
