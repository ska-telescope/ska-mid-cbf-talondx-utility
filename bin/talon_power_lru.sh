#!/bin/bash

USER="admin"
PASS="1234"
PDU_IP="192.168.0.100"
SSH_TIMEOUT_IN_SECONDS="5"
LRU=$1
STATE=$2

ST_PDU_SCRIPT="/shared/talon-dx-utilities/bin/mid-psi-rack-pdu.sh"

SNMP_USER="apcsnmp"
SNMP_PASS="testingapcsnmp"
SNMP_OID_BASE="1.3.6.1.4.1.318.1.1.4.4.2.1.3"
PDU1_SNMP_IP="192.168.1.253"
PDU2_SNMP_IP="192.168.1.252"

if [ ! -f $ST_PDU_SCRIPT ]; then
    ST_PDU_SCRIPT="./mid-psi-rack-pdu.sh"
fi

USAGE_BANNER="Usage: ./talon_power_lru.sh LRU [STATE]
  LRU: lru1|lru2|lru3|lru4|lru5|lru6|lru7|lru8

  Options:
    [STATE]: on|On|ON|off|Off|OFF (sets the lru to the STATE; if no STATE is provided, the LRU status is returned)"


if ! [[ "$LRU" =~ lru1|lru2|lru3|lru4|lru5|lru6|lru7|lru8 ]]; then
	echo "ERROR: Unrecognized LRU \"$LRU\" provided."
        echo "$USAGE_BANNER"
        exit 1
fi

# PDU[1|2]_MODEL should be one of "DLI", "ST", or "APC".
# 	- DLI is the small PDU with a few outlets
#   - ST is the Mid PSI rack PDU
#   - APC is the model used in sITF

if [[ "$LRU" == "lru1" ]]; then
	PDU1_MODEL="ST"
	PDU1_OUTLET="AA1"
	TALON_A="talon1"
	TALON_B="talon2"
elif [[ "$LRU" == "lru2" ]]; then
	PDU1_MODEL="ST"
	PDU1_OUTLET="AA2"
	TALON_A="talon3"
	TALON_B="talon4"
elif [[ "$LRU" == "lru3" ]]; then
	PDU1_MODEL="ST"
	PDU1_OUTLET="AA33"
	TALON_A="talon5"
	TALON_B="talon6"
elif [[ "$LRU" == "lru4" ]]; then
	PDU1_MODEL="ST"
	PDU1_OUTLET="AA34"
	TALON_A="talon7"
	TALON_B="talon8"
elif [[ "$LRU" == "lru5" ]]; then
	PDU2_MODEL="APC_SNMP"
	PDU2_OUTLET="1"
	TALON_A="talon9"
	TALON_B="talon10"
elif [[ "$LRU" == "lru6" ]]; then
	PDU2_MODEL="APC_SNMP"
	PDU2_OUTLET="2"
	TALON_A="talon11"
	TALON_B="talon12"
elif [[ "$LRU" == "lru7" ]]; then
	PDU2_MODEL="APC_SNMP"
	PDU2_OUTLET="3"
	TALON_A="talon13"
	TALON_B="talon14"
elif [[ "$LRU" == "lru8" ]]; then
	PDU2_MODEL="APC_SNMP"
	PDU2_OUTLET="4"
	TALON_A="talon15"
	TALON_B="talon16"
else
	echo "ERROR: Unknown LRU \"$LRU\". No OUTLETS assigned."
	exit 1
fi

# Outlet status constants
OUTLET_OFF=0
OUTLET_ON=1
OUTLET_UNKNOWN=2

function powerOnDLI() {
	local outlet=$1
	curl -s -S -u ${USER}:${PASS} -X PUT -H "X-CSRF: x" --data "value=true" --digest "http://${PDU_IP}/restapi/relay/outlets/=${outlet}/state/"
}

function powerOffDLI() {
	local outlet=$1
	curl -s -S -u ${USER}:${PASS} -X PUT -H "X-CSRF: x" --data "value=false" --digest "http://${PDU_IP}/restapi/relay/outlets/=${outlet}/state/"
}

