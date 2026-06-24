#!/bin/bash -e

APP=$(basename $0)
LOCKFILE="/tmp/$APP.lock"

trap "rm -f ${LOCKFILE}; exit" INT TERM EXIT
if ! ln -s $APP $LOCKFILE 2>/dev/null; then
    echo "ERROR: script LOCKED" >&2
    exit 15
fi

function usage {
  echo "Usage: $0 [<options>] [command [arg]]"
  echo "Options:"
  echo " -i : Init (Create server keys and configs)"
  echo " -c : Create new user"
  echo " -d : Delete user"
  echo " -L : Lock user"
  echo " -U : Unlock user"
  echo " -p : Print user config"
  echo " -q : Print user QR code"
  echo " -u <user> : User identifier (uniq field for vpn account)"
  echo " -s <server> : Server host for user connection (overrides SERVER_HOST from .env)"
  echo " -I <interface> : Interface (overrides SERVER_INTERFACE from .env, default auto)"
  echo " -h, --help : Usage"
  exit 1
}

unset USER
umask 0077

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
fi

HOME_DIR="${HOME_DIR:-/etc/amnezia/amneziawg}"
SERVER_NAME="${SERVER_NAME:-awg0}"
SERVER_IP_PREFIX="${SERVER_IP_PREFIX:-10.10.90}"
SERVER_PORT="${SERVER_PORT:-43748}"
SERVER_INTERFACE="${SERVER_INTERFACE:-$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)}"
SERVER_HOST="${SERVER_HOST}"

# Support --help, help, usage
for arg in "$@"; do
  if [ "$arg" == "--help" ] || [ "$arg" == "help" ] || [ "$arg" == "usage" ]; then
    usage
  fi
done

while getopts ":icdpqhLUu:I:s:h" opt; do
  case $opt in
     i) INIT=1 ;;
     c) CREATE=1 ;;
     d) DELETE=1 ;;
     L) LOCK=1 ;;
     U) UNLOCK=1 ;;
     p) PRINT_USER_CONFIG=1 ;;
     q) PRINT_QR_CODE=1 ;;
     u) USER="$OPTARG" ;;
     I) SERVER_INTERFACE="$OPTARG" ;;
     h) usage ;;
     s) SERVER_HOST="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" ; exit 1 ;;
     :) echo "Option -$OPTARG requires an argument" ; exit 1 ;;
  esac
done

