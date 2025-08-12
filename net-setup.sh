#!/bin/bash
set -e

clear
echo "=== Визначення менеджера мережі ==="

if systemctl is-active --quiet NetworkManager; then
    NET_CTRL="NetworkManager"
elif systemctl is-active --quiet systemd-networkd; then
    NET_CTRL="systemd-networkd"
elif command -v netplan &>/dev/null; then
    NET_CTRL="netplan"
else
    echo "Не вдалося визначити менеджер мережі!"
    exit 1
fi

echo "Використовується: $NET_CTRL"
echo "--------------------------------------"

# Визначаємо інтерфейси
interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

echo "=== Стан інтерфейсів ==="
for iface in "${interfaces[@]}"; do
    link_state=$(cat /sys/class/net/$iface/carrier 2>/dev/null || echo 0)
    link_text=$([[ "$link_state" == "1" ]] && echo "Кабель" || echo "Немає лінку")
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
        if [[ "$(cat /sys/class/net/$iface/carrier 2>/dev/null || echo 0)" == "1" ]]; then
            selected_iface=$iface
            break
        fi
    done
else
    read -rp "Введіть назву інтерфейсу: " selected_iface
fi

if [[ -z "$selected_iface" ]]; then
    echo "Не знайдено активного інтерфейсу."
    exit 1
fi

echo "Вибрано інтерфейс: $selected_iface"
echo "--------------------------------------"

# --- Зчитуємо поточні налаштування ---

if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    # Дізнаємося активне підключення для інтерфейсу
    current_con=$(nmcli -t -f NAME,DEVICE con show --active | grep ":$selected_iface$" | cut -d: -f1 || true)
    if [[ -z "$current_con" ]]; then
        current_con="$selected_iface"
    fi
    old_method=$(nmcli -g ipv4.method con show "$current_con" 2>/dev/null || echo "auto")
    old_ip=$(nmcli -g ipv4.addresses con show "$current_con" 2>/dev/null || echo "")
    old_gw=$(nmcli -g ipv4.gateway con show "$current_con" 2>/dev/null || echo "")
    old_dns=$(nmcli -g ipv4.dns con show "$current_con" 2>/dev/null | paste -sd "," - || echo "")
elif [[ "$NET_CTRL" == "netplan" ]]; then
    # Парсим netplan файл (припускаємо 1 файл /etc/netplan/01-netcfg.yaml)
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    if [[ -f "$NETPLAN_FILE" ]]; then
        old_method="static"
        if grep -q "dhcp4: true" "$NETPLAN_FILE"; then
            old_method="auto"
        fi
        old_ip=$(grep -Po 'addresses:\s*\[\K[^\]]+' "$NETPLAN_FILE" | head -1 | tr -d ' ')
        old_gw=$(grep -Po 'via:\s*\K\S+' "$NETPLAN_FILE" | head -1)
        old_dns=$(grep -Po 'addresses:\s*\[\K[^\]]+' "$NETPLAN_FILE" | tail -1 | tr -d ' ')
    else
        old_method="auto"
        old_ip=""
        old_gw=""
        old_dns=""
    fi
else
    echo "Відкат не підтримується для $NET_CTRL"
    old_method=""
fi

echo "Поточні налаштування:"
echo "  Метод: $old_method"
echo "  IP: $old_ip"
echo "  Шлюз: $old_gw"
echo "  DNS: $old_dns"
echo "--------------------------------------"

read -rp "Використовувати DHCP чи Статичний? (dhcp/static): " mode

if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    echo "⚙ Керуємо через nmcli..."
    if ! nmcli -t -f NAME con show | grep -qx "$selected_iface"; then
        sudo nmcli con add type ethernet ifname "$selected_iface" con-name "$selected_iface" >/dev/null 2>&1 || true
    fi

    if [[ "$mode" == "dhcp" ]]; then
        sudo nmcli con mod "$selected_iface" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
    else
        while true; do
            read -rp "Введіть IP/маску (наприклад 192.168.1.10/24): " IPADDR
            [[ "$IPADDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
            echo "Формат невірний!"
        done
        read -rp "Введіть шлюз: " GATEWAY
        read -rp "Введіть DNS через кому: " DNS
        sudo nmcli con mod "$selected_iface" ipv4.method manual ipv4.addresses "$IPADDR" ipv4.gateway "$GATEWAY" ipv4.dns "$DNS"
    fi
    sudo nmcli con up "$selected_iface"
elif [[ "$NET_CTRL" == "netplan" ]]; then
    echo "⚙ Керуємо через netplan..."
    NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    if [[ "$mode" == "dhcp" ]]; then
        sudo tee $NETPLAN_FILE > /dev/null <<EOF
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
            echo "Формат невірний!"
        done
        read -rp "Введіть шлюз: " GATEWAY
        read -rp "Введіть DNS через кому: " DNS
        sudo tee $NETPLAN_FILE > /dev/null <<EOF
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

read -rp "Бажаєте відкотити зміни, повернувши старі налаштування? (y/n): " rollback

if [[ "$rollback" =~ ^[Yy]$ ]]; then
    echo "Повертаємо старі налаштування..."

    if [[ "$NET_CTRL" == "NetworkManager" ]]; then
        if [[ "$old_method" == "auto" ]]; then
            sudo nmcli con mod "$selected_iface" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        else
            sudo nmcli con mod "$selected_iface" ipv4.method manual ipv4.addresses "$old_ip" ipv4.gateway "$old_gw" ipv4.dns "$old_dns"
        fi
        sudo nmcli con up "$selected_iface"
    elif [[ "$NET_CTRL" == "netplan" ]]; then
        if [[ "$old_method" == "auto" ]]; then
            sudo tee /etc/netplan/01-netcfg.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      dhcp4: true
EOF
        else
            sudo tee /etc/netplan/01-netcfg.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      addresses: [$old_ip]
      routes:
        - to: default
          via: $old_gw
      nameservers:
        addresses: [${old_dns//,/ }]
EOF
        fi
        sudo chmod 600 /etc/netplan/01-netcfg.yaml
        sudo netplan apply
    else
        echo "Відкат не підтримується для $NET_CTRL"
        exit 1
    fi

    echo "Відкат виконано."
else
    echo "Зміни залишено."
fi
