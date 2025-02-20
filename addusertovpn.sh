#!/bin/bash

source /etc/wireguard/params

DATABASE_PATH="/opt/telegram_wireguard/data.sqlite" # Укажите путь к вашей базе данных

function newClient() {
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"
    TGID="$1"


    # Проверяем, существует ли пользователь в базе данных
    USER_EXISTS=$(sqlite3 "$DATABASE_PATH" "SELECT COUNT(*) FROM userss WHERE tgid='$TGID';")

    if [[ $USER_EXISTS -eq 0 ]]; then
        echo "Пользователь TGID $TGID не найден в базе данных. Добавляем нового пользователя."
    else
        echo "Пользователь TGID $TGID найден в базе данных. Проверяем данные..."

        # Получение данных пользователя из базы
        CLIENT_WG_IPV4=$(sqlite3 "$DATABASE_PATH" "SELECT wg_ipv4 FROM userss WHERE tgid='$TGID';")
        CLIENT_WG_IPV6=$(sqlite3 "$DATABASE_PATH" "SELECT wg_ipv6 FROM userss WHERE tgid='$TGID';")
        CLIENT_PRIV_KEY=$(sqlite3 "$DATABASE_PATH" "SELECT wg_priv_key FROM userss WHERE tgid='$TGID';")
        CLIENT_PUB_KEY=$(sqlite3 "$DATABASE_PATH" "SELECT wg_pub_key FROM userss WHERE tgid='$TGID';")
        CLIENT_PRE_SHARED_KEY=$(sqlite3 "$DATABASE_PATH" "SELECT wg_preshared_key FROM userss WHERE tgid='$TGID';")

        # Если данные отсутствуют, создаём их
        if [[ -z $CLIENT_WG_IPV4 || -z $CLIENT_WG_IPV6 || -z $CLIENT_PRIV_KEY || -z $CLIENT_PUB_KEY || -z $CLIENT_PRE_SHARED_KEY ]]; then
            echo "Некоторые данные пользователя отсутствуют. Создаём новые."

            FOUND_FREE_IP=false
            for DOT1 in {0..255}; do
                for DOT2 in {10..254}; do
                    CLIENT_WG_IPV4="10.10.${DOT1}.${DOT2}"
                    IP_IN_WIREGUARD=$(grep -q "${CLIENT_WG_IPV4}/32" "/etc/wireguard/${SERVER_WG_NIC}.conf" && echo "1" || echo "0")
                    IP_IN_DB=$(sqlite3 "$DATABASE_PATH" "SELECT COUNT(*) FROM userss WHERE wg_ipv4='$CLIENT_WG_IPV4';")
                    if [[ $IP_IN_WIREGUARD -eq 0 && $IP_IN_DB -eq 0 ]]; then
                        FOUND_FREE_IP=true
                        break 2
                    fi
                done
            done

            if ! $FOUND_FREE_IP; then
                echo "No available IPv4 addresses left."
                exit 1
            fi

            BASE_IP6=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
            FOUND_FREE_IPV6=false
            for DOT_IP6 in {2..65534}; do
                CLIENT_WG_IPV6="${BASE_IP6}::${DOT_IP6}"
                IP6_IN_WIREGUARD=$(grep -q "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf" && echo "1" || echo "0")
                IP6_IN_DB=$(sqlite3 "$DATABASE_PATH" "SELECT COUNT(*) FROM userss WHERE wg_ipv6='$CLIENT_WG_IPV6';")
                if [[ $IP6_IN_WIREGUARD -eq 0 && $IP6_IN_DB -eq 0 ]]; then
                    FOUND_FREE_IPV6=true
                    break
                fi
            done

            if ! $FOUND_FREE_IPV6; then
                echo "No available IPv6 addresses left."
                exit 1
            fi

            CLIENT_PRIV_KEY=$(wg genkey)
            CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
            CLIENT_PRE_SHARED_KEY=$(wg genpsk)

            # Обновление данных пользователя в базе
            sqlite3 "$DATABASE_PATH" <<EOF
UPDATE userss SET wg_ipv4='$CLIENT_WG_IPV4', wg_ipv6='$CLIENT_WG_IPV6', wg_priv_key='$CLIENT_PRIV_KEY', wg_pub_key='$CLIENT_PUB_KEY', wg_preshared_key='$CLIENT_PRE_SHARED_KEY' WHERE tgid='$TGID';
EOF
            echo "Данные пользователя TGID $TGID успешно обновлены."
        fi

        # Проверка, есть ли пользователь в конфигурации WireGuard
if grep -q "${CLIENT_PUB_KEY}" "/etc/wireguard/${SERVER_WG_NIC}.conf"; then
    echo "Пользователь TGID $TGID уже активен в WireGuard."

    # Создание конфигурационного файла для клиента, если его нет
    HOME_DIR="/root"
    CLIENT_CONF="${HOME_DIR}/${SERVER_WG_NIC}-client-${TGID}.conf"

    # Если конфигурационный файл не существует, создаем его
    if [ ! -f "$CLIENT_CONF" ]; then
        cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
        echo "Конфигурационный файл для клиента TGID $TGID создан: $CLIENT_CONF"
    else
        echo "Конфигурационный файл для клиента TGID $TGID уже существует."
    fi
    exit 0
fi


        # Добавление пользователя в WireGuard, если его там нет
        wg set "${SERVER_WG_NIC}" peer "${CLIENT_PUB_KEY}" preshared-key <(echo "${CLIENT_PRE_SHARED_KEY}") allowed-ips "${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
        echo -e "\n### Client ${TGID}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

        echo "Пользователь TGID $TGID успешно восстановлен."
        exit 0
    fi

    # Если пользователь не найден, создаём нового
    FOUND_FREE_IP=false
    for DOT1 in {0..255}; do
        for DOT2 in {10..254}; do
            CLIENT_WG_IPV4="10.10.${DOT1}.${DOT2}"
            IP_IN_WIREGUARD=$(grep -q "${CLIENT_WG_IPV4}/32" "/etc/wireguard/${SERVER_WG_NIC}.conf" && echo "1" || echo "0")
            IP_IN_DB=$(sqlite3 "$DATABASE_PATH" "SELECT COUNT(*) FROM userss WHERE wg_ipv4='$CLIENT_WG_IPV4';")
            if [[ $IP_IN_WIREGUARD -eq 0 && $IP_IN_DB -eq 0 ]]; then
                FOUND_FREE_IP=true
                break 2
            fi
        done
    done

    if ! $FOUND_FREE_IP; then
        echo "No available IPv4 addresses left."
        exit 1
    fi

    BASE_IP6=$(echo "$SERVER_WG_IPV6" | awk -F '::' '{ print $1 }')
    FOUND_FREE_IPV6=false
    for DOT_IP6 in {2..65534}; do
        CLIENT_WG_IPV6="${BASE_IP6}::${DOT_IP6}"
        IP6_IN_WIREGUARD=$(grep -q "${CLIENT_WG_IPV6}/128" "/etc/wireguard/${SERVER_WG_NIC}.conf" && echo "1" || echo "0")
        IP6_IN_DB=$(sqlite3 "$DATABASE_PATH" "SELECT COUNT(*) FROM userss WHERE wg_ipv6='$CLIENT_WG_IPV6';")
        if [[ $IP6_IN_WIREGUARD -eq 0 && $IP6_IN_DB -eq 0 ]]; then
            FOUND_FREE_IPV6=true
            break
        fi
    done

    if ! $FOUND_FREE_IPV6; then
        echo "No available IPv6 addresses left."
        exit 1
    fi

    CLIENT_PRIV_KEY=$(wg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
    CLIENT_PRE_SHARED_KEY=$(wg genpsk)

    HOME_DIR="/root"

    cat >"${HOME_DIR}/${SERVER_WG_NIC}-client-${TGID}.conf" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    wg set "${SERVER_WG_NIC}" peer "${CLIENT_PUB_KEY}" preshared-key <(echo "${CLIENT_PRE_SHARED_KEY}") allowed-ips "${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128"
    echo -e "\n### Client ${TGID}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

    sqlite3 "$DATABASE_PATH" <<EOF
INSERT INTO userss (tgid, wg_ipv4, wg_ipv6, wg_priv_key, wg_pub_key, wg_preshared_key, subscription, registered, username, fullname)
VALUES ('$TGID', '$CLIENT_WG_IPV4', '$CLIENT_WG_IPV6', '$CLIENT_PRIV_KEY', '$CLIENT_PUB_KEY', '$CLIENT_PRE_SHARED_KEY', $(date +%s) + 432000, 1, '','$TGID'); #Добавил TGID как username и пустую строку как fullname
EOF

    echo "Пользователь TGID $TGID успешно добавлен."
}

newClient "$1"
