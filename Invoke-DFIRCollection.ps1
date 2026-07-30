<#
.SYNOPSIS
    Orchestrates the execution of a DFIR collection script across remote systems.
.DESCRIPTION
    Uses Invoke-Command to run Get-DFIRSystemData.ps1 on one or more target computers.
    Exports the collected data into separate JSON and CSV files within the specified output directory.
.PARAMETER ComputerName
    An array of computer names to collect data from.
.PARAMETER OutputDirectory
    The directory where output files will be saved. Defaults to ".\FlashForensics_Output".
.PARAMETER Credential
    Optional credentials to use for the remote connection.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory=$false)]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter(Mandatory=$false, HelpMessage="Path to a CSV file containing a 'ComputerName' column.")]
    [string]$ComputerCsvPath,

    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = ".\FlashForensics_Output",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Windows", "Linux")]
    [string]$OS = "Windows",

    [Parameter(Mandatory=$false)]
    [string]$SSHUsername = "",

    [Parameter(Mandatory=$false)]
    [pscredential]$Credential,

    [Parameter(Mandatory=$false)]
    [switch]$PromptCredential,

    [Parameter(Mandatory=$false)]
    [switch]$BuildDashboardOnly,

    [Parameter(Mandatory=$false)]
    [int[]]$AdditionalEventCodes = @()
)

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    Write-Output "Created output directory: $OutputDirectory"
}

if ($ComputerCsvPath) {
    if (Test-Path $ComputerCsvPath) {
        try {
            $csvData = Import-Csv $ComputerCsvPath
            if ($csvData[0].psobject.properties.match('ComputerName').Count -gt 0) {
                # Ensure it's an array so we can add to it, since default might be a single string if not overridden
                $ComputerName = @($ComputerName) + @($csvData.ComputerName)
                # Remove localhost if it's there by default and we added from CSV
                if ($ComputerName[0] -eq $env:COMPUTERNAME -and $ComputerName.Count -gt 1) {
                    $ComputerName = $ComputerName | Where-Object { $_ -ne $env:COMPUTERNAME }
                }
            } else {
                Write-Warning "The provided CSV does not contain a 'ComputerName' column. Ignoring CSV."
            }
        } catch {
            Write-Warning "Failed to import CSV from $($ComputerCsvPath): $_"
        }
    } else {
        Write-Warning "Could not find CSV file at $ComputerCsvPath"
    }
}

$Results = @()

if ($BuildDashboardOnly) {
    Write-Output "BuildDashboardOnly switch provided. Skipping remote data collection."
    Write-Output "Scanning $OutputDirectory for existing DFIR_Data.json files..."
    $ExistingJsonFiles = Get-ChildItem -Path $OutputDirectory -Filter "*-DFIR_Data.json" -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $ExistingJsonFiles) {
        try {
            $RawJson = Get-Content $file.FullName -Raw
            $RawJson = $RawJson -creplace '"value"\s*:', '"value_enum":'
            $Parsed = $RawJson | ConvertFrom-Json
            if ($Parsed) {
                $Results += $Parsed
            }
        } catch {
            Write-Warning "Failed to parse $($file.FullName): $_"
        }
    }
    Write-Output "Loaded $(($Results).Count) existing records from disk."
} else {

if ($OS -eq "Windows") {
    $PayloadScript = Join-Path -Path $PSScriptRoot -ChildPath "Get-DFIRSystemData.ps1"
    if (-not (Test-Path $PayloadScript)) {
        Write-Error "Could not find payload script at $PayloadScript. Please ensure Get-DFIRSystemData.ps1 is in the same directory as this script."
        exit
    }

    if ($PromptCredential) {
        $Credential = Get-Credential
    }

    $RemoteComputers = @()

    foreach ($Comp in $ComputerName) {
        if ($Comp -eq "localhost" -or $Comp -eq "127.0.0.1" -or $Comp -eq $env:COMPUTERNAME -or $Comp -eq '.') {
            Write-Output "Starting local DFIR collection on $($env:COMPUTERNAME)..."
            $LocalResult = & $PayloadScript -AdditionalEventCodes $AdditionalEventCodes
            if ($LocalResult) {
                $LocalResult | Add-Member -MemberType NoteProperty -Name PSComputerName -Value $env:COMPUTERNAME -Force
                $Results += $LocalResult
            }
        } else {
            $RemoteComputers += $Comp
        }
    }

    if ($RemoteComputers.Count -gt 0) {
        $InvokeParams = @{
            ComputerName = $RemoteComputers
            FilePath = $PayloadScript
            ArgumentList = (, $AdditionalEventCodes)
            ErrorAction = 'SilentlyContinue'
            ErrorVariable = 'InvokeErrors'
        }
        if ($Credential) {
            $InvokeParams.Credential = $Credential
        }

        Write-Output "Starting DFIR collection on $(($RemoteComputers).Count) remote systems..."
        $RemoteResults = Invoke-Command @InvokeParams
        
        $SuccessfulComps = @()
        if ($RemoteResults) {
            $Results += $RemoteResults
            $SuccessfulComps = $RemoteResults | Select-Object -ExpandProperty PSComputerName -Unique
        }
        
        $FailedComps = $RemoteComputers | Where-Object { $_ -notin $SuccessfulComps }
        if ($FailedComps.Count -gt 0) {
            Write-Warning "Collection failed on the following remote systems: $($FailedComps -join ', ')"
            if ($InvokeErrors) {
                Write-Warning "Connection Error Details:"
                foreach ($err in $InvokeErrors) {
                    Write-Warning " - $($err.TargetObject): $($err.Exception.Message)"
                }
            }
        }
    }
} elseif ($OS -eq "Linux") {
    $PayloadScript = Join-Path $PSScriptRoot "Get-LinuxDFIRSystemData.py"
    if (-not (Test-Path $PayloadScript)) {
        Write-Error "Could not find payload script at $PayloadScript"
        exit
    }
    
    if (-not $SSHUsername) {
        Write-Error "SSHUsername is required when OS is Linux"
        exit
    }

    Write-Output "If you are not using SSH keys, you will be prompted for passwords."
    foreach ($Comp in $ComputerName) {
        Write-Output "Starting Linux DFIR collection on $Comp via SSH..."
        $JsonOutput = Get-Content $PayloadScript -Raw | ssh.exe -o StrictHostKeyChecking=no -l $SSHUsername $Comp "python3 -"
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "SSH connection to $Comp failed (Exit Code: $LASTEXITCODE). Ensure SSH is running, credentials/keys are valid, and Python3 is installed."
            continue
        }
        
        if ([string]::IsNullOrWhiteSpace($JsonOutput)) {
            Write-Warning "No output from $Comp. Script execution may have failed."
            continue
        }
        try {
            $LinuxData = $JsonOutput | ConvertFrom-Json
            # Add PSComputerName for consistency
            $LinuxData | Add-Member -MemberType NoteProperty -Name PSComputerName -Value $Comp -Force
            $Results += $LinuxData
        } catch {
            Write-Warning "Failed to parse JSON output from $Comp."
        }
    }
}

foreach ($Result in $Results) {
    $TargetName = $Result.ComputerName
    if (-not $TargetName) {
        # Fallback if ComputerName property is missing for some reason
        $TargetName = $Result.PSComputerName
    }
    
    if ($Result.Timestamp -match '(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})') {
        $RunTime = "$($Matches[1])_$($Matches[2])$($Matches[3])Z"
    } else {
        $RunTime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd_HHmm\Z")
    }
    $SystemOutputDir = Join-Path -Path $OutputDirectory -ChildPath "$TargetName-$RunTime"
    if (-not (Test-Path -Path $SystemOutputDir)) {
        New-Item -ItemType Directory -Path $SystemOutputDir | Out-Null
    }

    Write-Output "Processing results for $TargetName..."

    # Export to JSON
    $JsonPath = Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-DFIR_Data.json"
    $Result | ConvertTo-Json -Depth 5 | Out-File -FilePath $JsonPath -Encoding UTF8

    # Export individual categories to CSV
    if ($Result.Processes) {
        $Result.Processes | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-Processes.csv") -NoTypeInformation
    }
    if ($Result.Services) {
        $Result.Services | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-Services.csv") -NoTypeInformation
    }
    if ($Result.ScheduledTasks) {
        $Result.ScheduledTasks | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-ScheduledTasks.csv") -NoTypeInformation
    }
    if ($Result.NetworkConnections) {
        $Result.NetworkConnections | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-NetworkConnections.csv") -NoTypeInformation
    }
    if ($Result.LocalUsers) {
        $Result.LocalUsers | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-LocalUsers.csv") -NoTypeInformation
    }
    if ($Result.SystemPersistence) {
        $Result.SystemPersistence | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-SystemPersistence.csv") -NoTypeInformation
    }
    if ($Result.StartupFiles) {
        $Result.StartupFiles | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-StartupFiles.csv") -NoTypeInformation
    }
    if ($Result.EventLogs) {
        $Result.EventLogs | Export-Csv -Path (Join-Path -Path $SystemOutputDir -ChildPath "$TargetName-EventLogs.csv") -NoTypeInformation
    }
}
}

Write-Output "Generating HTML Dashboard..."

# Export all results to data.js for HTML dashboard
$DataJsPath = Join-Path -Path $OutputDirectory -ChildPath "data.js"
$ExistingData = New-Object System.Collections.ArrayList

if (Test-Path $DataJsPath) {
    $FileContent = Get-Content $DataJsPath -Raw
    $JsonString = $FileContent -replace '^const dfirData = ', '' -replace ';\s*$', ''
    # PowerShell 7's ConvertFrom-Json fails if an object has duplicate case-insensitive keys (like {"value": 1, "Value": "One"}).
    # This happens due to PowerShell 5.1's Enum serialization. We sanitize it here before parsing to recover historical datasets.
    $JsonString = $JsonString -creplace '"value"\s*:', '"value_enum":'
    try {
        $Parsed = $JsonString | ConvertFrom-Json
        if ($Parsed) {
            foreach ($item in @($Parsed)) {
                $ExistingData.Add($item) | Out-Null
            }
        }
    } catch {
        Write-Warning "Failed to parse existing data.js. Overwriting with new data. $_"
    }
}

foreach ($Res in $Results) {
    $SysName = if ($Res.ComputerName) { $Res.ComputerName } else { $Res.PSComputerName }
    $ExistingIndex = -1
    for ($i = 0; $i -lt $ExistingData.Count; $i++) {
        $checkName = if ($ExistingData[$i].ComputerName) { $ExistingData[$i].ComputerName } else { $ExistingData[$i].PSComputerName }
        $checkTime = $ExistingData[$i].Timestamp
        if ($checkName -eq $SysName -and $checkTime -eq $Res.Timestamp) {
            $ExistingIndex = $i
            break
        }
    }
    if ($ExistingIndex -ge 0) {
        $ExistingData[$ExistingIndex] = $Res
    } else {
        $ExistingData.Add($Res) | Out-Null
    }
}

$CombinedJson = ConvertTo-Json -InputObject @($ExistingData) -Depth 10 -Compress
"const dfirData = $CombinedJson;" | Out-File -FilePath $DataJsPath -Encoding UTF8

