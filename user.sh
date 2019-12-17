#!/usr/bin/env bash

cd `dirname ${BASH_SOURCE[0]}`

. wg.def
CLIENT_TPL_FILE=client.conf.tpl
SERVER_TPL_FILE=server.conf.tpl
SAVED_FILE=.saved
AVAILABLE_IP_FILE=.available_ip
WG_TMP_CONF_FILE=.$_INTERFACE.conf
WG_CONF_FILE="/etc/wireguard/$_INTERFACE.conf"

dec2ip() {
    local delim=''
    local ip dec=$@
    for e in {3..0}
    do
        ((octet = dec / (256 ** e) ))
        ((dec -= octet * 256 ** e))
        ip+=$delim$octet
        delim=.
    done
    printf '%s\n' "$ip"
}

generate_cidr_ip_file_if() {
    local cidr=${_VPN_NET}
    local ip mask a b c d

    IFS=$'/' read ip mask <<< "$cidr"
    IFS=. read -r a b c d <<< "$ip"
    local beg=$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))
    local end=$(( beg+(1<<(32-mask))-1 ))
    ip=$(dec2ip $((beg+1)))
    _SERVER_IP="$ip/$mask"
    if [[ -f $AVAILABLE_IP_FILE ]]; then
        return
    fi

    > $AVAILABLE_IP_FILE
    local i=$((beg+2))
    while [[ $i -lt $end ]]; do
        ip=$(dec2ip $i)
	echo "$ip/$mask" >> $AVAILABLE_IP_FILE
        i=$((i+1))
    done
}

get_vpn_ip() {
    local ip=$(head -1 $AVAILABLE_IP_FILE)
    if [[ $ip ]]; then
	local mat="${ip/\//\\\/}"
        sed -i "/^$mat$/d" $AVAILABLE_IP_FILE
    fi
    echo "$ip"
}

add_user() {
    local user=$1
    local template_file=${CLIENT_TPL_FILE}
    local interface=${_INTERFACE}
    local userdir="users/$user"
    ipnum=$(grep Allowed /wg.def | tail -1 | awk -F '[ ./]' '{print $6}')
    newnum=$((10#${ipnum}+1))

    if [ ! -d "$userdir" ]
    then

     mkdir -p "$userdir"
    
    cd /etc/wireguard/
    cp client-wg0.conf $userdir.conf
    wg genkey | tee $userdir/privatekey | wg pubkey > $userdir/publickey

    ipnum=$(grep Allowed /etc/wireguard/wg0.conf | tail -1 | awk -F '[ ./]' '{print $6}')
    newnum=$((10#${ipnum}+1))
    sed -i 's%^PrivateKey.*$%'"PrivateKey = $(cat $userdir/privatekey)"'%' $userdir.conf
    sed -i 's%^Address.*$%'"Address = 10.9.0.$newnum\/24"'%' $userdir.conf
     fi
    cat >> /etc/wireguard/wg0.conf <<-EOF
    [Peer]
    PublicKey = $(cat tempubkey)
    AllowedIPs = 10.9.0.$newnum/32
    EOF
     
     # change wg config
     wg set wg0 peer $(cat $userdir/publickey) allowed-ips 10.9.0.$newnum/32
     qrencode -t ansiutf8  < /$userdir.conf
     echo -e "Add complete, $userdir.conf"
     rm -f $userdir/privatekey $userdir/publickey
     if [[ $? -ne 0 ]]; then
       echo "wg set failed"
       rm -rf $user
       exit 1
     fi

     echo "$user " >> ${SAVED_FILE}
    
    else
     echo "$user already exists." 1>&2
     echo
     read -r -p "Overwrite current user? [y/N]" response
     if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]
     then
        del_user $user
        add_user $user
     else
        echo "Exiting."
     fi
    fi
}

del_user() {
    local user=$1
    local userdir="users/$user"
    local ip key
    local interface=${_INTERFACE}

    read ip key <<<"$(awk "/^$user /{print \$2, \$3}" ${SAVED_FILE})"
    if [[ -n "$key" ]]; then
        wg set $interface peer $key remove
        if [[ $? -ne 0 ]]; then
            echo "wg set failed"
            exit 1
        fi
    fi
    sed -i "/^$user /d" ${SAVED_FILE}
    if [[ -n "$ip" ]]; then
        echo "$ip" >> ${AVAILABLE_IP_FILE}
    fi
    rm -rf $userdir
    
    sort ${AVAILABLE_IP_FILE} --version-sort -o ${AVAILABLE_IP_FILE}
}

generate_and_install_server_config_file() {
    local template_file=${SERVER_TPL_FILE}
    local ip

    # server config file
    eval "echo \"$(cat "${template_file}")\"" > $WG_TMP_CONF_FILE
    while read user vpn_ip public_key; do
      ip=${vpn_ip%/*}/32
      cat >> $WG_TMP_CONF_FILE <<EOF
[Peer]
PublicKey = $public_key
AllowedIPs = $ip
EOF
    done < ${SAVED_FILE}
    \cp -f $WG_TMP_CONF_FILE $WG_CONF_FILE
}

do_clear() {
    local interface=$_INTERFACE
    wg-quick down $interface
    > $WG_CONF_FILE
    rm -f ${SAVED_FILE} ${AVAILABLE_IP_FILE}
}

do_user() {
    generate_cidr_ip_file_if

    if [[ $action == "-a" ]]; then
        if [[ -d $user ]]; then
            echo "$user exist"
            exit 1
        fi
        add_user $user
    elif [[ $action == "-d" ]]; then
        del_user $user
    fi

    generate_and_install_server_config_file
}

view_user() {
    local user=$1
    local userdir="users/$user"

    echo "Client configuration ($(cat $userdir/client.conf | grep AllowedIPs))"
    echo "client.conf:"
    echo
    cat $userdir/client.conf
    echo
    qrencode -t ansiutf8  < $userdir/client.conf
    echo
    echo
    echo "----------------------------------------------------------------"
    echo "----------------------------------------------------------------"
    echo "----------------------------------------------------------------"
    echo
    echo
    echo "Client configuration (AllowedIPs: 0.0.0.0/0)"
    echo "client.all.conf:"
    echo
    cat $userdir/client.all.conf
    echo
    qrencode -t ansiutf8  < $userdir/client.all.conf
}

usage() {
    echo "usage: $0 [-a|-d|-c|-v] [username]"
    echo
    echo "       -a [username]                              add user"
    echo "       -d [username]                           delete user"
    echo "       -c               delete all users and configuration"
    echo "       -v [username]      view generated QR codes for user"
    echo

}

# main
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

action=$1
user=$2

if [[ $action == "-c" ]]; then
    read -r -p "Deleting all users and config. Are you sure? [y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]
    then
        do_clear
    else
        echo "Exiting."
    fi
elif [[ $action == "-v" ]]; then
    view_user $user   
elif [[ $action == "-g" ]]; then
    generate_cidr_ip_file_if
elif [[ ! -z "$user" && ( $action == "-a" || $action == "-d" ) ]]; then
    do_user
else
    usage
    exit 1
fi
