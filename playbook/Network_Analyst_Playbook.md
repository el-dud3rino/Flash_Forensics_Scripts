# Network Security Analyst Playbook

This playbook provides a checklist of commands and configurations for a network security analyst to audit and configure core network infrastructure. It covers Cisco, Vyatta (VyOS), and pfSense environments, focusing on identifying common security misconfigurations, validating ACLs, and configuring network visibility (SPAN/NetFlow) for Security Onion or ELK stacks.

Each section includes a **Why / Abuse** note explaining the analytic reason for the check and how attackers exploit the corresponding weakness, mapped to [MITRE ATT&CK](https://attack.mitre.org/) where a technique applies. Network devices are high-value targets: they sit in the traffic path, are rarely re-imaged, and a compromise gives an adversary durable, stealthy control over routing, filtering, and visibility (ATT&CK "Network Devices" platform).

## Table of Contents
- [Cisco (IOS / NX-OS)](#cisco-ios--nx-os)
  - [Service Configuration Audits](#service-configuration-audits)
  - [Access Control Lists (ACLs)](#access-control-lists-acls)
  - [Common Security Mistakes](#common-security-mistakes)
  - [Configuring SPAN (Port Mirroring)](#configuring-span-port-mirroring)
  - [Configuring NetFlow](#configuring-netflow)
- [Vyatta (VyOS)](#vyatta-vyos)
  - [Service Configuration Audits](#service-configuration-audits-1)
  - [Firewall and ACL Checks](#firewall-and-acl-checks)
  - [Common Security Mistakes](#common-security-mistakes-1)
  - [Configuring Port Mirroring (SPAN)](#configuring-port-mirroring-span)
  - [Configuring NetFlow (sFlow)](#configuring-netflow-sflow)
- [pfSense](#pfsense)
  - [Service Configuration Audits](#service-configuration-audits-2)
  - [Firewall and ACL Checks](#firewall-and-acl-checks-1)
  - [Common Security Mistakes](#common-security-mistakes-2)
  - [Configuring Port Mirroring (SPAN)](#configuring-port-mirroring-span-1)
  - [Configuring NetFlow (softflowd)](#configuring-netflow-softflowd)

---

## Cisco (IOS / NX-OS)

### Service Configuration Audits
- **Goal**: Verify that only secure management protocols are enabled.
- **Description**: Ensures that Telnet and HTTP are disabled, and SSH/HTTPS are strictly enforced. Also audits SNMP community strings.
- **Why / Abuse**: The management plane is how an adversary takes durable control of the device. Cleartext protocols (Telnet, HTTP) expose credentials to sniffing (T1040) and on-path capture; weak or default SNMP community strings (`public`/`private`) allow config readout and, with RW access, full reconfiguration (T1078 valid accounts, T1602 data from configuration repository). Confirm cleartext services are off and management is restricted to trusted sources.
- **Commands**:
  - *Check running services*: `show running-config | include (ip http|line vty|snmp-server)`
  - *Verify SSH is enabled (Telnet disabled)*: `show ip ssh`, `show crypto key mypubkey rsa`
  - *Verify active management sessions*: `show users`, `show tcp brief`

### Access Control Lists (ACLs)
- **Goal**: Audit ingress and egress filtering rules.
- **Description**: Reviews configured ACLs and their application to specific interfaces.
- **Why / Abuse**: ACLs are the device's segmentation boundary. Attackers who gain config access weaken or bypass them to open lateral paths, permit C2, or defeat segmentation - "network boundary bridging" (T1599). Missing egress filtering also enables exfiltration and outbound C2. Verify each ACL's content *and* that it is actually applied to the intended interface/direction (a defined-but-unapplied ACL is a common silent gap); hit counts reveal whether rules are matching real traffic.
- **Commands**:
  - *List all ACLs and hit counts*: `show access-lists`
  - *See where ACLs are applied*: `show ip interface | include (line protocol|access list)`
  - *Check specific interface config*: `show running-config interface GigabitEthernet0/1`

### Common Security Mistakes
- **Goal**: Identify low-hanging fruit and baseline security failures.
- **Description**: Analysts should hunt for default credentials, unencrypted passwords in configs, open unused ports, and lack of logging.
- **Why / Abuse**: These are the weaknesses adversaries look for first. Default/weak credentials give immediate access (T1078.001); Type 0 (cleartext) or reversible Type 7 passwords in the config are trivially recovered credentials (T1552.001 unsecured credentials); unused, un-shut ports allow rogue physical connections; and absent logging blinds detection and lets an intruder operate and clear tracks unseen (T1562.008). Centralized logging to a SIEM is what makes device tampering visible after the fact.
- **Commands**:
  - *Check for unencrypted passwords*: `show running-config | include password` (Ensure `service password-encryption` is set, and prefer Type 8/9 secrets over Type 7).
  - *Check for unused active ports*: `show interface status` (Unused ports should be administratively down or assigned to a dead VLAN).
  - *Check logging configuration*: `show logging` (Ensure logs are sent to a centralized SIEM/syslog server).

### Configuring SPAN (Port Mirroring)
- **Goal**: Forward raw packet copies to a Security Onion/Zeek sensor.
- **Description**: Configures a local SPAN session to mirror traffic from a production interface to the IDS sensor interface.
- **Why / Abuse**: SPAN is how you gain full-packet visibility for IDS/NSM without inline risk - the raw truth of what crossed the wire, which endpoint logs can be tampered to hide. Defensively, confirm the mirror covers the intended traffic and the sensor port carries no IP (so it cannot be attacked back). Conversely, an *unauthorized* SPAN/monitor session configured by an intruder is itself a sniffing/collection technique (T1040) - audit for monitor sessions you did not create.
- **Commands**:
  ```text
  configure terminal
  monitor session 1 source interface GigabitEthernet0/1 both
  monitor session 1 destination interface GigabitEthernet0/2
  end
  show monitor session 1
  ```

### Configuring NetFlow
- **Goal**: Export flow telemetry (metadata) to an ELK/Security Onion collector.
- **Description**: Configures Flexible NetFlow to track connections and export them to a collector IP on port 2055.
- **Why / Abuse**: NetFlow gives scalable who-talked-to-whom metadata (connections, volumes, ports) that survives even when full packet capture is impractical - ideal for spotting beaconing, scanning, and exfiltration patterns across the environment. It is a foundational detection feed; ensure it is enabled on the right interfaces and that the collector receives records. Attackers who control the device may disable or redirect flow export to reduce visibility (T1562.008).
- **Commands**:
  ```text
  configure terminal
  flow record SEC-ONION-RECORD
    match ipv4 source address
    match ipv4 destination address
    match transport source-port
    match transport destination-port
    collect counter bytes long
    collect counter packets long
  flow exporter SEC-ONION-EXPORTER
    destination <Security_Onion_IP>
    transport udp 2055
  flow monitor SEC-ONION-MONITOR
    record SEC-ONION-RECORD
    exporter SEC-ONION-EXPORTER
  interface GigabitEthernet0/1
    ip flow monitor SEC-ONION-MONITOR input
  ```

---

## Vyatta (VyOS)

### Service Configuration Audits
- **Goal**: Verify secure management plane configurations.
- **Description**: Audits SSH configurations, web GUIs, and SNMP services.
- **Why / Abuse**: Same management-plane risk as Cisco: exposed SSH/GUI/SNMP on untrusted interfaces invites credential attacks and config theft (T1078, T1040). Confirm SSH uses key auth, the web GUI is not reachable from the WAN, and SNMP (if used) has strong, non-default communities or SNMPv3. Review active management connections for sessions from unexpected sources.
- **Commands**:
  - *Check SSH settings*: `show configuration commands | grep ssh`
  - *Check SNMP settings*: `show configuration commands | grep snmp`
  - *View active management connections*: `show system connections`

### Firewall and ACL Checks
- **Goal**: Audit firewall rulesets and interface bindings.
- **Description**: VyOS uses zone-based or interface-based firewalling. Analysts must check the rules and where they are applied.
- **Why / Abuse**: As with Cisco ACLs, the firewall is the segmentation boundary; weakened rules or a default-accept policy open lateral movement and exfiltration paths (T1599). A rule set that looks correct but is not bound to the interface/zone provides no protection - always verify bindings and rule hit statistics against expectations.
- **Commands**:
  - *Show all firewall rules*: `show firewall`
  - *Show firewall rule statistics/hits*: `show firewall statistics`
  - *Check interface firewall bindings*: `show interfaces | grep firewall`

### Common Security Mistakes
- **Goal**: Identify misconfigurations in routing and access.
- **Description**: Analysts should check for unrestricted SSH access, default VyOS user accounts, and lack of default-drop policies.
- **Why / Abuse**: Unrestricted SSH exposes the device to brute force from anywhere (T1110); the default `vyos` account with a known/weak password is a direct foothold (T1078.001); and a firewall lacking a default-drop policy fails open, permitting anything not explicitly denied. Each is a common, high-impact oversight an adversary probes for early.
- **Commands**:
  - *Check for default-drop on firewalls*: `show firewall name <RuleName> default-action` (Should be drop/reject).
  - *Check SSH listen addresses*: Ensure SSH isn't listening on public WAN interfaces.
  - *Check user accounts*: `show system login` (Ensure default `vyos` user has a strong password or is disabled).

### Configuring Port Mirroring (SPAN)
- **Goal**: Send a copy of traffic to a network security sensor.
- **Description**: VyOS handles mirroring natively via traffic-control (tc) or interface mirroring.
- **Why / Abuse**: Provides full-packet NSM visibility on VyOS edges/segments. Confirm the mirror source covers the traffic of interest and the destination feeds the sensor only. As on any platform, audit for mirror configurations you did not authorize, which could indicate an intruder collecting traffic (T1040).
- **Commands**:
  ```text
  configure
  set interfaces ethernet eth0 mirror ingress 'eth1'
  set interfaces ethernet eth0 mirror egress 'eth1'
  commit
  save
  ```

### Configuring NetFlow (sFlow)
- **Goal**: Send network flow metadata to ELK/Security Onion.
- **Description**: VyOS supports sFlow (and NetFlow via flow-accounting).
- **Why / Abuse**: Flow metadata from VyOS gives the same beaconing/scanning/exfil visibility as Cisco NetFlow, scalable across high-volume links. Verify flow-accounting is enabled on the correct interface and the collector is receiving records; loss of flow data may indicate tampering or misconfiguration that blinds detection (T1562.008).
- **Commands**:
  ```text
  configure
  set system flow-accounting interface 'eth0'
  set system flow-accounting netflow server <Security_Onion_IP> port '2055'
  set system flow-accounting netflow version '9'
  commit
  save
  show system flow-accounting
  ```

---

## pfSense

*(Note: pfSense is heavily GUI-driven, so many of these checks map to specific UI tabs, though the backend relies on FreeBSD CLI utilities).*

### Service Configuration Audits
- **Goal**: Ensure the web UI and SSH are secured.
- **Description**: Audits the management interface bindings and protocols.
- **Why / Abuse**: A firewall's own management interface is a top target - if the WebGUI or SSH is reachable from the WAN or uses weak/default credentials, the entire security boundary can be reconfigured by an attacker (T1078, T1556). Enforce HTTPS, key-based SSH only when needed, and restrict management to the LAN/trusted hosts; review active listeners to confirm nothing is exposed unexpectedly.
- **Commands (GUI & CLI)**:
  - *GUI*: Navigate to **System > Advanced > Admin Access**. Ensure Protocol is HTTPS, and SSH is only enabled if necessary (using key-based auth).
  - *CLI Check*: `cat /cf/conf/config.xml | grep -i sshd` (Check if sshd is enabled)
  - *CLI Check active connections*: `sockstat -46 | grep -E ':(443|22)'`

### Firewall and ACL Checks
- **Goal**: Audit pf (Packet Filter) firewall rules.
- **Description**: Reviews the active pf ruleset loaded in memory to ensure it matches intended security posture.
- **Why / Abuse**: The *loaded* pf ruleset is what actually enforces policy - it can differ from what the GUI implies if changes were made out of band. An intruder may add permissive rules for C2 or lateral movement, or loosen outbound filtering for exfiltration (T1599, T1562.004). Diff the live rules against the intended baseline and watch state/drop counters for anomalies.
- **Commands**:
  - *Show all loaded pf rules*: `pfctl -sr`
  - *Show firewall states/connections*: `pfctl -ss`
  - *Show firewall drop statistics*: `pfctl -si`

### Common Security Mistakes
- **Goal**: Identify pfSense-specific security risks.
- **Description**: Analysts should check for anti-lockout rule exposure, unrestricted outbound rules, and WebGUI exposure to WAN.
- **Why / Abuse**: pfSense ships permissive by design for usability, which becomes risk if left unhardened. An overly broad anti-lockout rule or WAN-exposed WebGUI hands an attacker the management plane (T1078, T1190 exploit public-facing application); an unrestricted "allow all" outbound rule enables C2 and exfiltration (no egress control); and disabled bogon/private blocking on the WAN permits spoofed and unroutable source traffic.
- **Checks**:
  - **Anti-Lockout Rule**: Ensure the default anti-lockout rule isn't overly permissive on interfaces where it shouldn't be.
  - **Default Allow All**: The default LAN rule is "Allow All to Any". This should be restricted to required outbound ports (80, 443, 53) in high-security environments.
  - **Bogons/Martians**: Ensure "Block bogon networks" and "Block private networks" are enabled on the WAN interface settings.

### Configuring Port Mirroring (SPAN)
- **Goal**: Forward raw traffic to a Security Onion sensor.
- **Description**: pfSense handles port mirroring by bridging interfaces and designating a SPAN port.
- **Why / Abuse**: Gives full-packet NSM at the perimeter where much C2 and exfiltration crosses. Ensure the SPAN interface has no IP (so the sensor is invisible and unattackable) and that the bridge mirrors the intended segment. Audit for bridges/SPAN ports you did not create, which an intruder could use to sniff traffic (T1040).
- **Steps**:
  1. Go to **Interfaces > Assignments > Bridges**.
  2. Create a new Bridge, selecting the interfaces you want to monitor (e.g., LAN).
  3. Set the **SPAN Port** to the physical interface connected to your Security Onion sensor.
  4. Ensure the SPAN interface is enabled but does *not* have an IP address assigned.

### Configuring NetFlow (softflowd)
- **Goal**: Export flow telemetry to an ELK stack.
- **Description**: pfSense uses the `softflowd` package to generate and export NetFlow data.
- **Why / Abuse**: Perimeter flow data is one of the highest-value detection feeds - it reveals outbound beaconing, data egress volumes, and connections to known-bad infrastructure even without full PCAP. Confirm `softflowd` is exporting from the correct interfaces to the collector; a gap in flow data at the edge is a serious visibility loss and can indicate tampering (T1562.008).
- **Steps**:
  1. Go to **System > Package Manager > Available Packages** and install `softflowd`.
  2. Navigate to **Services > softflowd**.
  3. Select the Interface to monitor (e.g., LAN, WAN).
  4. Set the **Host** to `<Security_Onion_IP>` and **Port** to `2055`.
  5. Select the **NetFlow Version** (v9 or IPFIX recommended).
  6. Save and apply. Verify flow reception on the ELK stack.
