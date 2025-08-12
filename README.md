# Network Configurator Script (Bash)

A Bash script to manage network interface settings on Linux systems (Ubuntu/Debian and derivatives).

---

## Description

This script allows you to:

- Automatically detect the active network manager (`NetworkManager`, `netplan`, or `systemd-networkd`).
- Display the status of network interfaces (link state, IP addresses, gateway, DNS).
- Select a network interface automatically (with cable connected) or manually.
- Switch between DHCP and static IP configuration.
- Apply changes via the appropriate network manager.
- Roll back to previous network settings if needed.
- Validate entered IP addresses and subnet masks.

---

## Supported Network Managers

- NetworkManager
- netplan
- systemd-networkd

---

## Requirements

- Run the script as `root` or via `sudo`.
- Linux system using one of the supported network managers.
- Installed utilities: `nmcli`, `netplan`, `systemctl`, `ip`, `awk`, `grep`, `tee`.

---

## Usage

1. Clone the repository or download the script.
2. Make the script executable:
   
   chmod +x network-configurator.sh
   
3. Run the script with administrative privileges
   sudo ./network-configurator.sh
   
4. Follow the prompts to select the interface and configure network settings.
   


За потреби зробіть відкат змін.