[ $# -lt 1 ] && usage

function reload_server {
    awg syncconf ${SERVER_NAME} <(awg-quick strip ${SERVER_NAME})
}

function get_new_ip {
    declare -A IP_EXISTS

    for IP in $(grep -i 'Address\s*=\s*' keys/*/*.conf | sed 's/\/[0-9]\+$//' | grep -Po '\d+$')
    do
        IP_EXISTS[$IP]=1
    done

    for IP in {2..255}
    do
        [ ${IP_EXISTS[$IP]} ] || break
    done

    if [ $IP -eq 255 ]; then
        echo "ERROR: can't determine new address" >&2
        exit 3
    fi

    echo "${SERVER_IP_PREFIX}.${IP}/32"
}

function add_user_to_server {
    if [ ! -f "keys/${USER}/public.key" ]; then
        echo "ERROR: User not exists" >&2
        exit 1
    fi

    local USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    local USER_PSK_KEY=$(cat "keys/$USER/psk.key")
    local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')

    if grep "# BEGIN ${USER}$" "$SERVER_NAME.conf" >/dev/null ; then
        echo "User already exists"
        exit 0
    fi

cat <<EOF >> "$SERVER_NAME.conf"
# BEGIN ${USER}
[Peer]
PublicKey = ${USER_PUB_KEY}
AllowedIPs = ${USER_IP}
PresharedKey = ${USER_PSK_KEY}
# END ${USER}
EOF

    ip -4 route add ${USER_IP}/32 dev ${SERVER_NAME} || true
}

function remove_user_from_server {
    sed -i "/# BEGIN ${USER}$/,/# END ${USER}$/d" "$SERVER_NAME.conf"
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        local USER_IP=$(grep -i Address "keys/${USER}/${USER}.conf" | sed 's/Address\s*=\s*//i; s/\/.*//')
        ip -4 route del ${USER_IP}/32 dev ${SERVER_NAME} || true
    fi
}

function init {
    local EFFECTIVE_SERVER_HOST="${SERVER_HOST}"
    if [ -z "$EFFECTIVE_SERVER_HOST" ]; then
        EFFECTIVE_SERVER_HOST=$(ip -4 addr show dev "$SERVER_INTERFACE" | grep -Po '(?<=inet )(\d+\.\d+\.\d+\.\d+)' | head -1)
    fi

    if [ -z "$EFFECTIVE_SERVER_HOST" ]; then
        echo "ERROR: Server host required (use -s or SERVER_HOST in .env)" >&2
        exit 1
    fi

    if [ -z "$SERVER_INTERFACE" ]; then
        echo "ERROR: Can't determine server interface" >&2
        echo "DEBUG: 'ip route':"
        ip route
        exit 1
    fi

    echo "Interface: $SERVER_INTERFACE"
    echo "Server Host: $EFFECTIVE_SERVER_HOST"

    mkdir -p "keys/${SERVER_NAME}"
    echo -n "$EFFECTIVE_SERVER_HOST" > "keys/.server"

    if [ ! -f "keys/${SERVER_NAME}/private.key" ]; then
        awg genkey | tee "keys/${SERVER_NAME}/private.key" | awg pubkey > "keys/${SERVER_NAME}/public.key"
    fi

    if [ -f "$SERVER_NAME.conf" ]; then
        echo "Server already initialized"
        exit 0
    fi

    SERVER_PVT_KEY=$(cat "keys/$SERVER_NAME/private.key")

    JC=$(( RANDOM % 11 ))
    JMIN=$(( 64 + RANDOM % 448 ))
    JMAX=$(( JMIN + RANDOM % (1025 - JMIN) ))
    S1=$(( RANDOM % 129 ))
    S2=$(( RANDOM % 129 ))
    while [ $((S1 + 56)) -eq $S2 ]; do S2=$(( RANDOM % 129 )); done
    S3=$(( RANDOM % 129 ))
    S4=$(( RANDOM % 25 ))
    H1=$(( 5 + RANDOM % 1000000 ))
    H2=$(( 1000005 + RANDOM % 1000000 ))
    H3=$(( 2000005 + RANDOM % 1000000 ))
    H4=$(( 3000005 + RANDOM % 1000000 ))
    I1="<r 2><b $(openssl rand -hex 16)>"
    I2="<b $(openssl rand -hex 16)>"
    I3="<b $(openssl rand -hex 16)>"
    I4="<b $(openssl rand -hex 16)>"
    I5="<b $(openssl rand -hex 16)>"

cat <<EOF > "$SERVER_NAME.conf"
[Interface]
Address = ${SERVER_IP_PREFIX}.1/32
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PVT_KEY}
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_INTERFACE} -j MASQUERADE
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}
I2 = ${I2}
I3 = ${I3}
I4 = ${I4}
I5 = ${I5}

EOF

    echo net.ipv4.ip_forward=1 >> /etc/sysctl.conf
    sysctl -p

    systemctl enable awg-quick@${SERVER_NAME}
    awg-quick up ${SERVER_NAME} || true

    echo "Server initialized successfully"
    exit 0
}