# Generate HTML Dashboard
$HtmlPath = Join-Path -Path $OutputDirectory -ChildPath "index.html"
$HtmlContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FFS Dashboard</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: #0f172a;
            --glass-bg: rgba(30, 41, 59, 0.7);
            --glass-border: rgba(255, 255, 255, 0.1);
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --accent: #3b82f6;
            --accent-hover: #60a5fa;
            --danger: #ef4444;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        html { font-size: 14px; }
        body {
            font-family: 'Inter', sans-serif;
            background: linear-gradient(135deg, #020617, #0f172a);
            color: var(--text-main);
            height: 100vh;
            margin: 0;
            display: flex;
            overflow: hidden;
        }
        /* Sidebar */
        #sidebar {
            width: 220px;
            background: var(--glass-bg);
            backdrop-filter: blur(12px);
            border-right: 1px solid var(--glass-border);
            display: flex;
            flex-direction: column;
            padding: 15px 0;
            z-index: 10;
            transition: width 0.3s ease, opacity 0.3s ease;
            overflow-x: hidden;
            white-space: nowrap;
        }
        #sidebar.collapsed {
            width: 0;
            border-right: none;
            opacity: 0;
            padding: 0;
        }
        .brand {
            padding: 0 15px 15px;
            font-size: 1.2rem;
            font-weight: 700;
            color: var(--accent-hover);
            border-bottom: 1px solid var(--glass-border);
            margin-bottom: 5px;
        }
        .computer-list {
            list-style: none;
            overflow-y: auto;
            flex: 1;
        }
        .computer-item {
            padding: 8px 15px;
            cursor: pointer;
            transition: all 0.2s;
            color: var(--text-muted);
            font-weight: 600;
        }
        .computer-item:hover {
            background: rgba(255,255,255,0.05);
            color: var(--text-main);
        }
        .computer-item.active {
            background: rgba(59, 130, 246, 0.15);
            color: var(--accent-hover);
            border-right: 3px solid var(--accent);
        }
        
        /* Main Content */
        #main {
            flex: 1;
            display: flex;
            flex-direction: column;
            overflow: hidden;
            position: relative;
        }
        .header {
            padding: 12px 20px;
            background: var(--glass-bg);
            backdrop-filter: blur(12px);
            border-bottom: 1px solid var(--glass-border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .header-title h1 { font-size: 1.3rem; font-weight: 600; margin-bottom: 2px; }
        
        .search-container input[type="text"] {
            background: rgba(0,0,0,0.2);
            border: 1px solid var(--glass-border);
            color: var(--text-main);
            padding: 10px 15px;
            border-radius: 6px;
            font-family: inherit;
            font-size: 0.9rem;
            outline: none;
            width: 300px;
            transition: all 0.2s;
        }
        .search-container input[type="text"]:focus {
            border-color: var(--accent);
            background: rgba(0,0,0,0.4);
            box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.2);
        }
        
        /* Tabs */
        .tabs {
            display: flex;
            background: rgba(15, 23, 42, 0.8);
            border-bottom: 1px solid var(--glass-border);
            padding: 0 20px;
            overflow-x: auto;
        }
        .tab {
            padding: 10px 15px;
            cursor: pointer;
            color: var(--text-muted);
            font-weight: 600;
            border-bottom: 2px solid transparent;
            transition: all 0.2s;
            white-space: nowrap;
        }
        .tab:hover { color: var(--text-main); }
        .tab.active {
            color: var(--accent-hover);
            border-bottom-color: var(--accent);
        }
        
        /* Content Area */
        .content-area {
            flex: 1;
            padding: 15px;
            display: flex;
            flex-direction: column;
            min-height: 0;
        }
        .glass-panel {
            background: var(--glass-bg);
            backdrop-filter: blur(16px);
            border: 1px solid var(--glass-border);
            border-radius: 12px;
            padding: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.3);
            animation: fadeIn 0.4s ease-out;
            display: flex;
            flex-direction: column;
            flex: 1;
            min-height: 0;
        }
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(10px); }
            to { opacity: 1; transform: translateY(0); }
        }
        
        /* Table */
        .table-container {
            overflow: auto;
            flex: 1;
            min-height: 0;
            width: 100%;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            text-align: left;
        }
        th {
            background: rgba(0,0,0,0.2);
            padding: 8px 10px;
            font-weight: 600;
            color: var(--text-muted);
            text-transform: uppercase;
            font-size: 0.75rem;
            letter-spacing: 0.05em;
            border-bottom: 1px solid var(--glass-border);
            position: sticky;
            top: 0;
            z-index: 10;
        }
        td {
            padding: 8px 10px;
            border-bottom: 1px solid var(--glass-border);
            color: var(--text-muted);
            max-width: 350px;
            cursor: pointer;
            vertical-align: top;
        }
        .td-content {
            display: -webkit-box;
            -webkit-line-clamp: 2;
            -webkit-box-orient: vertical;
            overflow: hidden;
            white-space: normal;
            word-break: break-word;
        }
        .flag-btn {
            background: none;
            border: none;
            color: var(--text-muted);
            cursor: pointer;
            font-size: 1.1rem;
            transition: transform 0.2s, color 0.2s;
            padding: 0;
            margin-right: 5px;
        }
        .flag-btn:hover {
            transform: scale(1.2);
            color: var(--accent);
        }
        .flag-btn.flagged {
            color: var(--danger);
        }
        td:hover {
            background: rgba(255,255,255,0.05);
        }
        tr:hover td {
            background: rgba(255,255,255,0.03);
            color: var(--text-main);
        }
        
        /* Cell Modal */
        #cellModalOverlay {
            display: none;
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            background: rgba(0,0,0,0.5);
            backdrop-filter: blur(4px);
            z-index: 999;
            align-items: center;
            justify-content: center;
        }
        #cellModal {
            background: var(--glass-bg);
            border: 1px solid var(--glass-border);
            border-radius: 12px;
            padding: 30px;
            max-width: 80%;
            max-height: 80%;
            overflow: auto;
            box-shadow: 0 10px 40px rgba(0,0,0,0.5);
            position: relative;
        }
        #cellModalClose {
            position: absolute;
            top: 15px;
            right: 20px;
            cursor: pointer;
            font-size: 1.5rem;
            color: var(--text-muted);
            line-height: 1;
        }
        #cellModalClose:hover { color: var(--text-main); }
        #cellModalContent {
            white-space: pre-wrap;
            word-break: break-word;
            color: var(--text-main);
            font-family: 'Inter', sans-serif;
            font-size: 0.9rem;
            margin-top: 5px;
        }
        .empty-state {
            padding: 40px;
            text-align: center;
            color: var(--text-muted);
            font-size: 1.1rem;
        }
        .column-filter {
            width: 100%;
            padding: 4px;
            box-sizing: border-box;
            margin-top: 5px;
            background: rgba(0,0,0,0.3);
            border: 1px solid var(--glass-border);
            color: white;
            font-size: 0.8rem;
            border-radius: 4px;
        }
        .sortable-header {
            cursor: pointer;
            user-select: none;
        }
        .sortable-header:hover {
            color: var(--accent);
        }
        .null-val { color: var(--text-muted); font-style: italic; }

        /* Process Tree */
        ul.process-tree {
            list-style-type: none;
            padding-left: 20px;
            margin: 0;
            font-family: 'Inter', sans-serif;
            color: var(--text-main);
        }
        ul.process-tree-root { padding-left: 0; }
        ul.process-tree li {
            margin: 5px 0;
            position: relative;
        }
        ul.process-tree:not(.process-tree-root) > li::before {
            content: '';
            position: absolute;
            top: -5px;
            left: -15px;
            border-left: 1px solid var(--glass-border);
            bottom: 50%;
            height: 100%;
        }
        ul.process-tree:not(.process-tree-root) > li::after {
            content: '';
            position: absolute;
            top: 15px;
            left: -15px;
            border-top: 1px solid var(--glass-border);
            width: 15px;
        }
        ul.process-tree:not(.process-tree-root) > li:last-child::before {
            height: 20px;
            bottom: auto;
        }
        .tree-node-content {
            display: inline-flex;
            align-items: center;
            background: rgba(0,0,0,0.3);
            border: 1px solid var(--glass-border);
            padding: 6px 12px;
            border-radius: 6px;
            font-size: 0.85rem;
            cursor: pointer;
            transition: all 0.2s;
            margin-bottom: 2px;
            flex-wrap: wrap;
            gap: 5px;
        }
        .tree-node-content:hover {
            background: rgba(255,255,255,0.05);
            border-color: var(--accent);
        }
        .tree-badge {
            display: inline-block;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.7rem;
            font-weight: 600;
            cursor: pointer;
        }
        .tree-badge.network { background: rgba(59, 130, 246, 0.2); color: #93c5fd; border: 1px solid rgba(59, 130, 246, 0.5); }
        .tree-badge.network:hover { background: rgba(59, 130, 246, 0.4); }
        .tree-badge.service { background: rgba(16, 185, 129, 0.2); color: #6ee7b7; border: 1px solid rgba(16, 185, 129, 0.5); }
        .tree-badge.service:hover { background: rgba(16, 185, 129, 0.4); }
    </style>
</head>
<body>
    <div id="cellModalOverlay" onclick="closeCellModal(event)">
        <div id="cellModal" onclick="event.stopPropagation()">
            <div id="cellModalClose" onclick="closeCellModal(event)">&times;</div>
            <div id="cellModalContent"></div>
        </div>
    </div>
    <div id="sidebar">
        <div class="brand">FFS Dashboard</div>
        
        <div style="padding: 10px; margin: 10px 0; border-bottom: 1px solid var(--glass-border);">
            <label style="display:flex; align-items:center; color: var(--text-main); font-weight: bold; cursor: pointer; font-size: 0.9rem;">
                <input type="checkbox" id="compareModeToggle" style="margin-right:8px;" onchange="toggleCompareMode(this.checked)">
                Enable Compare Mode
            </label>
            <div id="compareControls" style="display:none; margin-top:10px; flex-direction:column; gap:8px;">
                <button onclick="selectAllOS('Windows')" style="background:var(--bg-lighter); color:var(--text-main); border:1px solid var(--glass-border); padding:5px; border-radius:4px; cursor:pointer;">Select All Windows</button>
                <button onclick="selectAllOS('Linux')" style="background:var(--bg-lighter); color:var(--text-main); border:1px solid var(--glass-border); padding:5px; border-radius:4px; cursor:pointer;">Select All Linux</button>
            </div>
        </div>

        <ul class="computer-list" id="computerList"></ul>
    </div>
    <div id="main">
        <div class="header">
            <div class="header-title">
                <button onclick="toggleSidebar()" style="background:none; border:none; color:var(--text-main); cursor:pointer; font-size:1.4rem; margin-right:15px; padding: 0;">&#9776;</button>
                <h1 id="computerTitle">Select a System</h1>
                <span id="timestampBadge" style="color: var(--text-muted); font-size: 0.875rem;"></span>
            </div>
            <div class="search-container" style="display: flex; align-items: center; gap: 15px;">
                <label style="color: var(--text-muted); font-size: 0.85rem; display: flex; align-items: center; cursor: pointer; margin-right: 15px;">
                    <input type="checkbox" id="filterSigned" style="margin-right: 6px;" onchange="switchTab(currentTab)">
                    Hide Signed Binaries
                </label>
                <label style="color: var(--text-muted); font-size: 0.85rem; display: flex; align-items: center; cursor: pointer;">
                    <input type="checkbox" id="searchLatestAllSystems" style="margin-right: 6px;" onchange="handleSearch(document.getElementById('searchInput').value)">
                    Search Latest (All Systems)
                </label>
                <label style="color: var(--text-muted); font-size: 0.85rem; display: flex; align-items: center; cursor: pointer; margin-right: 10px;">
                    <input type="checkbox" id="searchAllDatasets" style="margin-right: 6px;" onchange="handleSearch(document.getElementById('searchInput').value)">
                    Search All Datasets (All Time)
                </label>
                <input type="text" id="searchInput" placeholder="Search..." oninput="handleSearch(this.value)">
            </div>
        </div>
        <div class="tabs" id="tabs">
            <div class="tab" data-tab="SystemInfo" onclick="switchTab('SystemInfo')">Sys Info</div>
            <div class="tab" data-tab="Processes" onclick="switchTab('Processes')">Processes</div>
            <div class="tab" data-tab="Services" onclick="switchTab('Services')">Services</div>
            <div class="tab" data-tab="ScheduledTasks" onclick="switchTab('ScheduledTasks')">Tasks</div>
            <div class="tab" data-tab="NetworkConnections" onclick="switchTab('NetworkConnections')">Net Conns</div>
            <div class="tab" data-tab="Users" onclick="switchTab('Users')">Users</div>
            <div class="tab" data-tab="SystemPersistence" onclick="switchTab('SystemPersistence')">Persistence</div>
            <div class="tab" data-tab="StartupFiles" onclick="switchTab('StartupFiles')">Startup</div>
            <div class="tab" data-tab="ExecutionEvidence" onclick="switchTab('ExecutionEvidence')">Exec Evidence</div>
            <div class="tab" data-tab="EventLogs" onclick="switchTab('EventLogs')">Event Logs</div>
            <div class="tab" data-tab="InstalledSoftware" onclick="switchTab('InstalledSoftware')">Software</div>
            <div class="tab" data-tab="FirewallRules" onclick="switchTab('FirewallRules')">Firewall</div>
            <div class="tab" data-tab="RDPConnections" onclick="switchTab('RDPConnections')">RDP</div>
            <div class="tab" data-tab="ProcessTree" style="background: var(--accent); color: white;" onclick="switchTab('ProcessTree')">Proc Tree</div>
            <div class="tab" data-tab="Timeline" style="background: var(--accent); color: white;" onclick="switchTab('Timeline')">Timeline</div>
            <div class="tab" data-tab="FlaggedItems" onclick="switchTab('FlaggedItems')" style="color: var(--danger); font-weight: bold;">&#128681; Flagged</div>
            <div class="tab" data-tab="SearchResults" id="tabSearchResults" style="display: none;" onclick="switchTab('SearchResults')">Search Results</div>
        </div>
        <div class="content-area">
            <div class="glass-panel">
                <div class="table-container" id="tableContainer">
                    <div class="empty-state">Please select a system from the sidebar to view data.</div>
                </div>
            </div>
        </div>
    </div>

    <!-- Load the DFIR Data generated by the PowerShell script -->
    <script src="data.js"></script>
    <script>
        function showCellModal(cell) {
            const overlay = document.getElementById('cellModalOverlay');
            const content = document.getElementById('cellModalContent');
            content.textContent = cell.innerText || cell.textContent;
            overlay.style.display = 'flex';
        }
        
        function closeCellModal(e) {
            document.getElementById('cellModalOverlay').style.display = 'none';
        }

        function toggleSidebar() {
            const sidebar = document.getElementById('sidebar');
            sidebar.classList.toggle('collapsed');
        }
        
        function toggleFilterHelp(elementId) {
            const el = document.getElementById('filterHelp-' + elementId);
            if (!el) return;
            if (el.style.display === 'none') {
                document.querySelectorAll('[id^="filterHelp-"]').forEach(e => e.style.display = 'none');
                el.style.display = 'flex';
            } else {
                el.style.display = 'none';
            }
        }
        
        function appendFilter(elementId, col, text) {
            const input = document.getElementById('filter-' + elementId);
            if (input) {
                input.value = input.value + text;
                setColumnFilter(col, input.value);
                input.focus();
            }
            const helpMenu = document.getElementById('filterHelp-' + elementId);
            if (helpMenu) {
                helpMenu.style.display = 'none';
            }
        }

        window.eventLogGroupMode = false;
        let currentComputer = null;
        let currentTab = 'SystemInfo';
        let previousTab = 'SystemInfo';
        let searchResultsData = [];
        
        // Sorting and Filtering State
        let currentSortColumn = null;
        let currentSortDirection = 'asc';
        let columnFilters = {};

        let groupedSystems = {};
        let selectedHostname = null;
        
        window.isCompareMode = false;
        window.selectedHosts = new Set();
        window.hostOSMap = {};
        window.compareGroupKeys = {};
        window.isDiffMode = false;
        window.diffBaseTs = null;
        window.diffTargetTs = null;

        function getDefaultCompareKeys(tabName) {
            switch(tabName) {
                case 'Processes': return ['Name', 'Path', 'CommandLine', 'SHA256', 'Signer'];
                case 'Services': return ['Name', 'DisplayName', 'PathName', 'StartMode', 'State'];
                case 'ScheduledTasks': return ['TaskName', 'TaskPath', 'Command', 'Arguments'];
                case 'NetworkConnections': return ['ProcessName', 'ProcessPath', 'Protocol', 'RemoteAddress', 'RemotePort', 'State'];
                case 'Users': return ['Name', 'Enabled'];
                case 'SystemPersistence': return ['Key', 'ValueName', 'Source'];
                case 'StartupFiles': return ['Executable', 'Signer', 'Source'];
                case 'ExecutionEvidence': return ['Executable', 'Source'];
                case 'InstalledSoftware': return ['DisplayName', 'Publisher'];
                case 'FirewallRules': return ['DisplayName', 'Direction', 'Action', 'Profile'];
                case 'RDPConnections': return ['Type', 'User', 'SourceIP', 'Destination'];
                case 'EventLogs': return ['EventId', 'Provider', 'Details'];
                default: return []; // Empty means hash all keys (except _System, etc)
            }
        }
        
        function toggleCompareKey(tabName, keyName) {
            if (!window.compareGroupKeys[tabName]) {
                window.compareGroupKeys[tabName] = getDefaultCompareKeys(tabName);
            }
            const keys = window.compareGroupKeys[tabName];
            const idx = keys.indexOf(keyName);
            if (idx >= 0) {
                keys.splice(idx, 1);
            } else {
                keys.push(keyName);
            }
            renderTable(tabName);
        }

        if (typeof dfirData === 'undefined') {
            document.getElementById('tableContainer').innerHTML = '<div class="empty-state" style="color:var(--danger)">Error: data.js could not be loaded or is empty. Ensure Invoke-DFIRCollection.ps1 finished successfully.</div>';
        } else {
            initApp();
        }

        function toggleCompareMode(enabled) {
            window.isCompareMode = enabled;
            document.getElementById('compareControls').style.display = enabled ? 'flex' : 'none';
            renderComputerList();
            
            if (enabled) {
                if (selectedHostname) window.selectedHosts.add(selectedHostname);
                document.getElementById('computerTitle').textContent = "Compare Mode Active (" + window.selectedHosts.size + " selected)";
                document.getElementById('timestampBadge').innerHTML = ""; // No timestamp in compare mode
                renderTable(currentTab);
            } else {
                if (window.selectedHosts.size > 0 && !selectedHostname) {
                    selectedHostname = Array.from(window.selectedHosts)[0];
                }
                selectHostname(selectedHostname);
            }
        }
        
        function selectAllOS(osType) {
            window.selectedHosts.clear();
            Object.keys(groupedSystems).forEach(name => {
                if (window.hostOSMap[name] === osType) {
                    window.selectedHosts.add(name);
                }
            });
            renderComputerList();
            document.getElementById('computerTitle').textContent = "Compare Mode Active (" + window.selectedHosts.size + " selected)";
            renderTable(currentTab);
        }

        function toggleHostSelection(name, checkbox) {
            if (checkbox.checked) {
                window.selectedHosts.add(name);
            } else {
                window.selectedHosts.delete(name);
            }
            document.getElementById('computerTitle').textContent = "Compare Mode Active (" + window.selectedHosts.size + " selected)";
            renderTable(currentTab);
        }

        function renderComputerList() {
            const list = document.getElementById('computerList');
            list.innerHTML = '';
            Object.keys(groupedSystems).forEach(name => {
                const li = document.createElement('li');
                li.className = 'computer-item';
                if (window.isCompareMode) {
                    li.innerHTML = `<label style="display:flex; align-items:center; cursor:pointer; width:100%;">
                        <input type="checkbox" style="margin-right:8px;" ${window.selectedHosts.has(name) ? 'checked' : ''} onchange="toggleHostSelection('${name}', this)">
                        ${name}
                    </label>`;
                } else {
                    li.textContent = name;
                    li.onclick = () => selectHostname(name);
                    if (name === selectedHostname) li.classList.add('active');
                }
                list.appendChild(li);
            });
        }

        function initApp() {
            let systems = Array.isArray(dfirData) ? dfirData : [dfirData];
            
            function cleanDates(obj) {
                if (!obj) return;
                if (Array.isArray(obj)) {
                    obj.forEach(cleanDates);
                } else if (typeof obj === 'object') {
                    for (let key in obj) {
                        if (typeof obj[key] === 'string' && (obj[key].startsWith('/Date(') || obj[key].startsWith('Date('))) {
                            try {
                                const match = obj[key].match(/\d+/);
                                if (match) {
                                    const d = new Date(parseInt(match[0]));
                                    if (!isNaN(d)) obj[key] = d.toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
                                }
                            } catch(e) {}
                        } else if (typeof obj[key] === 'object') {
                            cleanDates(obj[key]);
                        }
                    }
                }
            }
            cleanDates(systems);
            
            
            groupedSystems = {};
            systems.forEach((sys, idx) => {
                const name = sys.ComputerName || sys.PSComputerName || `Unknown-${idx}`;
                if (!groupedSystems[name]) groupedSystems[name] = [];
                groupedSystems[name].push(sys);
            });
            
            Object.keys(groupedSystems).forEach(name => {
                groupedSystems[name].sort((a,b) => {
                    let ta = a.Timestamp || "";
                    let tb = b.Timestamp || "";
                    return tb.localeCompare(ta);
                });
                
                let os = 'Windows';
                const sysInfo = groupedSystems[name][0].SystemInfo;
                if (sysInfo && Array.isArray(sysInfo)) {
                    sysInfo.forEach(s => {
                        let valStr = Object.values(s).join(' ').toLowerCase();
                        if (valStr.includes('linux')) os = 'Linux';
                    });
                }
                window.hostOSMap[name] = os;
            });
            
            renderComputerList();
            
            if (Object.keys(groupedSystems).length > 0) {
                selectHostname(Object.keys(groupedSystems)[0]);
            }
        }

        function toggleDiffMode() {
            window.isDiffMode = !window.isDiffMode;
            if (window.isDiffMode) {
                window.isCompareMode = false;
                currentSortColumn = '_DiffStatus';
                currentSortDirection = 'asc';
                const runs = groupedSystems[selectedHostname];
                if (runs && runs.length > 1) {
                    window.diffTargetTs = runs[0].Timestamp || '';
                    window.diffBaseTs = runs[1].Timestamp || '';
                }
            }
            renderTimestampBadge();
            switchTab(currentTab);
        }

        function renderTimestampBadge() {
            const badgeContainer = document.getElementById('timestampBadge');
            if (!selectedHostname || window.isCompareMode) {
                badgeContainer.innerHTML = '';
                return;
            }
            const runs = groupedSystems[selectedHostname];
            if (runs.length <= 1) {
                badgeContainer.innerHTML = runs[0].Timestamp ? `<span style="margin-left:10px;">Collected: ${runs[0].Timestamp}</span>` : '';
                return;
            }

            if (!window.isDiffMode) {
                let selectHtml = `<select id="datasetSelect" style="background:var(--bg-color); color:var(--text-main); border:1px solid var(--glass-border); border-radius:4px; padding:3px 8px; margin-left:10px; font-family:inherit;" onchange="selectDatasetByTimestamp(this.value)">`;
                runs.forEach(r => { selectHtml += `<option value="${r.Timestamp || ''}">${r.Timestamp || 'Unknown Time'}</option>`; });
                selectHtml += `</select>`;
                selectHtml += `<button onclick="toggleDiffMode()" style="margin-left:10px; padding:3px 10px; background:var(--accent); color:white; border:none; border-radius:4px; cursor:pointer;">Diff Timelines</button>`;
                badgeContainer.innerHTML = selectHtml;
                if (currentComputer && currentComputer.Timestamp) {
                    const el = document.getElementById('datasetSelect');
                    if(el) el.value = currentComputer.Timestamp;
                }
            } else {
                let bHtml = `<select id="diffBaseSelect" style="background:var(--bg-color); color:var(--text-main); border:1px solid var(--glass-border); border-radius:4px; padding:3px 8px; margin-left:10px; font-family:inherit;" onchange="window.diffBaseTs=this.value; switchTab(currentTab);">`;
                runs.forEach(r => { bHtml += `<option value="${r.Timestamp || ''}" ${r.Timestamp === window.diffBaseTs ? 'selected' : ''}>Base: ${r.Timestamp || 'Unknown Time'}</option>`; });
                bHtml += `</select>`;
                
                let tHtml = `<select id="diffTargetSelect" style="background:var(--bg-color); color:var(--text-main); border:1px solid var(--glass-border); border-radius:4px; padding:3px 8px; margin-left:10px; font-family:inherit;" onchange="window.diffTargetTs=this.value; switchTab(currentTab);">`;
                runs.forEach(r => { tHtml += `<option value="${r.Timestamp || ''}" ${r.Timestamp === window.diffTargetTs ? 'selected' : ''}>Target: ${r.Timestamp || 'Unknown Time'}</option>`; });
                tHtml += `</select>`;
                
                let selectHtml = bHtml + tHtml + `<button onclick="toggleDiffMode()" style="margin-left:10px; padding:3px 10px; background:var(--danger); color:white; border:none; border-radius:4px; cursor:pointer;">Exit Diff</button>`;
                badgeContainer.innerHTML = selectHtml;
            }
        }
        
        function computeDiff(baseArr, targetArr, tabName) {
            let bArr = Array.isArray(baseArr) ? baseArr : (baseArr ? [baseArr] : []);
            let tArr = Array.isArray(targetArr) ? targetArr : (targetArr ? [targetArr] : []);
            
            let baseMap = new Map();
            let diffArr = [];
            
            bArr.forEach(item => {
                let h = hashArtifact(item, tabName);
                if (!baseMap.has(h)) baseMap.set(h, []);
                baseMap.get(h).push(item);
            });
            
            let targetMap = new Map();
            tArr.forEach(item => {
                let h = hashArtifact(item, tabName);
                if (!targetMap.has(h)) targetMap.set(h, []);
                targetMap.get(h).push(item);
            });
            
            tArr.forEach(item => {
                let h = hashArtifact(item, tabName);
                let cloned = Object.assign({}, item);
                if (!baseMap.has(h)) {
                    cloned._DiffStatus = 'Added';
                } else {
                    cloned._DiffStatus = 'Unchanged';
                }
                diffArr.push(cloned);
            });
            
            bArr.forEach(item => {
                let h = hashArtifact(item, tabName);
                if (!targetMap.has(h)) {
                    let cloned = Object.assign({}, item);
                    cloned._DiffStatus = 'Removed';
                    diffArr.push(cloned);
                }
            });
            
            return diffArr;
        }

        function selectHostname(name) {
            if (window.isCompareMode) return;
            selectedHostname = name;
            document.getElementById('computerTitle').textContent = name;
            
            renderComputerList();
            
            const runs = groupedSystems[name];
            if (!window.isDiffMode) {
                selectDatasetByTimestamp(runs[0].Timestamp || '');
            }
            renderTimestampBadge();
        }
        
        function selectDatasetByTimestamp(ts) {
            const runs = groupedSystems[selectedHostname];
            const dataset = runs.find(r => (r.Timestamp || '') === ts) || runs[0];
            selectDataset(dataset);
        }

        function selectDataset(sysData) {
            currentComputer = sysData;
            
            // Re-run search if a search was active
            const searchInput = document.getElementById('searchInput');
            if (searchInput.value.trim()) {
                handleSearch(searchInput.value);
            } else {
                switchTab(currentTab);
            }
        }

        function handleSearch(query) {
            query = query.trim();
            const searchTab = document.getElementById('tabSearchResults');
            
            if (!query) {
                // Clear search
                searchTab.style.display = 'none';
                if (currentTab === 'SearchResults') {
                    switchTab(previousTab);
                }
                return;
            }
            
            // Perform search
            searchTab.style.display = 'block';
            if (currentTab !== 'SearchResults') {
                previousTab = currentTab;
            }
            
            performSearch(query);
            switchTab('SearchResults');
        }

        function performSearch(query) {
            searchResultsData = []; // Clear previous
            
            const searchLatestAll = document.getElementById('searchLatestAllSystems') ? document.getElementById('searchLatestAllSystems').checked : false;
            const searchAllTime = document.getElementById('searchAllDatasets') ? document.getElementById('searchAllDatasets').checked : false;
            
            let systemsToSearch = [];
            
            if (searchAllTime) {
                systemsToSearch = Array.isArray(dfirData) ? dfirData : [dfirData];
            } else if (searchLatestAll) {
                Object.keys(groupedSystems).forEach(name => {
                    if (groupedSystems[name].length > 0) {
                        systemsToSearch.push(groupedSystems[name][0]);
                    }
                });
            } else {
                systemsToSearch = [currentComputer];
            }
            
            if (!systemsToSearch[0]) return;
            
            const categories = ['SystemInfo', 'Processes', 'Services', 'ScheduledTasks', 'NetworkConnections', 'LocalUsers', 'SystemPersistence', 'PrivilegedAccess', 'StartupFiles', 'ExecutionEvidence', 'EventLogs'];
            
            systemsToSearch.forEach((sys, idx) => {
                const sysBaseName = sys.ComputerName || sys.PSComputerName || `Unknown-${idx}`;
                const sysName = searchAllTime ? `${sysBaseName} (${sys.Timestamp || 'Unknown Time'})` : sysBaseName;
                
                categories.forEach(cat => {
                    const dataArray = sys[cat];
                    if (!dataArray) return;
                    
                    const arr = Array.isArray(dataArray) ? dataArray : [dataArray];
                    const matches = [];
                    const hideSigned = document.getElementById('filterSigned') ? document.getElementById('filterSigned').checked : false;
                    
                    arr.forEach(item => {
                        if (!item) return;
                        
                        if (hideSigned && item.Signer && item.Signer !== 'Invalid/NotSigned' && item.Signer !== 'N/A' && item.Signer.trim() !== '') {
                            return; // Skip signed items
                        }
                        
                        // Check if any property value contains the query
                        const itemValues = Object.values(item).map(v => v !== null && v !== undefined ? String(v).toLowerCase() : '');
                        
                        let processedQuery = query
                            .replace(/\s+AND\s+/g, '&')
                            .replace(/\s+OR\s+/g, ',')
                            .replace(/(^|\s+|&|,)NOT\s+/g, '$1!')
                            .toLowerCase();
                        
                        let isMatch = true;
                        
                        if (processedQuery.includes(',')) {
                            const terms = processedQuery.split(',');
                            isMatch = terms.some(t => {
                                t = t.trim();
                                if (t === '') return false;
                                if (t.startsWith('!')) {
                                    const excludeText = t.substring(1).trim();
                                    return excludeText === "" ? true : !itemValues.some(v => v.includes(excludeText));
                                }
                                return itemValues.some(v => v.includes(t));
                            });
                        } else if (processedQuery.includes('&')) {
                            const terms = processedQuery.split('&');
                            isMatch = terms.every(t => {
                                t = t.trim();
                                if (t === '') return true;
                                if (t.startsWith('!')) {
                                    const excludeText = t.substring(1).trim();
                                    return excludeText === "" ? true : !itemValues.some(v => v.includes(excludeText));
                                }
                                return itemValues.some(v => v.includes(t));
                            });
                        } else {
                            const terms = processedQuery.split(/\s+/).filter(t => t.trim() !== '');
                            for (const term of terms) {
                                if (term.startsWith('!')) {
                                    const excludeText = term.substring(1);
                                    if (excludeText !== "" && itemValues.some(v => v.includes(excludeText))) {
                                        isMatch = false;
                                        break;
                                    }
                                } else {
                                    if (!itemValues.some(v => v.includes(term))) {
                                        isMatch = false;
                                        break;
                                    }
                                }
                            }
                        }

                        if (isMatch) {
                            matches.push(item);
                        }
                    });
                    
                    if (matches.length > 0) {
                        searchResultsData.push({
                            system: sysName,
                            category: cat,
                            items: matches
                        });
                    }
                });
            });
        }

        function switchTab(tabId) {
            currentTab = tabId;
            columnFilters = {}; // Reset filters on tab switch
            
            const searchInput = document.getElementById('searchInput');
            if (tabId !== 'SearchResults' && searchInput && searchInput.value) {
                searchInput.value = '';
                document.getElementById('tabSearchResults').style.display = 'none';
            }
            
            document.querySelectorAll('.tab').forEach(t => {
                if(t.dataset.tab === tabId) {
                    t.classList.add('active');
                } else {
                    t.classList.remove('active');
                }
            });
            
            if (document.getElementById('searchInput').value) {
                renderSearchResults();
            } else if (tabId === 'Timeline') {
                renderTimeline();
            } else if (tabId === 'ProcessTree') {
                renderProcessTree();
            } else if (tabId === 'FlaggedItems') {
                renderFlaggedItems();
            } else {
                renderTable(tabId);
            }
        }
        
        function escapeHtml(unsafe) {
            if (unsafe === null || unsafe === undefined || unsafe === "") return '<span class="null-val">null</span>';
            if (typeof unsafe === 'object') {
                if (unsafe.value) return escapeHtml(unsafe.value);
                return escapeHtml(JSON.stringify(unsafe));
            }
            return unsafe
                 .toString()
                 .replace(/&/g, "&amp;")
                 .replace(/</g, "&lt;")
                 .replace(/>/g, "&gt;")
                 .replace(/"/g, "&quot;")
                 .replace(/'/g, "&#39;");
        }

        function parseCustomDate(val) {
            if (!val) return null;
            let strVal = String(val);
            let d = null;
            const match = strVal.match(/\/Date\((\d+)\)\//);
            if (match) {
                d = new Date(parseInt(match[1]));
            } else {
                d = new Date(val);
            }
            if (!isNaN(d)) {
                if (d.getFullYear() <= 1999) return null;
                return d;
            }
            return null;
        }

        function sortTable(column) {
            if (currentSortColumn === column) {
                currentSortDirection = currentSortDirection === 'asc' ? 'desc' : 'asc';
            } else {
                currentSortColumn = column;
                currentSortDirection = 'asc';
            }
            renderTable(currentTab);
        }

        function setColumnFilter(column, value) {
            if (!value.trim()) {
                delete columnFilters[column];
            } else {
                columnFilters[column] = value;
            }
            renderTable(currentTab);
        }

        function buildTableHTML(dataArray, titleHtml, groupId = 'main') {
            if (!dataArray || dataArray.length === 0) return '';
            let arr = Array.isArray(dataArray) ? [...dataArray] : [dataArray];
            
            // 1. Apply Global Signed Filter
            const hideSigned = document.getElementById('filterSigned') ? document.getElementById('filterSigned').checked : false;
            if (hideSigned) {
                arr = arr.filter(item => {
                    if (!item) return false;
                    if (item.Signer && item.Signer !== 'Invalid/NotSigned' && item.Signer !== 'N/A' && item.Signer.trim() !== '') {
                        return false; 
                    }
                    return true;
                });
            }

            // 2. Apply Per-Column Filters
            if (Object.keys(columnFilters).length > 0) {
                arr = arr.filter(item => {
                    if (!item) return false;
                    for (const col in columnFilters) {
                        let filterText = columnFilters[col];
                        filterText = filterText
                            .replace(/\s+AND\s+/g, '&')
                            .replace(/\s+OR\s+/g, ',')
                            .replace(/(^|\s+|&|,)NOT\s+/g, '$1!')
                            .toLowerCase();
                            
                        const val = item[col] ? String(item[col]).toLowerCase() : "";
                        
                        if (filterText.includes(',')) {
                            const terms = filterText.split(',');
                            const isMatch = terms.some(t => {
                                t = t.trim();
                                if (t === '') return false;
                                if (t.startsWith('!')) return !val.includes(t.substring(1).trim());
                                return val.includes(t);
                            });
                            if (!isMatch) return false;
                        } else if (filterText.includes('&')) {
                            const terms = filterText.split('&');
                            const isMatch = terms.every(t => {
                                t = t.trim();
                                if (t === '') return true;
                                if (t.startsWith('!')) return !val.includes(t.substring(1).trim());
                                return val.includes(t);
                            });
                            if (!isMatch) return false;
                        } else {
                            const spaceTerms = filterText.split(/\s+/).filter(t => t.trim() !== '');
                            const spaceMatch = spaceTerms.every(t => {
                                if (t.startsWith('!')) {
                                    const excludeText = t.substring(1);
                                    return excludeText === "" ? true : !val.includes(excludeText);
                                }
                                return val.includes(t);
                            });
                            if (!spaceMatch) return false;
                        }
                    }
                    return true;
                });
            }

            // 3. Apply Sorting
            if (currentSortColumn) {
                arr.sort((a, b) => {
                    let valA = a ? a[currentSortColumn] : "";
                    let valB = b ? b[currentSortColumn] : "";
                    
                    if (currentSortColumn === '_DiffStatus') {
                        const order = { 'Added': 1, 'Removed': 2, 'Unchanged': 3 };
                        let orderA = order[valA] || 4;
                        let orderB = order[valB] || 4;
                        if (orderA < orderB) return currentSortDirection === 'asc' ? -1 : 1;
                        if (orderA > orderB) return currentSortDirection === 'asc' ? 1 : -1;
                        return 0;
                    }
                    
                    if (valA === null || valA === undefined) valA = "";
                    if (valB === null || valB === undefined) valB = "";
                    
                    if (currentSortColumn.includes('Time') || currentSortColumn.includes('Date') || currentSortColumn === 'LastRun') {
                        let dA = parseCustomDate(valA);
                        let dB = parseCustomDate(valB);
                        let numA = dA ? dA.getTime() : 0;
                        let numB = dB ? dB.getTime() : 0;
                        if (numA < numB) return currentSortDirection === 'asc' ? -1 : 1;
                        if (numA > numB) return currentSortDirection === 'asc' ? 1 : -1;
                        return 0;
                    }
                    
                    // Basic numeric sort if both are numbers
                    if (!isNaN(valA) && !isNaN(valB) && valA !== "" && valB !== "") {
                        valA = Number(valA);
                        valB = Number(valB);
                    } else {
                        valA = String(valA).toLowerCase();
                        valB = String(valB).toLowerCase();
                    }

                    if (valA < valB) return currentSortDirection === 'asc' ? -1 : 1;
                    if (valA > valB) return currentSortDirection === 'asc' ? 1 : -1;
                    return 0;
                });
            }

            // Extract all keys for headers
            let keys = new Set();
            (Array.isArray(dataArray) ? dataArray : [dataArray]).forEach(item => {
                if(item) Object.keys(item).forEach(k => keys.add(k));
            });
            keys = Array.from(keys).filter(k => !k.startsWith('_'));
            
            // Limit Chronological EventLogs view to generic columns
            if (currentTab === 'EventLogs') {
                if (!window.eventLogGroupMode && titleHtml === '') {
                    keys = ['EventTime', 'EventId', 'Details'];
                } else {
                    keys = keys.filter(k => k !== 'EventName' && k !== 'Provider');
                }
            }
            if (currentTab === 'FirewallRules') {
                keys = keys.filter(k => k !== 'Program' && k !== 'Profile');
            }
            
            let html = titleHtml + '<table><thead><tr>';
            if (currentTab !== 'FlaggedItems') {
                html += '<th style="width:50px; text-align:center;">Flag</th>';
            }
            if (window.isDiffMode) {
                let diffFilterVal = columnFilters['_DiffStatus'] || '';
                let sortIndicator = "";
                if (currentSortColumn === '_DiffStatus') {
                    sortIndicator = currentSortDirection === 'asc' ? " &#9650;" : " &#9660;";
                }
                html += `<th style="width:120px; text-align:center; vertical-align:top;">
                            <div class="sortable-header" onclick="sortTable('_DiffStatus')" style="margin-bottom:5px;">Diff${sortIndicator}</div>
                            <select onchange="setColumnFilter('_DiffStatus', this.value);" style="width:100%; padding:3px; border-radius:4px; background:var(--bg-color); color:var(--text-main); border:1px solid var(--glass-border);">
                                <option value="" ${diffFilterVal === '' ? 'selected' : ''}>All</option>
                                <option value="Added" ${diffFilterVal === 'Added' ? 'selected' : ''}>+ Added</option>
                                <option value="Removed" ${diffFilterVal === 'Removed' ? 'selected' : ''}>- Removed</option>
                                <option value="Unchanged" ${diffFilterVal === 'Unchanged' ? 'selected' : ''}>Unchanged</option>
                            </select>
                         </th>`;
            }
            keys.forEach(k => {
                let sortIndicator = "";
                if (currentSortColumn === k) {
                    sortIndicator = currentSortDirection === 'asc' ? " &#9650;" : " &#9660;";
                }
                let filterValue = columnFilters[k] ? escapeHtml(columnFilters[k]) : "";
                
                html += `<th>
                            <div class="sortable-header" onclick="sortTable('${escapeHtml(k)}')">${escapeHtml(k)}${sortIndicator}</div>
                            <div style="display:flex; align-items:center; position:relative; margin-top:5px;">
                                <input type="text" id="filter-${groupId}-${escapeHtml(k)}" class="column-filter" placeholder="Filter..." value="${filterValue}" oninput="setColumnFilter('${escapeHtml(k)}', this.value)" style="width:100%; border-radius:4px 0 0 4px;">
                                <button title="Filter Builder" style="background:var(--accent); color:white; border:1px solid var(--accent); border-radius:0 4px 4px 0; padding:3px 6px; cursor:pointer;" onclick="toggleFilterHelp('${groupId}-${escapeHtml(k)}')">&#9660;</button>
                                <div id="filterHelp-${groupId}-${escapeHtml(k)}" style="display:none; position:absolute; top:100%; right:0; background:var(--bg-color); border:1px solid var(--glass-border); border-radius:4px; padding:5px; z-index:100; box-shadow: 0 4px 6px rgba(0,0,0,0.5); flex-direction:column; gap:5px; min-width: 140px;">
                                    <div style="font-size:0.7rem; color:var(--text-muted); padding:3px; text-align:center; border-bottom:1px solid var(--glass-border);">Add Rule</div>
                                    <button style="background:transparent; color:var(--text-main); border:none; text-align:left; cursor:pointer; padding:5px; width:100%; border-radius:3px;" onmouseover="this.style.background='rgba(255,255,255,0.1)'" onmouseout="this.style.background='transparent'" onclick="appendFilter('${groupId}-${escapeHtml(k)}', '${escapeHtml(k)}', ' AND ')">&#10133; AND Condition</button>
                                    <button style="background:transparent; color:var(--text-main); border:none; text-align:left; cursor:pointer; padding:5px; width:100%; border-radius:3px;" onmouseover="this.style.background='rgba(255,255,255,0.1)'" onmouseout="this.style.background='transparent'" onclick="appendFilter('${groupId}-${escapeHtml(k)}', '${escapeHtml(k)}', ' OR ')">&#10133; OR Condition</button>
                                    <button style="background:transparent; color:var(--text-main); border:none; text-align:left; cursor:pointer; padding:5px; width:100%; border-radius:3px;" onmouseover="this.style.background='rgba(255,255,255,0.1)'" onmouseout="this.style.background='transparent'" onclick="appendFilter('${groupId}-${escapeHtml(k)}', '${escapeHtml(k)}', ' NOT ')">&#10060; NOT Condition</button>
                                </div>
                            </div>
                        </th>`;
            });
            html += '</tr></thead><tbody>';
            
            if (arr.length === 0) {
                html += `<tr><td colspan="${keys.length + (window.isDiffMode ? 2 : 1)}"><div class="empty-state">All items are hidden by your filters.</div></td></tr>`;
            } else {
            window.renderedItems = window.renderedItems || {};
            arr.forEach(item => {
                let rowStyle = '';
                if (window.isDiffMode && item && item._DiffStatus) {
                    if (item._DiffStatus === 'Added') rowStyle = 'background: rgba(40,167,69,0.15);';
                    if (item._DiffStatus === 'Removed') rowStyle = 'background: rgba(220,53,69,0.15); text-decoration: line-through;';
                }
                const trId = 'tr-' + Math.random().toString(36).substr(2, 9);
                window.renderedItems[trId] = { system: selectedHostname, category: currentTab, data: item, timestamp: (typeof currentComputer !== 'undefined' && currentComputer ? (currentComputer.Timestamp || '') : '') };
                
                const isFlagged = item && window.flaggedHashes && window.flaggedHashes.has(hashArtifact(item, currentTab));
                html += `<tr id="${trId}" style="${rowStyle}">`;
                if (currentTab !== 'FlaggedItems') {
                    if (isFlagged) {
                        html += `<td style="text-align:center; vertical-align:top;" onclick="toggleFlag('${trId}', '${escapeHtml(hashArtifact(item, currentTab))}')"><span style="cursor:pointer; color:var(--danger); font-size:1.2rem;">&#128681;</span></td>`;
                    } else {
                        html += `<td style="text-align:center; vertical-align:top;" onclick="toggleFlag('${trId}', '${escapeHtml(hashArtifact(item, currentTab))}')"><span style="cursor:pointer; color:var(--text-muted); opacity:0.3; font-size:1.2rem;" onmouseover="this.style.opacity=1" onmouseout="this.style.opacity=0.3">&#9873;</span></td>`;
                    }
                }
                
                if (window.isDiffMode) {
                    let diffBadge = '';
                    if (item && item._DiffStatus === 'Added') diffBadge = '<span style="color: #28a745; font-weight:bold;">+ Added</span>';
                    else if (item && item._DiffStatus === 'Removed') diffBadge = '<span style="color: #dc3545; font-weight:bold;">- Removed</span>';
                    else diffBadge = '<span style="color: var(--text-muted);">Unchanged</span>';
                    html += `<td style="text-align:center; vertical-align:top;">${diffBadge}</td>`;
                }
                
                keys.forEach((key, kIdx) => {
                    let val = item ? item[key] : null;
                    if (val && typeof val === 'object' && val.value_enum !== undefined && val.Value !== undefined) val = val.Value;
                    if (key.includes('Time') || key.includes('Date')) {
                        try {
                            const d = parseCustomDate(val);
                            if (d) {
                                val = d.toISOString().replace('T', ' ').substring(0, 19) + ' UTC';
                            } else {
                                val = val ? val : "N/A";
                            }
                        } catch(e) {}
                    }
                    if ((currentTab === 'EventLogs' || currentTab === 'FirewallRules') && kIdx === 0) {
                        html += `<td>
                                   <span style="cursor:pointer; color:var(--accent); font-weight:bold; margin-right:10px; font-family:monospace;" 
                                         onclick="const e=document.getElementById('${trId}-exp'); e.style.display=e.style.display==='none'?'table-row':'none'; this.innerText=e.style.display==='none'?'[+]':'[-]';">[+]</span>
                                   <div class="td-content" style="display:inline-block; vertical-align:top;" onclick="showCellModal(this.parentElement)">${escapeHtml(val)}</div>
                                 </td>`;
                    } else {
                        html += `<td onclick="showCellModal(this)"><div class="td-content">${escapeHtml(val)}</div></td>`;
                    }
                });
                html += '</tr>';
                if (currentTab === 'EventLogs' || currentTab === 'FirewallRules') {
                    const fullData = item ? Object.keys(item).map(k => `<strong style="color:var(--accent-hover);">${escapeHtml(k)}:</strong> ${escapeHtml(item[k])}`).join('<br>') : '';
                    let colSpanCount = currentTab !== 'FlaggedItems' ? keys.length + 1 : keys.length;
                    if (window.isDiffMode) colSpanCount += 1;
                    html += `<tr id="${trId}-exp" style="display:none; background: rgba(0,0,0,0.2);">
                               <td colspan="${colSpanCount}" style="padding:15px; border-left: 3px solid var(--accent);">
                                 <div style="max-height:400px; overflow-y:auto; white-space:pre-wrap; font-family:monospace; color:var(--text);">${fullData}</div>
                               </td>
                             </tr>`;
                }
            });
            }
            html += '</tbody></table>';
            return html;
        }

        function hashArtifact(obj, tabName) {
            let clean = {};
            let keys = window.compareGroupKeys[tabName] || [];
            if (keys.length === 0) {
                Object.keys(obj).sort().forEach(k => {
                    if (k !== '_System' && k !== '_CompareType' && k !== 'Count' && k !== 'Seen On' && k !== '_DiffStatus') {
                        let val = obj[k];
                        if (val && typeof val === 'object' && val.value_enum !== undefined && val.Value !== undefined) val = val.Value;
                        clean[k] = val;
                    }
                });
            } else {
                keys.forEach(k => {
                    let val = obj[k] !== undefined ? obj[k] : null;
                    if (val && typeof val === 'object' && val.value_enum !== undefined && val.Value !== undefined) val = val.Value;
                    clean[k] = val;
                });
            }
            return JSON.stringify(clean);
        }

        function renderTable(tabName) {
            const container = document.getElementById('tableContainer');
            if (!currentComputer && !window.isCompareMode) return;
            if (window.isCompareMode && window.selectedHosts.size === 0) {
                container.innerHTML = '<div class="empty-state">Select one or more hosts from the sidebar to compare them.</div>';
                return;
            }
            
            let activeFilterId = null;
            let activeFilterStart = null;
            if (document.activeElement && document.activeElement.classList.contains('column-filter')) {
                activeFilterId = document.activeElement.id;
                try { activeFilterStart = document.activeElement.selectionStart; } catch(e) {}
            }
            
            let html = '';
            
            // COMPARE MODE AGGREGATION
            if (window.isCompareMode) {
                let allItems = [];
                window.selectedHosts.forEach(hostname => {
                    if (groupedSystems[hostname] && groupedSystems[hostname].length > 0) {
                        const sys = groupedSystems[hostname][0];
                        if (tabName === 'Users') {
                            const l = sys['LocalUsers'] ? (Array.isArray(sys['LocalUsers']) ? sys['LocalUsers'] : [sys['LocalUsers']]) : [];
                            const p = sys['PrivilegedAccess'] ? (Array.isArray(sys['PrivilegedAccess']) ? sys['PrivilegedAccess'] : [sys['PrivilegedAccess']]) : [];
                            l.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'LocalUsers'; copy._System = hostname; allItems.push(copy); });
                            p.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'PrivilegedAccess'; copy._System = hostname; allItems.push(copy); });
                        } else {
                            let sysData = sys[tabName];
                            if (sysData) {
                                let arr = Array.isArray(sysData) ? sysData : [sysData];
                                arr.forEach(i => { let copy = Object.assign({}, i); copy._System = hostname; allItems.push(copy); });
                            }
                        }
                    }
                });

                if (allItems.length === 0) {
                    container.innerHTML = '<div class="empty-state">No data collected for ' + tabName + ' across selected hosts.</div>';
                    return;
                }
                
                let allKeys = new Set();
                allItems.forEach(i => {
                    if(i) Object.keys(i).forEach(k => {
                        if (k !== '_System' && k !== '_CompareType' && k !== 'Count' && k !== 'Seen On') allKeys.add(k);
                    });
                });
                allKeys = Array.from(allKeys).sort();
                
                if (!window.compareGroupKeys[tabName]) {
                    window.compareGroupKeys[tabName] = getDefaultCompareKeys(tabName);
                }
                const activeKeys = window.compareGroupKeys[tabName];
                
                html += `<div style="margin-bottom: 15px; padding: 15px; background: rgba(0,0,0,0.2); border-radius: 6px; border: 1px solid var(--glass-border);">
                    <div style="font-weight: bold; color: var(--text-main); margin-bottom: 10px; font-size: 0.95rem;">Stack Items By (Uniqueness Keys):</div>
                    <div style="display: flex; flex-wrap: wrap; gap: 8px;">`;
                allKeys.forEach(k => {
                    const isActive = activeKeys.includes(k);
                    const bg = isActive ? 'var(--accent)' : 'var(--bg-lighter)';
                    const fg = isActive ? 'white' : 'var(--text-muted)';
                    const border = isActive ? 'var(--accent)' : 'var(--glass-border)';
                    html += `<button onclick="toggleCompareKey('${tabName}', '${escapeHtml(k)}')" style="padding: 4px 10px; border-radius: 12px; border: 1px solid ${border}; background: ${bg}; color: ${fg}; cursor: pointer; font-size: 0.8rem; transition: all 0.2s; box-shadow: 0 2px 4px rgba(0,0,0,0.2);">${escapeHtml(k)}</button>`;
                });
                html += `</div></div>`;

                const stacked = {};
                allItems.forEach(item => {
                    const hash = hashArtifact(item, tabName);
                    if (!stacked[hash]) {
                        stacked[hash] = {
                            Count: 0,
                            SeenOn: new Set(),
                            Data: Object.assign({}, item)
                        };
                    }
                    stacked[hash].Count++;
                    stacked[hash].SeenOn.add(item._System);
                });

                let stackedArr = Object.values(stacked).map(s => {
                    let finalObj = { Count: s.Count, 'Seen On': Array.from(s.SeenOn).sort().join(', ') };
                    Object.assign(finalObj, s.Data);
                    return finalObj;
                });
                
                // Sort by Count ascending to highlight outliers, if no explicit sort
                if (!currentSortColumn) {
                    currentSortColumn = 'Count';
                    currentSortDirection = 'asc';
                }

                if (tabName === 'Users') {
                    const local = stackedArr.filter(i => i._CompareType === 'LocalUsers');
                    const priv = stackedArr.filter(i => i._CompareType === 'PrivilegedAccess');
                    local.forEach(i => { delete i._CompareType; delete i._System; });
                    priv.forEach(i => { delete i._CompareType; delete i._System; });
                    
                    if (local.length > 0) html += buildTableHTML(local, '<h2 style="color:var(--accent);margin-bottom:10px;">Local Users (Compare Mode)</h2>', 'local-users');
                    if (priv.length > 0) html += buildTableHTML(priv, '<h2 style="color:var(--accent);margin-top:30px;margin-bottom:10px;">Privileged Access (Compare Mode)</h2>', 'priv-users');
                    container.innerHTML = html;
                } else {
                    stackedArr.forEach(i => { delete i._System; });
                    
                    let shouldGroup = false;
                    let groupProp = 'Source';
                    if (tabName === 'EventLogs' && window.eventLogGroupMode) { shouldGroup = true; groupProp = 'EventId'; }
                    else if (tabName !== 'EventLogs' && stackedArr.some(i => i.Source)) { shouldGroup = true; groupProp = 'Source'; }
                    
                    if (shouldGroup) {
                        const groupedBySource = {};
                        stackedArr.forEach(item => {
                            const src = item[groupProp] || ('Unknown ' + groupProp);
                            if (!groupedBySource[src]) groupedBySource[src] = [];
                            groupedBySource[src].push(item);
                        });
                        Object.keys(groupedBySource).forEach((src, idx) => {
                            const groupId = 'group-' + tabName + '-' + idx;
                            let headerText = src;
                            if (groupProp === 'EventId') {
                                const fItem = groupedBySource[src][0];
                                const eName = (fItem && fItem.EventName && fItem.EventName !== 'Unknown') ? ': ' + fItem.EventName : '';
                                headerText = 'Event ID ' + src + eName;
                            }
                            html += `
                                <div style="display:flex; align-items:center; cursor:pointer; margin-top:20px; margin-bottom:10px; padding: 5px; border-radius: 4px; transition: background 0.2s;" 
                                     onclick="const e = document.getElementById('${groupId}'); e.style.display = e.style.display === 'none' ? 'block' : 'none';"
                                     onmouseover="this.style.background='rgba(255,255,255,0.05)'"
                                     onmouseout="this.style.background='transparent'">
                                    <h2 style="color:var(--accent); margin:0; font-size: 1.1rem;">${escapeHtml(headerText)}</h2>
                                    <span style="margin-left:10px; color:var(--text-muted); font-size:0.8rem;">(Click to expand/collapse)</span>
                                </div>
                                <div id="${groupId}">${buildTableHTML(groupedBySource[src], '', groupId)}</div>
                            `;
                        });
                        container.innerHTML = html;
                    } else {
                        container.innerHTML = buildTableHTML(stackedArr, '', 'main-table');
                    }
                }
            } else if (window.isDiffMode) {
                const runs = groupedSystems[selectedHostname] || [];
                let baseSys = runs.find(r => r.Timestamp === window.diffBaseTs) || runs[0];
                let targetSys = runs.find(r => r.Timestamp === window.diffTargetTs) || runs[0];
                
                let bData = [];
                let tData = [];
                if (tabName === 'Users') {
                    let bl = baseSys['LocalUsers'] ? (Array.isArray(baseSys['LocalUsers']) ? baseSys['LocalUsers'] : [baseSys['LocalUsers']]) : [];
                    let bp = baseSys['PrivilegedAccess'] ? (Array.isArray(baseSys['PrivilegedAccess']) ? baseSys['PrivilegedAccess'] : [baseSys['PrivilegedAccess']]) : [];
                    bl.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'LocalUsers'; bData.push(copy); });
                    bp.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'PrivilegedAccess'; bData.push(copy); });
                    
                    let tl = targetSys['LocalUsers'] ? (Array.isArray(targetSys['LocalUsers']) ? targetSys['LocalUsers'] : [targetSys['LocalUsers']]) : [];
                    let tp = targetSys['PrivilegedAccess'] ? (Array.isArray(targetSys['PrivilegedAccess']) ? targetSys['PrivilegedAccess'] : [targetSys['PrivilegedAccess']]) : [];
                    tl.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'LocalUsers'; tData.push(copy); });
                    tp.forEach(i => { let copy = Object.assign({}, i); copy._CompareType = 'PrivilegedAccess'; tData.push(copy); });
                } else {
                    bData = baseSys[tabName] ? (Array.isArray(baseSys[tabName]) ? baseSys[tabName] : [baseSys[tabName]]) : [];
                    tData = targetSys[tabName] ? (Array.isArray(targetSys[tabName]) ? targetSys[tabName] : [targetSys[tabName]]) : [];
                }
                
                let arrData = computeDiff(bData, tData, tabName);
                
                let shouldGroup = false;
                let groupProp = 'Source';
                
                if (tabName === 'Users') { shouldGroup = true; groupProp = '_CompareType'; }
                else if (tabName === 'EventLogs' && window.eventLogGroupMode) { shouldGroup = true; groupProp = 'EventId'; }
                else if (tabName !== 'EventLogs' && arrData.some(i => i && i.Source)) { shouldGroup = true; groupProp = 'Source'; }
                
                if (shouldGroup) {
                    const groupedBySource = {};
                    arrData.forEach(item => {
                        if (!item) return;
                        const src = item[groupProp] || ('Unknown ' + groupProp);
                        if (!groupedBySource[src]) groupedBySource[src] = [];
                        groupedBySource[src].push(item);
                    });
                    
                    Object.keys(groupedBySource).forEach((src, idx) => {
                        const groupId = 'group-' + tabName + '-' + idx;
                        let headerText = src;
                        if (groupProp === 'EventId') {
                            const fItem = groupedBySource[src][0];
                            const eName = (fItem && fItem.EventName && fItem.EventName !== 'Unknown') ? ': ' + fItem.EventName : '';
                            headerText = 'Event ID ' + src + eName;
                        }
                        html += `
                            <div style="display:flex; align-items:center; cursor:pointer; margin-top:20px; margin-bottom:10px; padding: 5px; border-radius: 4px; transition: background 0.2s;" 
                                 onclick="const e = document.getElementById('${groupId}'); e.style.display = e.style.display === 'none' ? 'block' : 'none';"
                                 onmouseover="this.style.background='rgba(255,255,255,0.05)'"
                                 onmouseout="this.style.background='transparent'">
                                <h2 style="color:var(--accent); margin:0; font-size: 1.1rem;">${escapeHtml(headerText)}</h2>
                                <span style="margin-left:10px; color:var(--text-muted); font-size:0.8rem;">(Click to expand/collapse)</span>
                            </div>
                            <div id="${groupId}">${buildTableHTML(groupedBySource[src], '', groupId)}</div>
                        `;
                    });
                } else {
                    html += buildTableHTML(arrData, '', 'main-table');
                }
                container.innerHTML = html;
            } 
            // SINGLE HOST MODE
            else {
                if (tabName === 'Users') {
                    const local = currentComputer['LocalUsers'] ? (Array.isArray(currentComputer['LocalUsers']) ? currentComputer['LocalUsers'] : [currentComputer['LocalUsers']]) : [];
                    const priv = currentComputer['PrivilegedAccess'] ? (Array.isArray(currentComputer['PrivilegedAccess']) ? currentComputer['PrivilegedAccess'] : [currentComputer['PrivilegedAccess']]) : [];
                    
                    if (local.length > 0) html += buildTableHTML(local, '<h2 style="color:var(--accent);margin-bottom:10px;">Local Users</h2>', 'local-users');
                    if (priv.length > 0) html += buildTableHTML(priv, '<h2 style="color:var(--accent);margin-top:30px;margin-bottom:10px;">Privileged Access</h2>', 'priv-users');
                    
                    if (html === '') container.innerHTML = '<div class="empty-state">No users or privileges found.</div>';
                    else container.innerHTML = html;
                } else {
                const dataArray = currentComputer[tabName];
                if (!dataArray || dataArray.length === 0) {
                    container.innerHTML = '<div class="empty-state">No data collected for ' + tabName + '.</div>';
                } else {
                    let html = '';
                    if (tabName === 'ExecutionEvidence') {
                        html += `
                        <div style="margin-bottom: 15px; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 6px; display: flex; align-items: center; gap: 15px;">
                            <span style="font-weight: bold; color: var(--accent);">Load PECmd Data:</span>
                            <input type="file" id="pecmdUpload" accept=".csv" style="color: var(--text);">
                            <button onclick="handlePecmdUpload()" style="padding: 5px 15px; background: var(--accent); color: white; border: none; border-radius: 4px; cursor: pointer;">Import CSV</button>
                        </div>`;
                    }
                    
                    if (tabName === 'EventLogs') {
                        html += `
                        <div style="margin-bottom: 15px; padding: 10px; background: rgba(0,0,0,0.2); border-radius: 6px; display: flex; align-items: center; gap: 15px;">
                            <span style="font-weight: bold; color: var(--accent);">View Mode:</span>
                            <label style="color: var(--text-main); cursor: pointer;"><input type="radio" name="evtMode" value="chronological" ${!window.eventLogGroupMode ? 'checked' : ''} onchange="window.eventLogGroupMode=false; renderTable('EventLogs');"> Chronological</label>
                            <label style="color: var(--text-main); cursor: pointer;"><input type="radio" name="evtMode" value="grouped" ${window.eventLogGroupMode ? 'checked' : ''} onchange="window.eventLogGroupMode=true; renderTable('EventLogs');"> Grouped by Event ID</label>
                        </div>`;
                    }
                    
                    const arrData = Array.isArray(dataArray) ? dataArray : [dataArray];
                    
                    let shouldGroup = false;
                    let groupProp = 'Source';
                    
                    if (tabName === 'EventLogs' && window.eventLogGroupMode) {
                        shouldGroup = true;
                        groupProp = 'EventId';
                    } else if (tabName !== 'EventLogs' && arrData.some(i => i && i.Source)) {
                        shouldGroup = true;
                        groupProp = 'Source';
                    }
                    
                    if (shouldGroup) {
                        const groupedBySource = {};
                        arrData.forEach(item => {
                            if (!item) return;
                            const src = item[groupProp] || ('Unknown ' + groupProp);
                            if (!groupedBySource[src]) groupedBySource[src] = [];
                            groupedBySource[src].push(item);
                        });
                        
                        Object.keys(groupedBySource).forEach((src, idx) => {
                            const groupId = 'group-' + tabName + '-' + idx;
                            let headerText = src;
                            if (groupProp === 'EventId') {
                                const fItem = groupedBySource[src][0];
                                const eName = (fItem && fItem.EventName && fItem.EventName !== 'Unknown') ? ': ' + fItem.EventName : '';
                                headerText = 'Event ID ' + src + eName;
                            }
                            html += `
                                <div style="display:flex; align-items:center; cursor:pointer; margin-top:20px; margin-bottom:10px; padding: 5px; border-radius: 4px; transition: background 0.2s;" 
                                     onclick="const e = document.getElementById('${groupId}'); e.style.display = e.style.display === 'none' ? 'block' : 'none';"
                                     onmouseover="this.style.background='rgba(255,255,255,0.05)'"
                                     onmouseout="this.style.background='transparent'">
                                    <h2 style="color:var(--accent); margin:0; font-size: 1.1rem;">${escapeHtml(headerText)}</h2>
                                    <span style="margin-left:10px; color:var(--text-muted); font-size:0.8rem;">(Click to expand/collapse)</span>
                                </div>
                                <div id="${groupId}">${buildTableHTML(groupedBySource[src], '', groupId)}</div>
                            `;
                        });
                    } else {
                        html += buildTableHTML(arrData, '', 'main-table');
                    }
                    container.innerHTML = html;
                }
            }
            } // Close the SINGLE HOST MODE else block
            
            if (activeFilterId) {
                const filterElem = document.getElementById(activeFilterId);
                if (filterElem) {
                    filterElem.focus();
                    if (activeFilterStart !== null) filterElem.setSelectionRange(activeFilterStart, activeFilterStart);
                }
            }
        }
        
        function handlePecmdUpload() {
            const fileInput = document.getElementById('pecmdUpload');
            if (!fileInput || !fileInput.files || fileInput.files.length === 0) {
                alert("Please select a PECmd CSV file first.");
                return;
            }
            const file = fileInput.files[0];
            const reader = new FileReader();
            reader.onload = function(e) {
                const text = e.target.result;
                const lines = text.split('\n');
                if (lines.length < 2) return;
                
                const headers = lines[0].split(',');
                const exeIdx = headers.findIndex(h => h.includes('ExecutableName'));
                const fileIdx = headers.findIndex(h => h.includes('SourceFilename'));
                const runCountIdx = headers.findIndex(h => h.includes('RunCount'));
                const lastRunIdx = headers.findIndex(h => h.includes('LastRun'));
                const createdIdx = headers.findIndex(h => h.includes('SourceCreated'));
                
                if (exeIdx === -1) {
                    alert("Could not find 'ExecutableName' column in CSV.");
                    return;
                }
                
                let count = 0;
                for (let i = 1; i < lines.length; i++) {
                    if (!lines[i].trim()) continue;
                    
                    const row = lines[i].split(/,(?=(?:(?:[^"]*"){2})*[^"]*$)/);
                    if (row.length > exeIdx) {
                        let exeName = row[exeIdx].replace(/^"|"$/g, '');
                        let fileName = fileIdx !== -1 && row.length > fileIdx ? row[fileIdx].replace(/^"|"$/g, '') : "";
                        let runCount = runCountIdx !== -1 && row.length > runCountIdx ? row[runCountIdx].replace(/^"|"$/g, '') : "";
                        let lastRun = lastRunIdx !== -1 && row.length > lastRunIdx ? row[lastRunIdx].replace(/^"|"$/g, '') : "";
                        let created = createdIdx !== -1 && row.length > createdIdx ? row[createdIdx].replace(/^"|"$/g, '') : "";
                        
                        if (!currentComputer.ExecutionEvidence) {
                            currentComputer.ExecutionEvidence = [];
                        } else if (!Array.isArray(currentComputer.ExecutionEvidence)) {
                            currentComputer.ExecutionEvidence = [currentComputer.ExecutionEvidence];
                        }
                        
                        currentComputer.ExecutionEvidence.push({
                            Executable: exeName,
                            FileName: fileName,
                            CreationTime: created,
                            LastWriteTime: lastRun,
                            RunCount: runCount,
                            Source: "PECmd Import"
                        });
                        count++;
                    }
                }
                alert(`Successfully imported ${count} records!`);
                renderTable('ExecutionEvidence');
            };
            reader.readAsText(file);
        }

        function extractTimestamp(item, category) {
            if (!item) return null;
            if (item.EventTime) return parseCustomDate(item.EventTime);
            if (item.CreationDate) return parseCustomDate(item.CreationDate);
            if (item.StartTime) return parseCustomDate(item.StartTime);
            if (item.LastLogon) return parseCustomDate(item.LastLogon);
            if (item.CreationTime) return parseCustomDate(item.CreationTime);
            return null;
        }

        function renderTimeline() {
            const container = document.getElementById('tableContainer');
            if (!currentComputer) {
                container.innerHTML = '<div class="empty-state">Select a system first.</div>';
                return;
            }

            let events = [];
            const timestampCats = ['Processes', 'ScheduledTasks', 'LocalUsers', 'StartupFiles', 'ExecutionEvidence', 'EventLogs'];
            
            timestampCats.forEach(cat => {
                const arr = currentComputer[cat];
                if (!arr) return;
                const items = Array.isArray(arr) ? arr : [arr];
                
                items.forEach(item => {
                    const ts = extractTimestamp(item, cat);
                    if (ts && !isNaN(ts)) {
                        let summary = '';
                        if (cat === 'Processes') summary = `Process Started: ${item.Name || item.CommandLine}`;
                        else if (cat === 'ScheduledTasks') summary = `Task Executed: ${item.TaskName}`;
                        else if (cat === 'LocalUsers') summary = `User Logon: ${item.Username}`;
                        else if (cat === 'StartupFiles') summary = `Startup File Created: ${item.Path}`;
                        else if (cat === 'ExecutionEvidence') summary = `Executed: ${item.Executable}`;
                        else if (cat === 'EventLogs') summary = `[${item.EventId}] ${item.Provider}: ${item.Message}`;

                        events.push({
                            time: ts,
                            category: cat,
                            summary: summary
                        });
                    }
                });
            });

            if (events.length === 0) {
                container.innerHTML = '<div class="empty-state">No timeline events found for this system.</div>';
                return;
            }

            events.sort((a, b) => b.time - a.time);

            let html = '<table><thead><tr><th>Timestamp</th><th>Category</th><th>Event Summary</th></tr></thead><tbody>';
            events.forEach(ev => {
                let catColor = '#cbd5e1';
                if (ev.category === 'Processes') catColor = '#60a5fa';
                if (ev.category === 'EventLogs') catColor = '#f87171';
                if (ev.category === 'StartupFiles') catColor = '#fbbf24';
                if (ev.category === 'ScheduledTasks') catColor = '#34d399';
                if (ev.category === 'ExecutionEvidence') catColor = '#c084fc';
                
                html += `<tr>
                    <td style="white-space: nowrap;" onclick="showCellModal(this)">${ev.time.toLocaleString()}</td>
                    <td onclick="showCellModal(this)"><span style="color: ${catColor}; font-weight: bold;">${ev.category}</span></td>
                    <td onclick="showCellModal(this)"><div class="td-content">${escapeHtml(ev.summary)}</div></td>
                </tr>`;
            });
            html += '</tbody></table>';
            container.innerHTML = html;
        }

        function renderProcessTree() {
            const container = document.getElementById('tableContainer');
            if (!currentComputer) {
                container.innerHTML = '<div class="empty-state">Select a system first.</div>';
                return;
            }

            const procs = currentComputer['Processes'];
            if (!procs || procs.length === 0) {
                container.innerHTML = '<div class="empty-state">No process data available.</div>';
                return;
            }

            let procArray = Array.isArray(procs) ? procs : [procs];
            
            // Apply signed filter if needed
            const hideSigned = document.getElementById('filterSigned') ? document.getElementById('filterSigned').checked : false;
            if (hideSigned) {
                procArray = procArray.filter(p => !(p.Signer && p.Signer !== 'Invalid/NotSigned' && p.Signer !== 'N/A' && p.Signer.trim() !== ''));
            }

            // Build dictionary
            const pDict = {};
            procArray.forEach(p => {
                const pid = p.ProcessId !== undefined ? p.ProcessId : p.Id;
                pDict[pid] = { ...p, children: [], network: [], services: [], _pid: pid };
            });

            // Correlate Network Connections
            const net = currentComputer['NetworkConnections'];
            if (net) {
                (Array.isArray(net) ? net : [net]).forEach(n => {
                    if (n && n.OwningProcess && pDict[n.OwningProcess]) {
                        pDict[n.OwningProcess].network.push(n);
                    }
                });
            }

            // Correlate Services
            const svcs = currentComputer['Services'];
            if (svcs) {
                (Array.isArray(svcs) ? svcs : [svcs]).forEach(s => {
                    if (s && s.ProcessId && pDict[s.ProcessId]) {
                        pDict[s.ProcessId].services.push(s);
                    }
                });
            }

            // Build hierarchy
            const roots = [];
            Object.values(pDict).forEach(pNode => {
                if (pNode.ParentProcessId !== null && pNode.ParentProcessId !== undefined && pDict[pNode.ParentProcessId]) {
                    pDict[pNode.ParentProcessId].children.push(pNode);
                } else {
                    roots.push(pNode);
                }
            });

            if (roots.length === 0) {
                container.innerHTML = '<div class="empty-state">No root processes found (maybe filtered?).</div>';
                return;
            }

            // Sort roots by PID
            roots.sort((a,b) => a._pid - b._pid);

            function buildHtml(nodes) {
                let html = '';
                nodes.forEach(n => {
                    let procText = `[${n._pid}] ${n.Name || 'Unknown'} - ${n.CommandLine || n.Path || ''}`;
                    let contentHtml = `<div class="tree-node-content" onclick="showCellModal(this)">
                        <span>${escapeHtml(procText)}</span>`;
                    
                    n.services.forEach(s => {
                        let sText = s.ServiceRaw ? s.ServiceRaw : `Service: ${s.Name} (${s.State})`;
                        contentHtml += `<span class="tree-badge service" onclick="event.stopPropagation(); showCellModal(this)">${escapeHtml(sText)}</span>`;
                    });
                    
                    n.network.forEach(nt => {
                        let nText = nt.ConnectionRaw ? nt.ConnectionRaw : `Net: ${nt.Protocol} ${nt.LocalAddress}:${nt.LocalPort} -> ${nt.RemoteAddress || '*'}:${nt.RemotePort || '*'} (${nt.State})`;
                        contentHtml += `<span class="tree-badge network" onclick="event.stopPropagation(); showCellModal(this)">${escapeHtml(nText)}</span>`;
                    });
                    
                    contentHtml += `</div>`;
                    
                    html += `<li>${contentHtml}`;
                    if (n.children.length > 0) {
                        n.children.sort((a,b) => a._pid - b._pid);
                        html += `<ul class="process-tree">` + buildHtml(n.children) + `</ul>`;
                    }
                    html += `</li>`;
                });
                return html;
            }

            container.innerHTML = `<ul class="process-tree process-tree-root" style="padding: 20px;">${buildHtml(roots)}</ul>`;
        }

        function renderSearchResults() {
            const container = document.getElementById('tableContainer');
            if (searchResultsData.length === 0) {
                container.innerHTML = '<div class="empty-state">No matching results found.</div>';
                return;
            }
            
            const searchLatestAll = document.getElementById('searchLatestAllSystems') ? document.getElementById('searchLatestAllSystems').checked : false;
            const searchAllTime = document.getElementById('searchAllDatasets') ? document.getElementById('searchAllDatasets').checked : false;
            const searchAll = searchLatestAll || searchAllTime;
            
            let html = '';
            searchResultsData.forEach(resultGroup => {
                const titleText = searchAll ? 
                    `${escapeHtml(resultGroup.system)} - ${resultGroup.category}` : 
                    `${resultGroup.category}`;
                    
                html += `<h3 style="margin-top: 20px; margin-bottom: 10px; color: var(--accent-hover);">${titleText} (${resultGroup.items.length} matches)</h3>`;
                
                const arr = resultGroup.items;
                let tableHtml = '<table><thead><tr>';
                
                let keys = new Set();
                arr.forEach(item => {
                    if(item) Object.keys(item).forEach(k => keys.add(k));
                });
                keys = Array.from(keys);
                
                if (resultGroup.category === 'FirewallRules') {
                    keys = keys.filter(k => k !== 'Program' && k !== 'Profile');
                }
                
                keys.forEach(k => {
                    tableHtml += `<th>${escapeHtml(k)}</th>`;
                });
                tableHtml += '</tr></thead><tbody>';
                
                arr.forEach(item => {
                    tableHtml += '<tr>';
                    keys.forEach(k => {
                        tableHtml += `<td onclick="showCellModal(this)"><div class="td-content">${escapeHtml(item ? item[k] : null)}</div></td>`;
                    });
                    tableHtml += '</tr>';
                });
                tableHtml += '</tbody></table>';
                
                html += tableHtml;
            });
            
            container.innerHTML = html;
        }
        
        function getFlaggedItems() {
            try { 
                let items = JSON.parse(localStorage.getItem('ffs_flagged_items')) || []; 
                if (typeof groupedSystems !== 'undefined' && Object.keys(groupedSystems).length > 0) {
                    const validSystems = new Set(Object.keys(groupedSystems));
                    const originalLength = items.length;
                    items = items.filter(f => validSystems.has(f.system));
                    if (items.length < originalLength) {
                        saveFlaggedItems(items);
                    }
                }
                return items;
            } catch(e) { return []; }
        }
        
        function saveFlaggedItems(items) {
            localStorage.setItem('ffs_flagged_items', JSON.stringify(items));
        }
        
        function hashItem(item) {
            return JSON.stringify(item);
        }
        
        window.showAllFlaggedHosts = false;
        function toggleFlaggedHosts(isChecked) {
            window.showAllFlaggedHosts = isChecked;
            renderFlaggedItems();
        }

        function isItemFlagged(item) {
            const flags = getFlaggedItems();
            const str = hashItem(item);
            return flags.some(f => hashItem(f.data) === str);
        }

        function toggleFlag(trId, event) {
            event.stopPropagation();
            const btn = event.currentTarget;
            const itemObj = window.renderedItems[trId];
            if (!itemObj) return;
            
            let flags = getFlaggedItems();
            const str = hashItem(itemObj.data);
            const idx = flags.findIndex(f => hashItem(f.data) === str);
            
            if (idx >= 0) {
                flags.splice(idx, 1);
                btn.classList.remove('flagged');
                btn.innerHTML = '&#9872;';
            } else {
                flags.push(itemObj);
                btn.classList.add('flagged');
                btn.innerHTML = '&#128681;';
            }
            saveFlaggedItems(flags);
            
            if (currentTab === 'FlaggedItems') {
                renderFlaggedItems();
            }
        }
        
        function renderFlaggedItems() {
            const container = document.getElementById('tableContainer');
            let flags = getFlaggedItems();
            
            if (!window.showAllFlaggedHosts && selectedHostname) {
                  const curTs = (typeof currentComputer !== 'undefined' && currentComputer ? currentComputer.Timestamp || '' : '');
                  flags = flags.filter(f => f.system === selectedHostname && (!f.timestamp || f.timestamp === curTs));
            }
            
            const toggleHtml = `
            <div style="margin-bottom: 15px; display:flex; gap:15px; align-items:center;">
                <button onclick="exportFlaggedItems()" style="background:var(--accent); color:white; border:none; padding:8px 15px; border-radius:4px; cursor:pointer; font-weight:bold; transition: background 0.2s;">&#128190; Export Flagged Items to CSV</button>
                <label style="color:var(--text-main); font-weight:bold; cursor:pointer; display:flex; align-items:center;">
                    <input type="checkbox" style="margin-right:6px;" ${window.showAllFlaggedHosts ? 'checked' : ''} onchange="toggleFlaggedHosts(this.checked)"> 
                    Include all hosts and historical datasets
                </label>
            </div>`;

            if (flags.length === 0) {
                let msg = '<div class="empty-state">No items have been flagged yet. Click the &#9872; icon on any row to bookmark it.</div>';
                if (!window.showAllFlaggedHosts && getFlaggedItems().length > 0) {
                     msg = '<div class="empty-state">No flagged items for this host. Check "Include all hosts" or select another host.</div>';
                }
                container.innerHTML = toggleHtml + msg;
                return;
            }
            
            let html = toggleHtml;
            
            const grouped = {};
            flags.forEach(f => {
                if (!grouped[f.category]) grouped[f.category] = [];
                grouped[f.category].push(f);
            });
            
            Object.keys(grouped).forEach(cat => {
                const titleHtml = `<div class="group-header" style="margin-top:20px; margin-bottom:10px; font-size:1.1rem; font-weight:bold; color:var(--accent-hover);">${cat}</div>`;
                const rawData = grouped[cat].map(g => {
                    let d = { 'System': g.system };
                    Object.assign(d, g.data);
                    return d;
                });
                html += buildTableHTML(rawData, titleHtml, 'flagged-' + cat);
            });
            
            container.innerHTML = html;
        }

        function exportFlaggedItems() {
            let flags = getFlaggedItems();
            if (!window.showAllFlaggedHosts && selectedHostname) {
                  const curTs = (typeof currentComputer !== 'undefined' && currentComputer ? currentComputer.Timestamp || '' : '');
                  flags = flags.filter(f => f.system === selectedHostname && (!f.timestamp || f.timestamp === curTs));
            }
            if (flags.length === 0) return;
            
            let csvContent = "data:text/csv;charset=utf-8,";
            let allKeys = new Set(['System', 'Category']);
            flags.forEach(f => {
                if (f.data) Object.keys(f.data).forEach(k => allKeys.add(k));
            });
            let keys = Array.from(allKeys);
            
            csvContent += keys.map(k => `"${k}"`).join(",") + "\r\n";
            
            flags.forEach(f => {
                let row = keys.map(k => {
                    if (k === 'System') return `"${(f.system||'').toString().replace(/"/g, '""')}"`;
                    if (k === 'Category') return `"${(f.category||'').toString().replace(/"/g, '""')}"`;
                    let val = f.data[k];
                    if (val === null || val === undefined) val = "";
                    return `"${val.toString().replace(/"/g, '""')}"`;
                });
                csvContent += row.join(",") + "\r\n";
            });
            
            const encodedUri = encodeURI(csvContent);
            const link = document.createElement("a");
            link.setAttribute("href", encodedUri);
            link.setAttribute("download", "FFS_Flagged_Items.csv");
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
        }

        document.querySelector('.tab').classList.add('active');
    </script>
</body>
</html>
'@
$HtmlContent | Out-File -FilePath $HtmlPath -Encoding UTF8

Write-Output "DFIR Collection Complete. Results saved in $OutputDirectory"

