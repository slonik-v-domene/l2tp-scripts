#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2022 Andrey V. Shetukhin <stellar@communico.pro>. All Rights Reserved.
#

set -e -o pipefail
shopt -s extglob
export LC_ALL=C

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
export PATH="${SELF%/*}:$PATH"

BR_ADDRESS=""
BR_NAME=""
LOCAL_ADDRESS=""
ROUTES_VIA_BR=( )
MAX_ATTEMPTS=( )
REMOTE_ADDRESS=( )
REMOTE_ID=( )
IS_ALIVE=0
INTERFACE=""
CONFIG_FILE=""
PROGRAM="${0##*/}"
ARGS=( "$@" )

cmd() {
	echo "[#] $*" >&2
	"$@"
}

die() {
	echo "$PROGRAM: $*" >&2
	exit 1
}

parse_options() {
	local bridge_section=0 local_section=0 remote_section=0 line key value stripped v
	CONFIG_FILE="$1"
	BR_NAME="$1"
	[[ $CONFIG_FILE =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] && CONFIG_FILE="/etc/l2tp/$CONFIG_FILE.conf"
	[[ -e $CONFIG_FILE ]] || die "\`$CONFIG_FILE' does not exist"
	[[ $CONFIG_FILE =~ (^|/)([a-zA-Z0-9_=+.-]{1,15})\.conf$ ]] || die "The config file must be a valid interface name, followed by .conf"
	CONFIG_FILE="$(readlink -f "$CONFIG_FILE")"
	((($(stat -c '0%#a' "$CONFIG_FILE") & $(stat -c '0%#a' "${CONFIG_FILE%/*}") & 0007) == 0)) || echo "Warning: \`$CONFIG_FILE' is world accessible" >&2
	INTERFACE="${BASH_REMATCH[2]}"
	shopt -s nocasematch
	while read -r line || [[ -n $line ]]; do
		stripped="${line%%\#*}"
		key="${stripped%%=*}"; key="${key##*([[:space:]])}"; key="${key%%*([[:space:]])}"
		value="${stripped#*=}"; value="${value##*([[:space:]])}"; value="${value%%*([[:space:]])}"
		if [[ $key == "[Bridge]" ]]; then
			bridge_section=1 local_section=0 remote_section=0
		fi
		if [[ $key == "[Local]" ]]; then
			bridge_section=0 local_section=1 remote_section=0
		fi
		if [[ $key == "[Remote]" ]]; then
			bridge_section=0 local_section=0 remote_section=1
		fi
		if [[ $bridge_section -eq 1 ]]; then
			case "$key" in
			Address) BR_ADDRESS=( ${value//,/ } ); continue ;;
			Routes) ROUTES_VIA_BR+=( "$value" ); continue ;;
			esac
		fi
		if [[ $local_section -eq 1 ]]; then
			case "$key" in
			Address) LOCAL_ADDRESS=${value}; continue ;;
			esac
		fi
		if [[ $remote_section -eq 1 ]]; then
			case "$key" in
			Address) REMOTE_ADDRESS+=( "$value" ); continue ;;
			Id) REMOTE_ID+=( "$value" ); continue ;;
			Attempts) MAX_ATTEMPTS+=( "$value" ); continue ;;
			esac
		fi
	done < "$CONFIG_FILE"
	shopt -u nocasematch
}

auto_su() {
	[[ $UID == 0 ]] || exec sudo -p "$PROGRAM must be run as root. Please enter the password for %u to continue: " -- "$BASH" -- "$SELF" "${ARGS[@]}"
}