function statusDLI() {
	local outlet=$1
	
	local json_resp=`curl -s -S -u ${USER}:${PASS} -H "Accept: application/json" --digest "http://${USER}:${PASS}@${PDU_IP}/restapi/relay/outlets/=${outlet}/"`
	local outlet_state=`echo $json_resp | sed -n 's/.*"state":\([^,}]*\).*/\1/p'`

	local outlet_status=$OUTLET_UNKNOWN
	if [[ "$outlet_state" == "false" ]]; then
		outlet_status=$OUTLET_OFF
	elif [[ "$outlet_state" == "true" ]]; then
		outlet_status=$OUTLET_ON
	fi
	return $outlet_status
}

function powerOnST() {
	local outlet=$1	
	${ST_PDU_SCRIPT} ${outlet} on
}

function powerOffST() {
	local outlet=$1	
	${ST_PDU_SCRIPT} ${outlet} off
}

function statusST() {
	local outlet=$1
	local st_script_out=$(${ST_PDU_SCRIPT} ${outlet} | tr -d '\n')

	# echo "st_script_out = $st_script_out"

	local outlet_status=$OUTLET_UNKNOWN
	if [[ "$st_script_out" == *'OFF' ]]; then
		outlet_status=$OUTLET_OFF
	elif [[ "$st_script_out" == *'ON' ]]; then
		outlet_status=$OUTLET_ON
	fi
	return $outlet_status
}

function powerOnSNMP() {
	local outlet=$1
    local ipaddr=$2
	snmpset -v3 -u $SNMP_USER -a MD5 -A $SNMP_PASS -l AuthNoPriv $ipaddr "$SNMP_OID_BASE.$outlet" i 1 >/dev/null 2>&1
	sleep 5
}

function powerOffSNMP() {
        local outlet=$1
        local ipaddr=$2
        snmpset -v3 -u $SNMP_USER -a MD5 -A $SNMP_PASS -l AuthNoPriv $ipaddr "$SNMP_OID_BASE.$outlet" i 2 >/dev/null 2>&1
	sleep 5
}

function statusSNMP() {
	local outlet=$1
    local ipaddr=$2
	snmp_return=$(snmpget -v3 -u $SNMP_USER -a MD5 -A $SNMP_PASS -l AuthNoPriv $ipaddr "$SNMP_OID_BASE.$outlet")
	snmp_outlet_return=$(echo "${snmp_return##* }")
	local outlet_status=$OUTLET_UNKNOWN
        if [[ "$snmp_outlet_return" == '1' ]]; then
                outlet_status=$OUTLET_ON
        elif [[ "$snmp_outlet_return" == '2' ]]; then
                outlet_status=$OUTLET_OFF
        fi
        return $outlet_status
}

function displayOutletStatus () {
	local pdu1_outlet_status=$OUTLET_UNKNOWN
	if [[ "$PDU1_MODEL" =~ "DLI" ]]; then
		statusDLI $PDU1_OUTLET
		pdu1_outlet_status=$?
	elif [[ "$PDU1_MODEL" =~ "ST" ]]; then
		statusST $PDU1_OUTLET
		pdu1_outlet_status=$?
	elif [[ "$PDU1_MODEL" =~ "APC_SNMP" ]]; then
		statusSNMP $PDU1_OUTLET $PDU1_SNMP_IP
		pdu1_outlet_status=$?
	fi
	#echo "pdu1_outlet_status = $pdu1_outlet_status"
	
	if [[ -n "$PDU2_OUTLET" ]]; then	
		local pdu2_outlet_status=$OUTLET_UNKNOWN
		if [[ "$PDU2_MODEL" =~ "DLI" ]]; then
			statusDLI $PDU2_OUTLET
			pdu2_outlet_status=$?
		elif [[ "$PDU2_MODEL" =~ "ST" ]]; then
			statusST $PDU2_OUTLET
			pdu2_outlet_status=$?
		elif [[ "$PDU2_MODEL" =~ "APC_SNMP" ]]; then
                        statusSNMP $PDU2_OUTLET $PDU2_SNMP_IP
                        pdu2_outlet_status=$?
		fi	
		#echo "pdu2_outlet_status = $pdu2_outlet_status"
	fi
	
	# The LRU is ON if either of the two power sources is ON
	if [[ $pdu1_outlet_status == $OUTLET_ON ]] || [[ $pdu2_outlet_status == $OUTLET_ON ]]; then
		LRU_STATE="ON"
	else
		LRU_STATE="OFF"
	fi

	# This echo should not be changed because system-tests look
	# for the exact match.
	echo "${LRU} status: ${LRU_STATE}"
}


