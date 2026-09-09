import subprocess
import json
import os
import glob
import time
import datetime
import hashlib
import re

def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, shell=True, text=True, capture_output=True)
        return res.stdout
    except:
        return ""

def get_file_hash(filepath):
    try:
        with open(filepath, 'rb') as f:
            return hashlib.sha256(f.read()).hexdigest()
    except:
        return ""

def split_host_port(hostport):
    """Split 'addr:port' into (addr, port), tolerating IPv6 like [::]:22 and '*:*'."""
    hp = hostport.strip()
    if not hp or ':' not in hp:
        return hp, ""
    host, _, port = hp.rpartition(':')
    return host.strip('[]'), port

def parse_cron_line(line, has_user, source):
    """Parse a single crontab line into structured fields, or None to skip.
    System crontabs (/etc/crontab, /etc/cron.d) carry a USER field between the
    schedule and the command; per-user crontabs (crontab -l) do not."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    # Skip environment assignments (e.g. SHELL=/bin/sh, PATH=..., MAILTO=root)
    if re.match(r'^[A-Za-z_][A-Za-z0-9_]*\s*=', line):
        return None
    user = ""
    if line.startswith('@'):
        toks = line.split(None, 2 if has_user else 1)
        schedule = toks[0]
        if has_user and len(toks) >= 3:
            user, command = toks[1], toks[2]
        else:
            command = toks[1] if len(toks) > 1 else ""
    else:
        toks = line.split(None, 6 if has_user else 5)
        if len(toks) <= 5:
            return None
        schedule = " ".join(toks[:5])
        if has_user:
            user = toks[5]
            command = toks[6] if len(toks) > 6 else ""
        else:
            command = toks[5]
    task_name = command.split()[0].split('/')[-1] if command.strip() else "cron"
    return {
        "TaskName": task_name,
        "Schedule": schedule,
        "User": user,
        "Command": command,
        "State": "Enabled",
        "Source": source
    }

results = {
    "ComputerName": os.uname()[1],
    "Timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "Processes": [],
    "Services": [],
    "ScheduledTasks": [],
    "NetworkConnections": [],
    "ArpTable": [],
    "RecycleBin": [],
    "LocalUsers": [],
    "SystemPersistence": [],
    "StartupFiles": [],
    "EventLogs": [],
    "SystemInfo": [],
    "ExecutionEvidence": [],
    "PrivilegedAccess": [],
    "InstalledSoftware": [],
    "FirewallRules": [],
    "LoggedinUsers": [],
    "DockerContainers": [],
    "DNSCache": [],
    "SMBSessions": [],
    "SMBShares": []
}

# 0. System Info
results["SystemInfo"].append({"Property": "Kernel", "Value": run_cmd("uname -a").strip()})
os_release = run_cmd("cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2").replace('\"', '').strip()
if os_release:
    results["SystemInfo"].append({"Property": "OS Version", "Value": os_release})
uptime_out = run_cmd("uptime -p").strip()
if not uptime_out:
    uptime_out = run_cmd("uptime").strip()
results["SystemInfo"].append({"Property": "Uptime", "Value": uptime_out})
ips = run_cmd("ip -4 addr show | grep inet | awk '{print $2}'").replace('\n', ', ').strip(', ')
if ips:
    results["SystemInfo"].append({"Property": "IP Addresses (IPv4)", "Value": ips})

dns_conf = run_cmd("cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$'").strip()
if dns_conf:
    results["SystemInfo"].append({"Property": "DNS Configuration", "Value": dns_conf})

w_out = run_cmd("w -h 2>/dev/null").strip()
if w_out:
    for line in w_out.split('\n'):
        parts = line.split()
        if len(parts) >= 3:
            results["LoggedinUsers"].append({
                "User": parts[0],
                "TTY": parts[1],
                "From": parts[2],
                "Idle": parts[4] if len(parts) > 4 else "",
                "Command": " ".join(parts[7:]) if len(parts) > 7 else ""
            })

docker_out = run_cmd("docker ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null").strip()
if docker_out:
    for line in docker_out.split('\n'):
        parts = line.split('|')
        if len(parts) >= 3:
            results["DockerContainers"].append({
                "Name": parts[0],
                "Image": parts[1],
                "Status": parts[2],
                "Ports": parts[3] if len(parts) > 3 else ""
            })

# 1. Processes
ps_out = run_cmd("ps -eo pid,ppid,user,start_time,command")
lines = ps_out.strip().split('\n')
if len(lines) > 1:
    for line in lines[1:]:
        parts = line.split(None, 4)
        if len(parts) == 5:
            pid = parts[0]
            ppid = parts[1]
            user = parts[2]
            start = parts[3]
            cmd = parts[4]
            path = ""
            try:
                path = os.readlink(f"/proc/{pid}/exe")
            except:
                path = cmd.split()[0]
                
            results["Processes"].append({
                "Id": pid,
                "ParentProcessId": ppid,
                "UserName": user,
                "StartTime": start,
                "CommandLine": cmd,
                "Name": path.split('/')[-1] if path else "",
                "Path": path,
                "SHA256": get_file_hash(f"/proc/{pid}/exe"),
                "Signer": "N/A"
            })

# 2. Services
svc_out = run_cmd("systemctl list-units --type=service --all --no-pager --no-legend")
if svc_out.strip():
    # Columns: UNIT LOAD ACTIVE SUB DESCRIPTION
    for line in svc_out.strip().split('\n'):
        line = line.strip()
        if not line:
            continue
        # systemd prefixes failed/inactive units with a status glyph (a non-word
        # char). Strip any leading non-word tokens so the unit name is parts[0].
        # (Kept ASCII-only: the payload is piped over SSH stdin and must survive
        # re-encoding through the local codepage.)
        line = re.sub(r'^[^\w]+', '', line)
        if not line:
            continue
        parts = line.split(None, 4)
        if len(parts) >= 4 and parts[0].endswith('.service'):
            results["Services"].append({
                "Name": parts[0],
                "DisplayName": parts[4] if len(parts) > 4 else "",
                "State": parts[2],       # active / inactive / failed
                "SubState": parts[3],    # running / exited / dead
                "StartMode": parts[1]    # loaded / not-found / masked
            })
else:
    # Fallback for SysV systems without systemd
    svc_out = run_cmd("service --status-all")
    for line in svc_out.strip().split('\n'):
        m = re.search(r'\[\s*([+\-?])\s*\]\s+(\S+)', line)
        if m:
            flag = m.group(1)
            state = {"+": "active", "-": "inactive"}.get(flag, "unknown")
            results["Services"].append({
                "Name": m.group(2),
                "DisplayName": "",
                "State": state,
                "SubState": "",
                "StartMode": ""
            })

# 3. Scheduled Tasks
# System-wide crontabs carry a USER field; per-user crontabs do not.
sys_cron = run_cmd("cat /etc/crontab /etc/cron.d/* 2>/dev/null")
for line in sys_cron.strip().split('\n'):
    task = parse_cron_line(line, has_user=True, source="System Crontab")
    if task:
        results["ScheduledTasks"].append(task)

for user in run_cmd("cut -d: -f1 /etc/passwd").strip().split('\n'):
    user = user.strip()
    if not user:
        continue
    user_cron = run_cmd(f"crontab -u {user} -l 2>/dev/null")
    for line in user_cron.strip().split('\n'):
        task = parse_cron_line(line, has_user=False, source=f"Crontab ({user})")
        if task:
            task["User"] = user
            results["ScheduledTasks"].append(task)

timer_out = run_cmd("systemctl list-timers --all --no-pager --no-legend")
for line in timer_out.strip().split('\n'):
    line = line.strip()
    if not line:
        continue
    parts = line.split()
    unit = next((p for p in parts if p.endswith('.timer')), "")
    activates = parts[-1] if parts and parts[-1].endswith('.service') else ""
    if not unit:
        continue
    results["ScheduledTasks"].append({
        "TaskName": activates or unit,
        "Schedule": "Systemd Timer",
        "User": "",
        "Command": unit,
        "State": "Active",
        "Source": "Systemd Timer"
    })

# 4. Network Connections
net_out = run_cmd("ss -tupan")
used_ss = bool(net_out.strip())
if not used_ss:
    net_out = run_cmd("netstat -tupan")

lines = net_out.strip().split('\n')
if len(lines) > 1:
    for line in lines[1:]:
        if not line.strip():
            continue
        parts = line.split()
        proto = state = laddr = lport = raddr = rport = ""
        owner_pid = proc_name = proc_path = ""

        # Owning process: ss prints users:(("name",pid=NNN,fd=N)); netstat prints NNN/name
        pid_match = re.search(r'pid=(\d+)', line) or re.search(r'\b(\d+)/\S+', line)
        if pid_match:
            owner_pid = pid_match.group(1)
        name_match = re.search(r'\(\("([^"]+)"', line) or re.search(r'\b\d+/(\S+)', line)
        if name_match:
            proc_name = name_match.group(1)

        if used_ss:
            # ss: Netid State Recv-Q Send-Q Local:Port Peer:Port [Process]
            if len(parts) >= 6:
                proto = parts[0].upper()
                state = parts[1]
                laddr, lport = split_host_port(parts[4])
                raddr, rport = split_host_port(parts[5])
        else:
            # netstat: Proto Recv-Q Send-Q Local Foreign [State] PID/Program
            if len(parts) >= 5:
                proto = parts[0].upper()
                laddr, lport = split_host_port(parts[3])
                raddr, rport = split_host_port(parts[4])
                # State column only exists for TCP; UDP rows put PID/Program here
                if len(parts) >= 6 and '/' not in parts[5]:
                    state = parts[5]

        # Enrich with the executable path from the collected process list
        if owner_pid:
            for p in results["Processes"]:
                if p["Id"] == owner_pid:
                    if not proc_name:
                        proc_name = p["Name"]
                    proc_path = p["Path"]
                    break

        results["NetworkConnections"].append({
            "LocalAddress": laddr,
            "LocalPort": lport,
            "RemoteAddress": raddr,
            "RemotePort": rport,
            "State": state,
            "Protocol": proto,
            "OwningProcess": owner_pid,
            "ProcessName": proc_name,
            "ProcessPath": proc_path
        })

# 4.5 ARP Table
arp_out = run_cmd("ip neigh show")
if arp_out:
    for line in arp_out.strip().split('\n'):
        if line.strip():
            parts = line.split()
            if len(parts) >= 1:
                ip = parts[0]
                mac = ""
                state = ""
                iface = ""
                if 'lladdr' in parts:
                    idx = parts.index('lladdr')
                    if idx + 1 < len(parts):
                        mac = parts[idx+1]
                if 'dev' in parts:
                    idx = parts.index('dev')
                    if idx + 1 < len(parts):
                        iface = parts[idx+1]
                state = parts[-1] if len(parts) > 1 else ""
                results["ArpTable"].append({
                    "IPAddress": ip,
                    "LinkLayerAddress": mac,
                    "State": state,
                    "InterfaceAlias": iface
                })
else:
    arp_out = run_cmd("arp -an")
    if arp_out:
        import re
        for line in arp_out.strip().split('\n'):
            if " at " in line:
                m = re.search(r'\((.*?)\)\s+at\s+(.*?)\s+.*on\s+(.*)', line)
                if m:
                    results["ArpTable"].append({
                        "IPAddress": m.group(1),
                        "LinkLayerAddress": m.group(2),
                        "State": "N/A",
                        "InterfaceAlias": m.group(3)
                    })

# 5. Local Users
try:
    with open('/etc/passwd', 'r') as f:
        for line in f:
            parts = line.strip().split(':')
            if len(parts) >= 7:
                results["LocalUsers"].append({
                    "Username": parts[0],
                    "UID": parts[2],
                    "GID": parts[3],
                    "HomeDirectory": parts[5],
                    "Shell": parts[6]
                })
except:
    pass

# 6. System Persistence
persist_paths = [
    "/etc/rc.local",
    "/etc/profile",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.ssh/authorized_keys",
    "/etc/ssh/sshd_config"
]
for p in persist_paths:
    expanded = os.path.expanduser(p)
    if os.path.exists(expanded):
        try:
            results["SystemPersistence"].append({
                "KeyName": p,
                "ValueData": "File exists, size: " + str(os.path.getsize(expanded)) + " bytes"
            })
        except:
            pass

lsmod_out = run_cmd("lsmod")
lines = lsmod_out.strip().split('\n')
if len(lines) > 1:
    for line in lines[1:]:
        if line:
            parts = line.split()
            if parts:
                mod_name = parts[0]
                results["SystemPersistence"].append({
                    "KeyName": f"Kernel Module: {mod_name}",
                    "ValueData": line.strip()
                })

# 7. Startup Files
startup_paths = ["~/.config/autostart/*.desktop", "/etc/xdg/autostart/*.desktop", "/etc/init.d/*"]
for p in startup_paths:
    for file in glob.glob(os.path.expanduser(p)):
        try:
            results["StartupFiles"].append({
                "Path": file,
                "CreationTime": time.ctime(os.path.getctime(file)),
                "LastWriteTime": time.ctime(os.path.getmtime(file)),
                "Length": os.path.getsize(file),
                "SHA256": get_file_hash(file),
                "Signer": "N/A"
            })
        except:
            pass

# 8. Event Logs
log_files = {
    "Auth": ["/var/log/auth.log", "/var/log/secure"],
    "Syslog": ["/var/log/syslog", "/var/log/messages"],
    "Dmesg": ["/var/log/dmesg"],
    "Daemon": ["/var/log/daemon.log"]
}

for provider, paths in log_files.items():
    out = ""
    for p in paths:
        if os.path.exists(p):
            out = run_cmd(f"tail -n 100 {p} 2>/dev/null")
            break # Found the log for this category, skip alternative
            
    if not out and provider == "Auth":
        out = run_cmd("journalctl -u ssh -n 100 --no-pager 2>/dev/null")
        
    if out:
        import datetime
        current_year = str(datetime.datetime.now().year)
        
        for line in out.strip().split('\n'):
            if line:
                username = ""
                status = ""
                
                # Extract event time
                event_time = ""
                iso_match = re.match(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[^\s]*)', line)
                if iso_match:
                    event_time = iso_match.group(1)
                else:
                    parts = line.split()
                    if len(parts) >= 3:
                        # Append current year if not present
                        if not re.search(r'\d{4}', " ".join(parts[:3])):
                            event_time = f"{current_year} {' '.join(parts[:3])}"
                        else:
                            event_time = " ".join(parts[:3])

                if provider == "Auth":
                    if "COMMAND=" in line:
                        cmd_match = re.search(r'COMMAND=(.*)', line)
                        if cmd_match:
                            results["ExecutionEvidence"].append({
                                "Executable": cmd_match.group(1).strip(),
                                "FileName": "sudo",
                                "CreationTime": event_time,
                                "LastWriteTime": event_time,
                                "Length": 0
                            })

                    if "Failed password" in line or "authentication failure" in line or "Invalid user" in line or "Unknown user" in line:
                        status = "Failed"
                    elif "Accepted" in line or "session opened" in line:
                        status = "Success"
                    elif "Disconnected" in line or "Connection closed" in line or "session closed" in line:
                        status = "Closed"
                    
                    user_match = re.search(r'(?:for\s+invalid\s+user\s+|for\s+unknown\s+user\s+|for\s+user\s+|for\s+|user\s+|user=)(?P<user>[a-zA-Z0-9_.-]+)', line, re.IGNORECASE)
                    if user_match:
                        u = user_match.group('user')
                        if u.lower() not in ['from', 'message', 'invalid', 'unknown', 'to']:
                            username = u

                results["EventLogs"].append({
                    "EventTime": event_time,
                    "EventId": provider,
                    "Provider": provider,
                    "Username": username,
                    "Status": status,
                    "Message": line,
                    "Details": line
                })

try:
    with open('/etc/passwd', 'r') as f:
        for line in f:
            parts = line.strip().split(':')
            if len(parts) >= 6:
                home = parts[5]
                hist_files = ['.bash_history', '.zsh_history', '.mysql_history']
                for hf in hist_files:
                    hist_path = os.path.join(home, hf)
                    if os.path.exists(hist_path):
                        hist_out = run_cmd(f"tail -n 50 {hist_path} 2>/dev/null")
                        for hline in hist_out.strip().split('\n'):
                            if hline:
                                results["ExecutionEvidence"].append({
                                    "Executable": hline,
                                    "FileName": hist_path,
                                    "CreationTime": "",
                                    "LastWriteTime": "",
                                    "Length": 0
                                })
except:
    pass

try:
    # 10. Privileged Access
    # Sudoers file
    sudoers_out = run_cmd("cat /etc/sudoers 2>/dev/null | grep -v '^#' | grep -v '^$'")
    for line in sudoers_out.strip().split('\n'):
        if line:
            parts = line.split(None, 1)
            name = parts[0] if parts else line
            perms = parts[1] if len(parts) > 1 else ""
            results["PrivilegedAccess"].append({
                "Group": "sudoers_file",
                "Name": name,
                "ObjectClass": "Configuration",
                "PrincipalSource": perms
            })
            
    # Sudo and Wheel groups
    group_out = run_cmd("cat /etc/group | grep -E '^(sudo|wheel):'")
    for line in group_out.strip().split('\n'):
        if line:
            parts = line.split(':')
            if len(parts) >= 4 and parts[3]:
                group_name = parts[0]
                members = parts[3].split(',')
                for mem in members:
                    if mem:
                        results["PrivilegedAccess"].append({
                            "Group": group_name,
                            "Name": mem,
                            "ObjectClass": "User",
                            "PrincipalSource": "LocalGroup"
                        })
except:
    pass

try:
    # 11. Installed Software
    dpkg_out = run_cmd("dpkg-query -W -f='${binary:Package}|${Version}|${Maintainer}\n' 2>/dev/null")
    if dpkg_out:
        for line in dpkg_out.strip().split('\n'):
            parts = line.split('|')
            if len(parts) >= 2:
                results["InstalledSoftware"].append({
                    "DisplayName": parts[0],
                    "DisplayVersion": parts[1],
                    "Publisher": parts[2] if len(parts) > 2 else "Unknown"
                })
    else:
        rpm_out = run_cmd("rpm -qa --qf '%{NAME}|%{VERSION}|%{VENDOR}\n' 2>/dev/null")
        if rpm_out:
            for line in rpm_out.strip().split('\n'):
                parts = line.split('|')
                if len(parts) >= 2:
                    results["InstalledSoftware"].append({
                        "DisplayName": parts[0],
                        "DisplayVersion": parts[1],
                        "Publisher": parts[2] if len(parts) > 2 else "Unknown"
                    })
    
    snap_out = run_cmd("snap list 2>/dev/null")
    lines = snap_out.strip().split('\n')
    if len(lines) > 1:
        for line in lines[1:]:
            parts = line.split()
            if len(parts) >= 3:
                results["InstalledSoftware"].append({
                    "DisplayName": parts[0] + " (snap)",
                    "DisplayVersion": parts[1],
                    "Publisher": parts[3] if len(parts) > 3 else "Unknown"
                })
except:
    pass

try:
    # 12. Firewall Rules
    ufw_out = run_cmd("ufw status numbered 2>/dev/null")
    if ufw_out and "Status: active" in ufw_out:
        for line in ufw_out.strip().split('\n'):
            if "[" in line and "]" in line:
                results["FirewallRules"].append({
                    "DisplayName": line.strip(),
                    "Direction": "In/Out",
                    "Action": "UFW Rule",
                    "Profile": "UFW",
                    "Details": line.strip()
                })
    else:
        firewalld_out = run_cmd("firewall-cmd --list-all 2>/dev/null")
        if firewalld_out:
            for line in firewalld_out.strip().split('\n'):
                if line.strip():
                    results["FirewallRules"].append({
                        "DisplayName": line.strip(),
                        "Direction": "N/A",
                        "Action": "Firewalld Config",
                        "Profile": "Firewalld",
                        "Details": line.strip()
                    })
        else:
            iptables_out = run_cmd("iptables -S 2>/dev/null")
            if iptables_out:
                for line in iptables_out.strip().split('\n'):
                    if line.startswith('-P') or line.startswith('-A'):
                        parts = line.split()
                        action = ""
                        if '-j' in parts:
                            action = parts[parts.index('-j') + 1]
                        elif '-P' in parts:
                            action = parts[-1]
                        
                        direction = parts[1] if len(parts) > 1 else ""
                        
                        results["FirewallRules"].append({
                            "DisplayName": line.strip(),
                            "Direction": direction,
                            "Action": action,
                            "Profile": "iptables",
                            "Details": line.strip()
                        })
except:
    pass

try:
    # 13. DNS Configuration
    if os.path.exists("/etc/resolv.conf"):
        with open("/etc/resolv.conf", "r") as f:
            for line in f:
                if not line.strip() or line.startswith("#"): continue
                results["DNSCache"].append({
                    "Entry": "Config",
                    "Name": "/etc/resolv.conf",
                    "Type": line.split()[0] if len(line.split()) > 0 else "",
                    "Status": "File",
                    "Data": line.strip(),
                    "TimeToLive": ""
                })
except:
    pass

try:
    # 14. Logged In Users
    who_out = run_cmd("who 2>/dev/null")
    if who_out:
        for line in who_out.strip().split('\n'):
            parts = line.split()
            if len(parts) >= 4:
                results["LoggedinUsers"].append({
                    "User": parts[0],
                    "Session": parts[1],
                    "ID": line[line.find('(')+1:line.find(')')] if '(' in line else "-",
                    "State": "Active",
                    "IdleTime": "-",
                    "LogonTime": f"{parts[2]} {parts[3]}"
                })
except:
    pass

try:
    # 15. Docker Containers
    docker_out = run_cmd("docker ps -a --format '{{json .}}' 2>/dev/null")
    if docker_out:
        for line in docker_out.strip().split('\n'):
            try:
                import json
                d = json.loads(line)
                results["DockerContainers"].append({
                    "Name": d.get("Names", ""),
                    "Image": d.get("Image", ""),
                    "Status": d.get("Status", ""),
                    "Ports": d.get("Ports", ""),
                    "ID": d.get("ID", "")
                })
            except:
                pass
except:
    pass

# 19. Recycle Bin
try:
    with open('/etc/passwd', 'r') as f:
        for line in f:
            parts = line.strip().split(':')
            if len(parts) >= 6:
                user = parts[0]
                home = parts[5]
                trash_info_dir = os.path.join(home, ".local/share/Trash/info")
                if os.path.exists(trash_info_dir):
                    for info_file in glob.glob(os.path.join(trash_info_dir, "*.trashinfo")):
                        try:
                            orig_path = ""
                            del_date = ""
                            with open(info_file, 'r') as tf:
                                for tline in tf:
                                    if tline.startswith("Path="):
                                        orig_path = tline.split("=", 1)[1].strip()
                                    elif tline.startswith("DeletionDate="):
                                        del_date = tline.split("=", 1)[1].strip()
                            results["RecycleBin"].append({
                                "User": user,
                                "OriginalPath": orig_path,
                                "DeletionTime": del_date,
                                "InfoFile": os.path.basename(info_file)
                            })
                        except:
                            pass
except:
    pass

print(json.dumps(results))