function create {
    if [ -f "keys/${USER}/${USER}.conf" ]; then
        echo "WARNING: key ${USER}.conf already exists" >&2
        return 0
    fi

    local EFFECTIVE_SERVER_HOST="${SERVER_HOST}"
    if [ -z "$EFFECTIVE_SERVER_HOST" ]; then
        if [ -f "keys/.server" ]; then
            EFFECTIVE_SERVER_HOST=$(cat "keys/.server")
        else
            EFFECTIVE_SERVER_HOST=$(ip -4 addr show dev "$SERVER_INTERFACE" | grep -Po '(?<=inet )(\d+\.\d+\.\d+\.\d+)' | head -1)
        fi
    fi

    if [ -n "$SERVER_HOST" ] && [ -d "keys" ]; then
        echo -n "$SERVER_HOST" > "keys/.server"
    fi

    if [ -z "$EFFECTIVE_SERVER_HOST" ]; then
        echo "ERROR: Can't determine server host. Set SERVER_HOST in .env or use -s" >&2
        exit 1
    fi

    USER_IP=$( get_new_ip )

    mkdir "keys/${USER}"
    awg genkey | tee "keys/${USER}/private.key" | awg pubkey > "keys/${USER}/public.key"
    awg genpsk > "keys/${USER}/psk.key"

    USER_PVT_KEY=$(cat "keys/${USER}/private.key")
    USER_PUB_KEY=$(cat "keys/${USER}/public.key")
    USER_PSK_KEY=$(cat "keys/${USER}/psk.key")
    SERVER_PUB_KEY=$(cat "keys/$SERVER_NAME/public.key")

    local SERVER_CONF="$SERVER_NAME.conf"
    JC=$(grep -i "^Jc\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    JMIN=$(grep -i "^Jmin\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    JMAX=$(grep -i "^Jmax\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    S1=$(grep -i "^S1\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    S2=$(grep -i "^S2\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    S3=$(grep -i "^S3\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    S4=$(grep -i "^S4\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    H1=$(grep -i "^H1\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    H2=$(grep -i "^H2\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    H3=$(grep -i "^H3\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    H4=$(grep -i "^H4\s*=" "$SERVER_CONF" | cut -d'=' -f2 | tr -d ' ')
    I1=$(grep -i "^I1\s*=" "$SERVER_CONF" | sed 's/^I1\s*=\s*//i')
    I2=$(grep -i "^I2\s*=" "$SERVER_CONF" | sed 's/^I2\s*=\s*//i')
    I3=$(grep -i "^I3\s*=" "$SERVER_CONF" | sed 's/^I3\s*=\s*//i')
    I4=$(grep -i "^I4\s*=" "$SERVER_CONF" | sed 's/^I4\s*=\s*//i')
    I5=$(grep -i "^I5\s*=" "$SERVER_CONF" | sed 's/^I5\s*=\s*//i')

cat <<EOF > "keys/${USER}/${USER}.conf"
[Interface]
PrivateKey = ${USER_PVT_KEY}
Address = ${USER_IP}
DNS = 8.8.8.8, 8.8.4.4
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
I1 = ${I1}
I2 = ${I2}
I3 = ${I3}
I4 = ${I4}
I5 = ${I5}

[Peer]
PublicKey = ${SERVER_PUB_KEY}
Endpoint = ${EFFECTIVE_SERVER_HOST}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 20
PresharedKey = ${USER_PSK_KEY}
EOF
    add_user_to_server
    reload_server
}

cd $HOME_DIR

if [ $INIT ]; then
    init
    exit 0;
fi

if [ ! -f "keys/$SERVER_NAME/public.key" ]; then
    echo "ERROR: Run init script before" >&2
    exit 2
fi

if [ -z "${USER}" ]; then
    echo "ERROR: User required" >&2
    exit 1
fi

if [ $CREATE ]; then
    create
    # Update config if SERVER_HOST was provided even if user already exists
    if [ -n "$SERVER_HOST" ] && [ -f "keys/${USER}/${USER}.conf" ]; then
        sed -i "s|^Endpoint\s*=.*|Endpoint = ${SERVER_HOST}:${SERVER_PORT}|" "keys/${USER}/${USER}.conf"
    fi
fi

if [ $DELETE ]; then
    remove_user_from_server
    reload_server
    rm -rf "keys/${USER}"
    exit 0
fi

if [ $LOCK ]; then
    remove_user_from_server
    reload_server
    exit 0
fi

if [ $UNLOCK ]; then
    add_user_to_server
    reload_server
    exit 0
fi

if [ $PRINT_USER_CONFIG ]; then
    if [ -n "$SERVER_HOST" ] && [ -f "keys/${USER}/${USER}.conf" ]; then
        sed -i "s|^Endpoint\s*=.*|Endpoint = ${SERVER_HOST}:${SERVER_PORT}|" "keys/${USER}/${USER}.conf"
        # Also update keys/.server to persist this change
        echo -n "$SERVER_HOST" > "keys/.server"
    fi
    cat "keys/${USER}/${USER}.conf"
elif [ $PRINT_QR_CODE ]; then
    qrencode -t ansiutf8 < "keys/${USER}/${USER}.conf"
fi


exit 0
