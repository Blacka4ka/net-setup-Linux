#!/bin/bash
# universal-net-setup.sh — Універсальний скрипт налаштування мережі з бекапом

BACKUP_DIR="/root/net-backup-$(date +%F_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

clear
echo "--------------------------------------"
echo "=== Визначення менеджера мережі ==="

if systemctl is-active --quiet NetworkManager; then
    NET_CTRL="NetworkManager"
elif systemctl is-active --quiet systemd-networkd; then
    NET_CTRL="systemd-networkd"
elif command -v netplan &>/dev/null; then
    NET_CTRL="netplan"
else
    echo "❌ Не вдалося визначити менеджер мережі!"
    exit 1
fi

echo "✅ Використовується: $NET_CTRL"
echo "--------------------------------------"

echo "=== Пошук наявних IP у конфігах ==="
if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    for con in $(nmcli -t -f NAME con show | grep -v '^lo$'); do
        ip_info=$(nmcli -g IP4.ADDRESS con show "$con" 2>/dev/null)
        gw_info=$(nmcli -g IP4.GATEWAY con show "$con" 2>/dev/null)
        dns_info=$(nmcli -g IP4.DNS con show "$con" 2>/dev/null | paste -sd "," -)
        echo "Підключення: $con"
        echo "  IP: ${ip_info:-немає}"
        echo "  GW: ${gw_info:-немає}"
        echo "  DNS: ${dns_info:-немає}"
    done
elif [[ "$NET_CTRL" == "netplan" || "$NET_CTRL" == "systemd-networkd" ]]; then
    grep -R "address\|addresses\|gateway\|nameserver" /etc/netplan 2>/dev/null || echo "IP у netplan не знайдено"
fi
echo "--------------------------------------"

read -rp "Видалити існуючі налаштування перед зміною? (y/n): " CLEAR_CONF
if [[ "$CLEAR_CONF" =~ ^[Yy]$ ]]; then
    echo "📦 Робимо резервну копію у: $BACKUP_DIR"
    case $NET_CTRL in
        NetworkManager)
            cp -a /etc/NetworkManager "$BACKUP_DIR/" 2>/dev/null
            for c in $(nmcli -t -f NAME con show | grep -v '^lo$'); do
                nmcli con delete "$c" >/dev/null 2>&1
            done
            ;;
        netplan|systemd-networkd)
            cp -a /etc/netplan "$BACKUP_DIR/" 2>/dev/null
            sudo rm -f /etc/netplan/*.yaml
            ;;
    esac
    echo "✅ Старі налаштування збережені та видалені"
fi
echo "--------------------------------------"

interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

echo "=== Стан інтерфейсів ==="
for iface in "${interfaces[@]}"; do
    link_state=$(cat /sys/class/net/$iface/carrier 2>/dev/null)
    link_text=$([[ "$link_state" == "1" ]] && echo "✅ Кабель" || echo "❌ Немає лінку")
    ips=$(ip -4 addr show "$iface" | awk '/inet /{print $2}' | paste -sd "," -)
    gw=$(ip route show dev "$iface" | awk '/default/ {print $3}')
    dns=$(grep "nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd "," -)
    echo "  - $iface : $link_text , IP: ${ips:-немає} , GW: ${gw:-немає} , DNS: ${dns:-немає}"
done
echo "--------------------------------------"

read -rp "Вибрати інтерфейс автоматично (з лінком)? (y/n): " auto_iface
if [[ "$auto_iface" =~ ^[Yy]$ ]]; then
    selected_iface=""
    for iface in "${interfaces[@]}"; do
        if [[ "$(cat /sys/class/net/$iface/carrier 2>/dev/null)" == "1" ]]; then
            selected_iface=$iface
            break
        fi
    done
else
    read -rp "Введіть назву інтерфейсу: " selected_iface
fi

if [[ -z "$selected_iface" ]]; then
    echo "❌ Не знайдено активного інтерфейсу."
    exit 1
fi

echo "Вибрано інтерфейс: $selected_iface"
echo "--------------------------------------"

read -rp "Використовувати DHCP чи Статичний? (dhcp/static): " mode

if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    echo "⚙ Керуємо через nmcli..."
    nmcli con add type ethernet ifname "$selected_iface" con-name "$selected_iface" >/dev/null 2>&1 || true
    if [[ "$mode" == "dhcp" ]]; then
        sudo nmcli con mod "$selected_iface" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
    else
        while true; do
            read -rp "Введіть IP/маску (наприклад 192.168.1.10/24): " IPADDR
            [[ "$IPADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
            echo "❌ Формат невірний!"
        done
        read -rp "Введіть шлюз: " GATEWAY
        read -rp "Введіть DNS через кому: " DNS
        sudo nmcli con mod "$selected_iface" ipv4.method manual ipv4.addresses "$IPADDR" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS"
    fi
    sudo nmcli con up "$selected_iface"
else
    echo "⚙ Керуємо через netplan..."
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    if [[ "$mode" == "dhcp" ]]; then
        cat <<EOF | sudo tee $NETPLAN_FILE > /dev/null
network:
  version: 2
  ethernets:
    $selected_iface:
      dhcp4: true
EOF
    else
        while true; do
            read -rp "Введіть IP/маску (наприклад 192.168.1.10/24): " IPADDR
            [[ "$IPADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
            echo "❌ Формат невірний!"
        done
        read -rp "Введіть шлюз: " GATEWAY
        read -rp "Введіть DNS через кому: " DNS
        cat <<EOF | sudo tee $NETPLAN_FILE > /dev/null
network:
  version: 2
  ethernets:
    $selected_iface:
      addresses: [$IPADDR]
      routes:
        - to: default
          via: $GATEWAY
      nameservers:
        addresses: [${DNS//,/ }]
EOF
    fi
    sudo chmod 600 $NETPLAN_FILE
    sudo netplan apply
fi

echo "--------------------------------------"
echo "=== Новий стан інтерфейсу $selected_iface ==="
ip addr show $selected_iface
ip route show dev $selected_iface
echo "--------------------------------------"
echo "📦 Резервна копія конфігів збережена у: $BACKUP_DIR"
