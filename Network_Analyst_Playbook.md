# Network Security Analyst Playbook

This playbook provides a checklist of commands and configurations for a network security analyst to audit and configure core network infrastructure. It covers Cisco, Vyatta (VyOS), and pfSense environments, focusing on identifying common security misconfigurations, validating ACLs, and configuring network visibility (SPAN/NetFlow) for Security Onion or ELK stacks.

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
- **Commands**:
  - *Check running services*: `show running-config | include (ip http|line vty|snmp-server)`
  - *Verify SSH is enabled (Telnet disabled)*: `show ip ssh`, `show crypto key mypubkey rsa`
  - *Verify active management sessions*: `show users`, `show tcp brief`

### Access Control Lists (ACLs)
- **Goal**: Audit ingress and egress filtering rules.
- **Description**: Reviews configured ACLs and their application to specific interfaces.
- **Commands**:
  - *List all ACLs and hit counts*: `show access-lists`
  - *See where ACLs are applied*: `show ip interface | include (line protocol|access list)`
  - *Check specific interface config*: `show running-config interface GigabitEthernet0/1`

### Common Security Mistakes
- **Goal**: Identify low-hanging fruit and baseline security failures.
- **Description**: Analysts should hunt for default credentials, unencrypted passwords in configs, open unused ports, and lack of logging.
- **Commands**:
  - *Check for unencrypted passwords*: `show running-config | include password` (Ensure `service password-encryption` is set).
  - *Check for unused active ports*: `show interface status` (Unused ports should be administratively down or assigned to a dead VLAN).
  - *Check logging configuration*: `show logging` (Ensure logs are sent to a centralized SIEM/syslog server).

### Configuring SPAN (Port Mirroring)
- **Goal**: Forward raw packet copies to a Security Onion/Zeek sensor.
- **Description**: Configures a local SPAN session to mirror traffic from a production interface to the IDS sensor interface.
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
- **Commands**:
  - *Check SSH settings*: `show configuration commands | grep ssh`
  - *Check SNMP settings*: `show configuration commands | grep snmp`
  - *View active management connections*: `show system connections`

### Firewall and ACL Checks
- **Goal**: Audit firewall rulesets and interface bindings.
- **Description**: VyOS uses zone-based or interface-based firewalling. Analysts must check the rules and where they are applied.
- **Commands**:
  - *Show all firewall rules*: `show firewall`
  - *Show firewall rule statistics/hits*: `show firewall statistics`
  - *Check interface firewall bindings*: `show interfaces | grep firewall`

### Common Security Mistakes
- **Goal**: Identify misconfigurations in routing and access.
- **Description**: Analysts should check for unrestricted SSH access, default VyOS user accounts, and lack of default-drop policies.
- **Commands**:
  - *Check for default-drop on firewalls*: `show firewall name <RuleName> default-action` (Should be drop/reject).
  - *Check SSH listen addresses*: Ensure SSH isn't listening on public WAN interfaces.
  - *Check user accounts*: `show system login` (Ensure default `vyos` user has a strong password or is disabled).

### Configuring Port Mirroring (SPAN)
- **Goal**: Send a copy of traffic to a network security sensor.
- **Description**: VyOS handles mirroring natively via traffic-control (tc) or interface mirroring.
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
- **Commands (GUI & CLI)**:
  - *GUI*: Navigate to **System > Advanced > Admin Access**. Ensure Protocol is HTTPS, and SSH is only enabled if necessary (using key-based auth).
  - *CLI Check*: `cat /cf/conf/config.xml | grep -i sshd` (Check if sshd is enabled)
  - *CLI Check active connections*: `sockstat -46 | grep -E ':(443|22)'`

### Firewall and ACL Checks
- **Goal**: Audit pf (Packet Filter) firewall rules.
- **Description**: Reviews the active pf ruleset loaded in memory to ensure it matches intended security posture.
- **Commands**:
  - *Show all loaded pf rules*: `pfctl -sr`
  - *Show firewall states/connections*: `pfctl -ss`
  - *Show firewall drop statistics*: `pfctl -si`

### Common Security Mistakes
- **Goal**: Identify pfSense-specific security risks.
- **Description**: Analysts should check for anti-lockout rule exposure, unrestricted outbound rules, and WebGUI exposure to WAN.
- **Checks**:
  - **Anti-Lockout Rule**: Ensure the default anti-lockout rule isn't overly permissive on interfaces where it shouldn't be.
  - **Default Allow All**: The default LAN rule is "Allow All to Any". This should be restricted to required outbound ports (80, 443, 53) in high-security environments.
  - **Bogons/Martians**: Ensure "Block bogon networks" and "Block private networks" are enabled on the WAN interface settings.

### Configuring Port Mirroring (SPAN)
- **Goal**: Forward raw traffic to a Security Onion sensor.
- **Description**: pfSense handles port mirroring by bridging interfaces and designating a SPAN port.
- **Steps**:
  1. Go to **Interfaces > Assignments > Bridges**.
  2. Create a new Bridge, selecting the interfaces you want to monitor (e.g., LAN).
  3. Set the **SPAN Port** to the physical interface connected to your Security Onion sensor.
  4. Ensure the SPAN interface is enabled but does *not* have an IP address assigned.

### Configuring NetFlow (softflowd)
- **Goal**: Export flow telemetry to an ELK stack.
- **Description**: pfSense uses the `softflowd` package to generate and export NetFlow data.
- **Steps**:
  1. Go to **System > Package Manager > Available Packages** and install `softflowd`.
  2. Navigate to **Services > softflowd**.
  3. Select the Interface to monitor (e.g., LAN, WAN).
  4. Set the **Host** to `<Security_Onion_IP>` and **Port** to `2055`.
  5. Select the **NetFlow Version** (v9 or IPFIX recommended).
  6. Save and apply. Verify flow reception on the ELK stack.