cmd_usage() {
	cat >&2 <<-_EOF
	Usage: $PROGRAM [ up | down ] [ CONFIG_FILE | INTERFACE ]

	  CONFIG_FILE is a configuration file, whose filename is the interface name
	  followed by \`.conf'. Otherwise, INTERFACE is an interface name, with
	  configuration found at /etc/l2tp/INTERFACE.conf.
	_EOF
}

check_alive() {
	local i res
	IS_ALIVE=0
	for i in $(seq 1 $2); do
		read -r res < <(ping -c 1 -t 1 $1 | grep "transmitted" | awk '{print $4}' || true) || true
		if [[ $res -eq "1" ]]; then
			IS_ALIVE=1
			break
		fi
		logger -t l2tp -p daemon.info "CHECK_ALIVE: waiting $1 is ready"
		sleep 1
	done
}

cmd_up() {
	local i addr net id iface attempts mac

	if [[ -z $BR_ADDRESS ]]; then
		[[ -n $(ip link show dev "$BR_NAME" 2>/dev/null) ]] || die "\`$BR_NAME' does not exist"
	else
		[[ -z $(ip link show dev "$BR_NAME" 2>/dev/null) ]] || die "\`$BR_NAME' already exists"
		read -r mac < <(echo $BR_ADDRESS | md5sum | hexdump -n3 -e'/3 "FC:FF:AA" 3/1 ":%02X"' || true) || true
		ip link add $BR_NAME address $mac type bridge
		ip link set dev $BR_NAME up
		ip address add $BR_ADDRESS dev $BR_NAME
		for i in "${!ROUTES_VIA_BR[@]}"; do
			net=${ROUTES_VIA_BR[i]}
			ip ro add $net dev $BR_NAME
		done
	fi

	for i in "${!REMOTE_ADDRESS[@]}"; do
		addr=${REMOTE_ADDRESS[i]}
		id=${REMOTE_ID[i]}
		attempts=${MAX_ATTEMPTS[i]}
		check_alive $addr $attempts
		if [[ $IS_ALIVE -ne 1 ]]; then
			logger -t l2tp -p daemon.alert "CMD_UP: $addr is not accessible; skipping l2tp tunnel for $id after $attempts attempt(s)"
		else
			ip l2tp add tunnel tunnel_id $id peer_tunnel_id $id encap ip local $LOCAL_ADDRESS remote $addr
			ip l2tp add session tunnel_id $id session_id $id peer_session_id $id
			read -r iface < <(ip l2tp show session | sed ':a;N;$!ba;s/\n  / /g' | grep "Session $id in tunnel $id Peer session $id, tunnel $id" | awk '{print $13}' || true) || true
			if [[ -n "$iface" ]]; then
				ip link set dev $iface up
				ip link set dev $iface master $BR_NAME
			fi
		fi
	done

	trap - INT TERM EXIT
}

cmd_down() {
	local i addr id iface res

	while read -r _ res; do
		[[ $res =~ ^([a-z0-9]+): ]] || continue
		iface=${BASH_REMATCH[1]}
		read -r id < <(ip l2tp show session | sed ':a;N;$!ba;s/\n  / /g' | grep "name: $iface" | awk '{print $2}' || true) || true
		if [[ -n "$id" ]]; then
			ip link set $iface nomaster
			ip link set dev $iface down
			ip l2tp del session tunnel_id $id session_id $id
			ip l2tp del tunnel tunnel_id $id
		fi
	done < <(ip link show | grep "master $BR_NAME")

	if [[ -n $BR_ADDRESS ]]; then
		read -r res < <(ip link show $BR_NAME || true) || true
		if [[ -n "$res" ]]; then
			ip link set dev $BR_NAME down
			ip link del $BR_NAME type bridge
		fi
	fi

	trap - INT TERM EXIT
}

if [[ $# -eq 1 && ( $1 == --help || $1 == -h || $1 == help ) ]]; then
	cmd_usage
elif [[ $# -eq 2 && $1 == up ]]; then
	auto_su
	parse_options "$2"
	cmd_up
elif [[ $# -eq 2 && $1 == down ]]; then
	auto_su
	parse_options "$2"
	cmd_down
else
	cmd_usage
	exit 1
fi

exit 0
