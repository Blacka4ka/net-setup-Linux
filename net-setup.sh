#!/bin/bash
set -e

# --- Перевірка sudo/root ---
if [[ $EUID -ne 0 ]]; then
    echo "Цей скрипт потрібно запускати з правами root або через sudo."
    exit 1
fi

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

# Визначаємо інтерфейси (крім lo)
interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))

echo "=== Стан інтерфейсів ==="
for iface in "${interfaces[@]}"; do
    link_state=$(cat /sys/class/net/$iface/carrier 2>/dev/null || echo 0)
    link_text=$([[ "$link_state" == "1" ]] && echo "Кабель" || echo "Немає лінку")
    ips=$(ip -4 addr show "$iface" | awk '/inet /{print $2}' | paste -sd "," -)
    gw=$(ip route show dev "$iface" | awk '/default/ {print $3}' | head -1)
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

# --- Функція валідації IP/маски ---
validate_ip() {
    local ipmask=$1
    if [[ ! $ipmask =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi

    IFS=/ read -r ip prefix <<< "$ipmask"

    IFS=. read -r i1 i2 i3 i4 <<< "$ip"
    for i in $i1 $i2 $i3 $i4; do
        if (( i < 0 || i > 255 )); then
            return 1
        fi
    done

    if (( prefix < 1 || prefix > 32 )); then
        return 1
    fi

    return 0
}

# --- Зчитуємо поточні налаштування ---

old_method=""
old_ip=""
old_gw=""
old_dns=""

if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    current_con=$(nmcli -t -f NAME,DEVICE con show --active | grep ":$selected_iface$" | cut -d: -f1 || true)
    if [[ -z "$current_con" ]]; then
        current_con="$selected_iface"
    fi
    old_method=$(nmcli -g ipv4.method con show "$current_con" 2>/dev/null || echo "auto")
    old_ip=$(nmcli -g ipv4.addresses con show "$current_con" 2>/dev/null || echo "")
    old_gw=$(nmcli -g ipv4.gateway con show "$current_con" 2>/dev/null || echo "")
    old_dns=$(nmcli -g ipv4.dns con show "$current_con" 2>/dev/null | paste -sd "," - || echo "")

elif [[ "$NET_CTRL" == "netplan" ]]; then
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1 || true)
    if [[ -n "$NETPLAN_FILE" ]]; then
        # Визначаємо, чи є DHCP
        if grep -q "dhcp4: true" "$NETPLAN_FILE"; then
            old_method="auto"
        else
            old_method="static"
        fi

        # IP
        old_ip=$(awk "/$selected_iface:/{flag=1;next}/^[^ ]/{flag=0}flag" "$NETPLAN_FILE" | grep -Po 'addresses:\s*\[\K[^\]]+' | head -1 | tr -d ' ')
        # GW
        old_gw=$(awk "/$selected_iface:/{flag=1;next}/^[^ ]/{flag=0}flag" "$NETPLAN_FILE" | grep -Po 'via:\s*\K\S+' | head -1)
        # DNS
        old_dns=$(awk "/$selected_iface:/{flag=1;next}/^[^ ]/{flag=0}flag" "$NETPLAN_FILE" | grep -Po 'nameservers:\s*\n\s*addresses:\s*\[\K[^\]]+' | head -1 | tr -d ' ')
    else
        old_method="auto"
    fi

elif [[ "$NET_CTRL" == "systemd-networkd" ]]; then
    NETD_CONF="/etc/systemd/network/10-$selected_iface.network"
    if [[ -f "$NETD_CONF" ]]; then
        # Читаємо [Network] секцію
        old_method="static"
        if grep -q "^DHCP=yes" "$NETD_CONF"; then
            old_method="auto"
        fi

        old_ip=$(grep -Po '^Address=\K[^/ ]+(/\d+)?' "$NETD_CONF" | head -1)
        old_gw=$(grep -Po '^Gateway=\K\S+' "$NETD_CONF" | head -1)
        old_dns=$(grep -Po '^DNS=\K\S+' "$NETD_CONF" | paste -sd "," -)
    else
        old_method="auto"
    fi

else
    echo "Відкат не підтримується для $NET_CTRL"
fi

echo "Поточні налаштування:"
echo "  Метод: $old_method"
echo "  IP: ${old_ip:-немає}"
echo "  Шлюз: ${old_gw:-немає}"
echo "  DNS: ${old_dns:-немає}"
echo "--------------------------------------"

# --- Обираємо режим ---
while true; do
    read -rp "Використовувати DHCP чи Статичний? (dhcp/static): " mode
    if [[ "$mode" == "dhcp" || "$mode" == "static" ]]; then
        break
    fi
    echo "Введіть 'dhcp' або 'static'"
done

if [[ "$mode" == "static" ]]; then
    while true; do
        read -rp "Введіть IP/маску (наприклад 192.168.1.10/24): " IPADDR
        if validate_ip "$IPADDR"; then
            break
        else
            echo "Неправильний формат IP/маски. Спробуйте ще."
        fi
    done
    read -rp "Введіть шлюз (GW): " GATEWAY
    read -rp "Введіть DNS-сервери через кому (наприклад 8.8.8.8,1.1.1.1), або залиште пустим: " DNS
fi

# --- Застосування налаштувань ---

if [[ "$NET_CTRL" == "NetworkManager" ]]; then
    echo "⚙ Керуємо через nmcli..."

    if ! nmcli -t -f NAME con show | grep -qx "$selected_iface"; then
        nmcli con add type ethernet ifname "$selected_iface" con-name "$selected_iface" >/dev/null 2>&1 || true
    fi

    if [[ "$mode" == "dhcp" ]]; then
        nmcli con mod "$selected_iface" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
    else
        nmcli con mod "$selected_iface" ipv4.method manual ipv4.addresses "$IPADDR" ipv4.gateway "$GATEWAY"
        if [[ -n "$DNS" ]]; then
            nmcli con mod "$selected_iface" ipv4.dns "$DNS"
        else
            nmcli con mod "$selected_iface" ipv4.dns ""
        fi
    fi
    nmcli con up "$selected_iface"

elif [[ "$NET_CTRL" == "netplan" ]]; then
    echo "⚙ Керуємо через netplan..."
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    if [[ -z "$NETPLAN_FILE" ]]; then
        NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
    fi

    if [[ "$mode" == "dhcp" ]]; then
        tee "$NETPLAN_FILE" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      dhcp4: true
EOF
    else
        dns_line=""
        if [[ -n "$DNS" ]]; then
            # формуємо список dns без пробілів
            dns_formatted="${DNS//,/ }"
            dns_line="nameservers:
        addresses: [$dns_formatted]"
        fi

        tee "$NETPLAN_FILE" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      addresses: [$IPADDR]
      routes:
        - to: default
          via: $GATEWAY
      $dns_line
EOF
    fi

    chmod 600 "$NETPLAN_FILE"
    netplan apply

elif [[ "$NET_CTRL" == "systemd-networkd" ]]; then
    echo "⚙ Керуємо через systemd-networkd..."
    NETD_CONF="/etc/systemd/network/10-$selected_iface.network"

    if [[ "$mode" == "dhcp" ]]; then
        tee "$NETD_CONF" > /dev/null <<EOF
[Match]
Name=$selected_iface

[Network]
DHCP=yes
EOF
    else
        dns_lines=""
        if [[ -n "$DNS" ]]; then
            IFS=',' read -ra dns_array <<< "$DNS"
            for d in "${dns_array[@]}"; do
                dns_lines+="DNS=$d
"
            done
        fi

        tee "$NETD_CONF" > /dev/null <<EOF
[Match]
Name=$selected_iface

[Network]
Address=$IPADDR
Gateway=$GATEWAY
$dns_lines
EOF
    fi

    systemctl restart systemd-networkd.service
else
    echo "Невідомий менеджер мережі: $NET_CTRL"
    exit 1
fi

echo "--------------------------------------"
echo "=== Новий стан інтерфейсу $selected_iface ==="
ip addr show "$selected_iface"
ip route show dev "$selected_iface"
echo "--------------------------------------"

# --- Відкат ---
read -rp "Бажаєте відкотити зміни, повернувши старі налаштування? (y/n): " rollback

if [[ "$rollback" =~ ^[Yy]$ ]]; then
    echo "Повертаємо старі налаштування..."

    if [[ "$NET_CTRL" == "NetworkManager" ]]; then
        if [[ "$old_method" == "auto" ]]; then
            nmcli con mod "$selected_iface" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        else
            nmcli con mod "$selected_iface" ipv4.method manual ipv4.addresses "$old_ip" ipv4.gateway "$old_gw"
            if [[ -n "$old_dns" ]]; then
                nmcli con mod "$selected_iface" ipv4.dns "$old_dns"
            else
                nmcli con mod "$selected_iface" ipv4.dns ""
            fi
        fi
        nmcli con up "$selected_iface"

    elif [[ "$NET_CTRL" == "netplan" ]]; then
        NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
        if [[ -z "$NETPLAN_FILE" ]]; then
            NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
        fi

        if [[ "$old_method" == "auto" ]]; then
            tee "$NETPLAN_FILE" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      dhcp4: true
EOF
        else
            dns_line=""
            if [[ -n "$old_dns" ]]; then
                dns_line="nameservers:
        addresses: [${old_dns//,/ }]"
            fi

            tee "$NETPLAN_FILE" > /dev/null <<EOF
network:
  version: 2
  ethernets:
    $selected_iface:
      addresses: [$old_ip]
      routes:
        - to: default
          via: $old_gw
      $dns_line
EOF
        fi

        chmod 600 "$NETPLAN_FILE"
        netplan apply

    elif [[ "$NET_CTRL" == "systemd-networkd" ]]; then
        NETD_CONF="/etc/systemd/network/10-$selected_iface.network"

        if [[ "$old_method" == "auto" ]]; then
            tee "$NETD_CONF" > /dev/null <<EOF
[Match]
Name=$selected_iface

[Network]
DHCP=yes
EOF
        else
            dns_lines=""
            if [[ -n "$old_dns" ]]; then
                IFS=',' read -ra dns_array <<< "$old_dns"
                for d in "${dns_array[@]}"; do
                    dns_lines+="DNS=$d
"
                done
            fi

            tee "$NETD_CONF" > /dev/null <<EOF
[Match]
Name=$selected_iface

[Network]
Address=$old_ip
Gateway=$old_gw
$dns_lines
EOF
        fi
        systemctl restart systemd-networkd.service
    else
        echo "Відкат не підтримується для $NET_CTRL"
        exit 1
    fi

    echo "Відкат виконано."
else
    echo "Зміни залишено."
fi