if [[ "$STATE" =~ on|On|ON ]]; then
	echo "Powering on $PDU1_MODEL PDU's outlet $PDU1_OUTLET for $LRU"
	if [[ "$PDU1_MODEL" =~ "DLI" ]]; then
		powerOnDLI $PDU1_OUTLET
	elif [[ "$PDU1_MODEL" =~ "ST" ]]; then
		powerOnST $PDU1_OUTLET
	elif [[ "$PDU1_MODEL" =~ "APC_SNMP" ]]; then
                powerOnSNMP $PDU1_OUTLET $PDU1_SNMP_IP
	fi

	if [[ -n "$PDU2_OUTLET" ]]; then	
		echo "Powering on $PDU2_MODEL PDU's outlet $PDU2_OUTLET for $LRU"
		if [[ "$PDU2_MODEL" =~ "DLI" ]]; then
			powerOnDLI $PDU2_OUTLET
		elif [[ "$PDU2_MODEL" =~ "ST" ]]; then
			powerOnST $PDU2_OUTLET
		elif [[ "$PDU2_MODEL" =~ "APC_SNMP" ]]; then
                        powerOnSNMP $PDU2_OUTLET $PDU2_SNMP_IP
		fi
	fi

	displayOutletStatus

elif [[ "$STATE" =~ off|Off|OFF ]]; then
	echo "Shutting down ${TALON_A}..."
	ssh -o ConnectTimeout=$SSH_TIMEOUT_IN_SECONDS root@${TALON_A} -n shutdown now
	echo "Shutting down ${TALON_B}..."
	ssh -o ConnectTimeout=$SSH_TIMEOUT_IN_SECONDS root@${TALON_B} -n shutdown now
	echo "Sleeping for 15 seconds..."
	sleep 15

	echo "Powering off $PDU1_MODEL PDU's outlet $PDU1_OUTLET for $LRU"
	if [[ "$PDU1_MODEL" =~ "DLI" ]]; then
		powerOffDLI $PDU1_OUTLET
	elif [[ "$PDU1_MODEL" =~ "ST" ]]; then
		powerOffST $PDU1_OUTLET
	elif [[ "$PDU1_MODEL" =~ "APC_SNMP" ]]; then
                powerOffSNMP $PDU1_OUTLET $PDU1_SNMP_IP
	fi

	if [[ -n "$PDU2_OUTLET" ]]; then	
		echo "Powering off $PDU2_MODEL PDU's outlet $PDU2_OUTLET for $LRU"
		if [[ "$PDU2_MODEL" =~ "DLI" ]]; then
			powerOffDLI $PDU2_OUTLET
		elif [[ "$PDU2_MODEL" =~ "ST" ]]; then
			powerOffST $PDU2_OUTLET
		elif [[ "$PDU2_MODEL" =~ "APC_SNMP" ]]; then
                        powerOffSNMP $PDU2_OUTLET $PDU2_SNMP_IP
		fi
	fi

	displayOutletStatus

elif [[ "$STATE" == "" ]]; then
	displayOutletStatus

else
	echo -e "ERROR: Unrecognized STATE \"$STATE\" provided.\n"
	echo "$USAGE_BANNER"
	exit 1
fi
