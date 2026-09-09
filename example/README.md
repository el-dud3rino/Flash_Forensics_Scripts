# Example Dataset

A **fully synthetic** sample dashboard for demoing and testing Flash Forensics — including the **Ask AI** feature — without running a collection or exposing any real host data.

## How to use

Open **`example/index.html`** in a browser (double-click, or serve the folder). It loads `example/data.js`, which contains three sample datasets:

| Host | OS | Timestamp | Notes |
|------|----|-----------|-------|
| `WIN-CLIENT-01` | Windows | `14:24Z` | Baseline capture |
| `WIN-CLIENT-01` | Windows | `14:34Z` | Later capture with seeded suspicious activity |
| `ubuntu-web-01` | Linux | `14:26Z` | Web server with one suspicious session |

Because the Windows host has **two timelines**, you can exercise **Diff Timelines** and the AI "all timelines" context scopes.

## What's in it

A handful of rows per tab for both Windows and Linux, using the exact field schema the real collectors produce (Processes, Services, Scheduled Tasks, Network, Drivers, Defender, Persistence, Event Logs, Execution Evidence, etc.).

The later Windows capture and the Linux host include a few **clearly fake** "suspicious" artifacts so the Ask AI assistant has something to find — e.g. an unsigned `svch0st.exe` in `C:\Users\Public` with a Mark-of-the-Web download origin, an IFEO debugger and Run-key persistence, an `Unverified` driver, a Defender exclusion for `C:\Users\Public`, encoded-command and `IEX (New-Object Net.WebClient)` PowerShell events, failed logons from an external IP, and a Linux `curl … | bash` in bash history beaconing to a documentation-range address.

## Data safety

Every value is generic and invented. Hostnames, users (`jsmith`, `analyst`, `deploy`), paths, and hashes are placeholders; all "external" IPs use the reserved documentation ranges `203.0.113.0/24` and `198.51.100.0/24` (RFC 5737). No data from any real system is included.
