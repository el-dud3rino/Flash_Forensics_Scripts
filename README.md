# Flash Forensics Scripts

An agentless Digital Forensics and Incident Response (DFIR) collection tool built entirely in PowerShell. This suite gathers forensic artifacts from local or remote Windows endpoints—and natively via SSH from Linux endpoints—compiling them into an HTML dashboard for cross-platform analysis.

## Features

- **Cross-Platform & Agentless**: Collects from Windows (via WinRM `Invoke-Command` or locally) and Linux (via native `ssh.exe` pipe), requiring zero agent installations.
- **Concurrent Execution**: Deploys payloads across multiple systems in parallel utilizing PowerShell background jobs (`Start-Job`) for lightning fast collections.
- **Fileless Linux Execution**: The Python payload (`Get-LinuxDFIRSystemData.py`) is piped directly into the remote Linux system's memory over SSH. No scripts are dropped to the disk of the target!
- **Interactive HTML Dashboard**: Automatically generates an HTML dashboard (`index.html`) that works completely offline without a web server. Features a collapsible sidebar to maximize screen real-estate.
- **Smart Temporal Filtering**: Automatically scales data collection windows (e.g., pulling 5 days of event logs/execution evidence for a new host, but only 2 days for previously scanned hosts) to drastically reduce collection time and duplicate data.
- **Analyst Collection Log**: Automatically maintains a timestamped CSV log (`Analyst_Collection_Log_YYYY-MM-DD.csv`) mapping hostnames, OS types, execution duration, and statuses.
- **Triage Flagging & Analyst Notes**: Bookmark suspicious items directly in the dashboard using the 🚩 icon on any row. Flagged items persist across sessions. The Flagged Items tab includes an editable **Analyst Notes** column that saves your notes locally. You can export the flagged items and your notes to a CSV for incident reports.
- **Dynamic UI**: Resizable table columns that persist across tab switches and pagination, plus a **Columns** button to show/hide individual columns per tab — each tab remembers its own hidden columns across navigation.
- **Compare Mode (All Hosts)**: Toggle "Compare Mode" in the sidebar to stack data across multiple systems. The dashboard filters out ephemeral noise (like PIDs and Timestamps) to group identical artifacts across systems. Items are automatically sorted by frequency, sorting unique outliers to the top.
- **Dataset Diff Mode (Single Host)**: Compare changes on a single machine between multiple timelines. Click "Diff Timelines" when viewing a host to select a Base and Target dataset. The dashboard computes the differences, highlighting new items in green (Added) and missing items in red (Removed).
- **Temporal Datasets**: Each run creates a timestamped dataset folder (e.g., `Host-YYYY-MM-DD_HHMMZ`), allowing you to review and compare historical captures of the same system.
- **Global Search**: Search across all categories on a specific system or sweep across all collected systems globally (both latest datasets and all-time history).
- **Raw Data Export**: Exports standard CSV files for each artifact type per machine for ingestion into SIEMs or long-term archiving.
- **Ask AI (Optional)**: An opt-in **🤖 Ask AI** popover (top-bar button) answers natural-language questions about the collected data using **your own** AI provider — Anthropic Claude, OpenAI, Google Gemini, or a **GenAI.mil**/custom OpenAI-compatible gateway. It is the only feature that makes a network call. See **[AI Assistant (Ask AI)](#ai-assistant-ask-ai)** below for setup, context scopes, and the local proxy for gateways like GenAI.mil.

## Artifacts Collected

For every targeted system, the script maps cross-platform data:
- **Running Processes**: Path, ID, Command Line, SHA256, Signer, etc. (Windows via WMI, Linux via `ps`). Windows binaries carrying a **Mark-of-the-Web** (downloaded from the internet) surface `Origin` and `DownloadZone` columns.
- **Services**: Name, Status, Start Type (Windows via WMI, Linux via `systemctl/service`).
- **Scheduled Tasks**: Task Name, Command, Next Run Time (Windows Tasks, Linux Crontabs).
- **Network Connections**: Local/Remote IP and Port, State (Windows via `NetTCPConnection`, Linux via `ss/netstat`).
- **ARP Table**: Local ARP cache mapping IP addresses to MAC addresses (Windows via `Get-NetNeighbor`, Linux via `ip neigh/arp`).
- **Local Users**: Username, Enabled Status, Home Dir (Windows SAM, Linux `/etc/passwd`).
- **Privileged Access**: Members of high-privileged groups and configuration (Windows Administrators/RDP Users, Linux sudo/wheel groups and sudoers).
- **Active Logged In Users**: Current interactive, RDP, and SSH sessions (Windows via `quser`, Linux via `who`).
- **System Persistence**: Evaluates `Run/RunOnce` keys, BITS jobs, `BootExecute`, **Image File Execution Options debuggers / SilentProcessExit**, **AppInit_DLLs**, and **Winlogon Notify** packages on Windows. Evaluates bash profiles, `rc.local`, and `authorized_keys` on Linux. 
- **USB History**: Historical USB device connections (Windows via Registry USBSTOR).
- **Startup Files**: Enumerates system and per-user Startup/autostart folders on both OSes.
- **Execution Evidence**: Tracks lateral movement and program execution by parsing Windows Prefetch metadata, BAM (Background Activity Moderator), UserAssist (with ROT13 decode), JumpLists, ShimCache, Amcache, SRUM metadata, PSReadLine PowerShell History, Linux `sudo` executions, and Linux bash history. Features a built-in Javascript parser to directly import Eric Zimmerman `PECmd` CSV exports!
- **Recycle Bin**: Parses Windows binary `$I` files across all SIDs and Linux `.trashinfo` files to reconstruct deleted files and deletion timestamps.
- **Installed Software**: Name, Version, Publisher, Install Date (Windows via Registry, Linux via dpkg/rpm/snap).
- **Firewall Rules**: Technical properties including local/remote IPs, Ports, Programs, Action and Direction (Windows via netsh, Linux via ufw/firewalld/iptables).
- **Loaded Drivers**: Enumerates loaded kernel drivers with image path, state, and signature verdict (Windows via `Win32_SystemDriver`) — surfacing unsigned/unverified drivers for rootkit hunting.
- **Microsoft Defender**: Antivirus exclusions (path/process/extension/IP), real-time protection and tamper-protection status, and threat detection history (Windows via `Get-MpPreference`, `Get-MpComputerStatus`, `Get-MpThreat`).
- **RDP Connections**: Aggregates Inbound RDP (Event Logs 21, 24, 25) and Outbound RDP (Event Log 1024, Terminal Server Client Registry) providing Source/Destination IP mapping.
- **Docker Containers**: Running images, container state, and network port mappings (Windows and Linux).
- **DNS Configuration & Cache**: Local DNS cache entries and resolver configurations.
- **SMB Sessions & Shares**: Active inbound SMB network sessions and configured SMB shares (Windows).
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
Pass an array of computer names to the `-ComputerName` parameter, or provide a CSV file using `-ComputerCsvPath`. WinRM must be enabled on the targets.
*(Note: The CSV file must contain a `ComputerName` header, with each computer name on its own new line, e.g., `ComputerName\nWIN-SRV01\nWIN-SRV02`)*
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

### 4. Build Dashboard from Existing Files
If you have a folder full of `*-DFIR_Data.json` files collected previously (or provided by another analyst), you can compile them into a unified dashboard without re-running any data collection against remote endpoints.
```powershell
.\Invoke-DFIRCollection.ps1 -BuildDashboardOnly
```

## Viewing the Results

Every time you run a collection, the data is appended into your dashboard without overwriting previous hosts. Collections on the same host append a new timestamped dataset.

1. Double-click **`index.html`** in the root directory to open it in your default web browser.
2. Select any Windows or Linux dataset from the left sidebar to view its artifacts. The sidebar can be collapsed via the `☰` icon to maximize table space.

### Timeline Diffing (Historical Comparison)
If you run the collection script on the same system multiple times, the dashboard automatically stacks your datasets. You can compare changes over time using the built-in diff engine:
1. Select a host that has multiple historical datasets.
2. Click the **Diff Timelines** button that appears in the top navigation bar.
3. Select a **Base** (older) dataset and a **Target** (newer) dataset.
4. The dashboard will automatically compare the two datasets and inject a **Diff** column into the tables. This allows you to see which artifacts were `+ Added`, `- Removed`, or `Unchanged`. You can also filter directly on these statuses using the column dropdown!

## Showing & Hiding Columns

Every data tab has a **Columns** button in the top bar. Click it to open a checklist of that tab's columns — untick a column to hide it, tick it to bring it back, or use **Show all**. Hidden columns are remembered **per tab** and persist as you navigate: hiding `ProcessId` on the Processes tab does not hide it on other tabs, and your choices survive switching tabs and reopening the dashboard (they are stored in your browser).

## AI Assistant (Ask AI)

The dashboard includes an optional, provider-agnostic AI assistant for asking natural-language questions about the collected data (e.g. *"Which running processes are unsigned or downloaded from the internet?"* or *"What persistence looks suspicious on this host?"*). Click the **🤖 Ask AI** button in the top bar to open it as a popover over the current tab.

> **This is the only feature that reaches the network.** A question sends the selected slice of forensic data to whatever endpoint you configure, so only point it at an endpoint approved for that data. Your API key is stored **only in your browser** (`localStorage`) — never written to `index.html`/`data.js` and never committed.

### Supported providers

| Provider | Notes |
|----------|-------|
| **Anthropic (Claude)** | Native API. Works directly from the browser. |
| **OpenAI** | Works directly from the browser. |
| **Google Gemini** | Uses Gemini's OpenAI-compatible endpoint. Works directly. |
| **GenAI.mil (DoD gateway)** | Endpoint prefilled. Requires the **local proxy** (see below) because it does not send CORS headers. |
| **Custom (OpenAI-compatible)** | Paste any OpenAI-compatible Base URL. |

### Quick start

1. Click **🤖 Ask AI**, expand **AI Settings**.
2. Pick a **Provider** (this prefills the Base URL and a default model). For GenAI.mil or a custom gateway, confirm/paste the exact Base URL.
3. Paste your **API key** and click **Save**. (Optional: click **Load models** to query `GET /v1/models` and pick the exact model from the list — handy for GenAI.mil, which fronts OpenAI, Gemini, and Grok models.)
4. Choose the **Context sent** scope, type a question, and press **Ask** (or Ctrl/Cmd+Enter).

### Context scopes

Because the assistant overlays the tab you are viewing, the "current tab" scope reflects what you are actually looking at. Five levels are available:

- **Current host + current tab** — a minimal slice of the selected dataset (one host, one category).
- **Current host + current tab (all timelines)** — that tab's data from every temporal capture of the host, each tagged with its timestamp (great for *"what changed on this tab over time"*).
- **Current host, all categories** — the entire selected dataset.
- **Current host, all categories (all timelines)** — every dataset of the host, in full.
- **Everything loaded (all hosts)** — all datasets for all hosts.

A live size readout (approx. characters / tokens) is shown, with a warning past ~500K characters, so nothing is sent silently.

### Using the local proxy (for GenAI.mil / gateways without CORS)

Some gateways — notably **GenAI.mil** — do not return the CORS headers a browser requires, so the browser blocks the response no matter where you run from. The fix is a small local proxy that serves the dashboard and relays your API calls server-to-server (where CORS does not apply). Two equivalent versions ship in `tools/` — use whichever your system has:

**PowerShell (no Python required):**
```powershell
# Run from the repository root, in the same elevated PowerShell you use for collection
.\tools\ff-ai-proxy.ps1
```

**Python:**
```powershell
python tools/ff-ai-proxy.py
```

Then:

1. Open the `http://localhost:8000/` URL the proxy prints (use `http://localhost:8000/example/` for the sample dataset).
2. In **AI Settings**, tick **"Route through local proxy"**.
3. Select **GenAI.mil**, paste your key, and ask as normal.

Notes:
- Anthropic, OpenAI, and Gemini work **without** the proxy — leave the box unticked for those.
- Your key still lives only in the browser; it passes through the local proxy exactly as it would going direct. Nothing is stored or logged.
- Both the chat and **Load models** requests route through the proxy when the box is ticked.
- If your network performs TLS inspection and the proxy cannot validate the gateway's certificate, run it with `-Insecure` (PowerShell) or `--insecure` (Python).
- Change the port with `-Port 8080` / `--port 8080` if 8000 is taken.

### GenAI.mil key locking

GenAI.mil automatically **locks API keys every 8 hours**. When locked, a request returns `401` with an unlock URL. The dashboard detects this and shows an **🔓 Unlock key** link plus a **Retry** button — click the link to re-enable your key (or unlock it from the GenAI.mil web UI), then click **Retry** to re-send your question.

## Directory Structure

```text
📁 flash-forensics-scripts\
 ├── 📄 index.html             (The interactive dashboard)
 ├── 📄 data.js                (The JSON payload containing all system data)
 ├── 📄 Invoke-DFIRCollection.ps1
 ├── 📄 Architecture.md        (Technical Deep Dive)
 ├── 📁 collection-scripts\    (Payloads deployed to endpoints)
 ├── 📁 playbook\              (Documentation and playbooks)
 ├── 📁 tools\                 (ff-ai-proxy.ps1 / ff-ai-proxy.py - local AI proxy)
 ├── 📁 example\               (Self-contained synthetic sample dashboard)
 └── 📁 FlashForensics_Output\ 
     └── 📁 <ComputerName>-<YYYY-MM-DD_HHMMZ>\  (Timestamped folder for each scanned system)
         ├── 📄 <ComputerName>-DFIR_Data.json
         ├── 📄 <ComputerName>-Processes.csv
         ├── 📄 <ComputerName>-Services.csv
         ├── 📄 <ComputerName>-ScheduledTasks.csv
         ├── 📄 <ComputerName>-NetworkConnections.csv
         ├── 📄 <ComputerName>-LocalUsers.csv
         ├── 📄 <ComputerName>-SystemPersistence.csv
         ├── 📄 <ComputerName>-StartupFiles.csv
         ├── 📄 <ComputerName>-RecycleBin.csv
         └── 📄 <ComputerName>-EventLogs.csv
```

## Dashboard Data Grouping

Several tabs in the dashboard merge data from multiple sources. For example:
- **Execution Evidence** groups artifacts by *Source* (e.g., Windows Prefetch, PowerShell History, Linux Bash History). 
- **Users** groups accounts into *Local Users* and *Privileged Access*.
- **System Persistence** groups by artifacts like *Registry Run Keys* or *BITS Transfers*.
- **Event Logs** groups natively by *Event ID* and injects descriptive names (e.g., Successful Logon, Process Creation) directly into the section headers.

Each data source is presented in its own distinct, collapsible section. You can click on the section header to expand or collapse that specific dataset.

## Global Search & Advanced Filtering

The dashboard features a query engine that supports logical operators across both Global Search and Column Filters.

### Supported Operators
You can build complex queries by combining terms with operators:
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
