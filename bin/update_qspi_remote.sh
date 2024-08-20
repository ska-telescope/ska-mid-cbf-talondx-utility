#!/bin/bash

# This script lives on the Development server.
# It is used to program/update the QSPI partitions with various application images.
#
# Author: Abtin Ghodoussi | abtin.ghodoussi@mda.space
# Date: May 22 2024

echo "--------------------------------------------------QSPI UPDATE--------------------------------------------------"

display_help_banner()
{
    echo "\
    ****************************************************************************
    update_qspi_remote.sh ARCHIVE TALON_BOARD PARTITION [-no_reboot] [-f]
    
    ARCHIVE:
        The .tar.gz archive containing a valid QSPI image file (*application.hps.rpd)
        The script calculates the MD5 hash of the .rpd file inside this tar package.
    TALON_BOARD:
        talon1, talon2, talon3, etc...
    PARTITION:
        software    | SOFTWARE  | sw    | SW    | s | 0
        hardware    | HARDWARE  | hw    | HW    | h | 1
        test        | TEST      | tst   | t     | 2
    -no_reboot (optional):
        skip the automatic linux reboot after programming.
    -f (optional)
        Force programming the QSPI partition regardless of 
        the number of differences between the requested partition and the loaded partition. 
    ****************************************************************************
    
                        Flash Layout
                        -------------
    Partition1 (slot0)  |    SW     |   @0x1000000
                        -------------
    Partition2 (slot1)  |    HW     |   @0x2000000
                        -------------
    Partition3 (slot2)  |    TEST   |   @0x3000000
                        -------------        

    ****************************************************************************
    "
}

########## ERROR CODES ##########
ERROR_NO_PING=4
ERROR_REBOOT_REQUEST_FAILED=6
ERROR_UNREACHABLE_AFTER_SWITCH=7
ERROR_UNREACHABLE_AFTER_PROGRAMMING=8
ERROR_UNPACKING_ARCHIVE=2
ALL_OK=0
#################################

ARCHIVE=$1
talon_arg=$2
REQUESTED_QSPI_PARTITION=$3
TARGET_QSPI_SLOT=""
REBOOT_REQUEST=$4

FORCE_QSPI_PROGRAM=false
SKIP_REBOOT=false

TEMP_DIR=""

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

echo_yel(){
    echo -e "${YEL} $1 ${NC}"
}

echo_grn(){
    echo -e "${GRN} $1 ${NC}"
}

echo_red(){
    echo -e "${RED} $1 ${NC}"
}

# extract the board/ip only in case the "user" was also provided
# for example from "root@talon1" extract "talon1"
# or from "root@192.168.8.1" extract "192.168.8.1"
talon=$(echo "$talon_arg"| cut -d'@' -f 2)

if [[ -z $talon ]] || [[ -z $ARCHIVE ]] || [[ -z $REQUESTED_QSPI_PARTITION ]]; then
    display_help_banner
    exit 1
fi

#Check for optional arguments
for arg in "$@"; do
    if [ "$arg" = "-no_reboot" ]; then
        echo "Skipping reboot..."
        REBOOT_REQUEST=$arg
        SKIP_REBOOT=true
    fi
    if [ "$arg" = "-f" ]; then
        echo "Force programming enabled..."
        FORCE_QSPI_PROGRAM=true
    fi
done

case $REQUESTED_QSPI_PARTITION in
    software | SOFTWARE | sw | SW | s | 0)
        TARGET_QSPI_SLOT="0"
        ;;
    hardware | HARDWARE | hw | HW | h | 1)
        TARGET_QSPI_SLOT="1"
        ;;
    test | TEST | tst | t | 2)
        TARGET_QSPI_SLOT="2"
        ;;
    *)
        echo "Invalid partition requested"
        display_help_banner
        exit 2
        ;;
esac

echo "Selecting slot:${TARGET_QSPI_SLOT} for requested partition:$REQUESTED_QSPI_PARTITION"

cleanup_exit(){
    if [ -e "$TEMP_DIR" ]; then
        echo "removing $TEMP_DIR before exit"
        rm -rf "$TEMP_DIR"
    fi
    echo "Exit code $1"  
    exit "$1"
}

wait_for_valid_ping ()
{
    local TARGET_BOARD;
    local MAX_TIME_OUT;

    TARGET_BOARD=$1
    MAX_TIME_OUT=$2

    start_time=$(date +%s)

    echo "Waiting maximum $MAX_TIME_OUT seconds for $TARGET_BOARD to respond to pings..."

    while true
    do
        echo -ne "###"

        #ping 3 times or timeout after 5 seconds
        PING_COMMAND=$(ping -w 5 -c 3 "$TARGET_BOARD" 2>&1)
        ping_result=$?

        curr_time=$(date +%s)
        delta=$((curr_time-start_time))

        if [ $ping_result -eq 0 ]; then
            echo -e "\nGot ping back from $TARGET_BOARD after ~$delta seconds"
            return 0
        fi

        if [ $ping_result -ne 0 ] && [ $delta -ge "$MAX_TIME_OUT" ]; then
            echo -e "\nUnable to ping the board after $MAX_TIME_OUT seconds..."
            return 1
        fi
        
        sleep 0.5
    done
}

is_partition_empty()
{
    echo "checking if the partition is empty"

    local requested_slot;
    local target_board;

    target_board=$1
    requested_slot=$2
    
    is_disabled=$(ssh root@"$target_board" -n "rsu_client --list $requested_slot" | awk '/PRIORITY/ {print $2}')
 
    if [ "$is_disabled" = "[disabled]" ]; then
        echo "requested slot is empty"
        return 0
    else
        echo "requested slot is not empty"
        return 1
    fi
}

compare_qspi_images ()
{
    echo "Computing the differences between the loaded image and the requested image"

    local requested_qspi_file;
    local target_board;
    local slot_num;

    requested_qspi_file=$1
    target_board=$2
    slot_num=$3
    # A small number of bytes difference between the programmed QSPI slot and 
    #the reference file is expected likely due to added meta data and checksum.
    ALLOWED_NUMBER_OF_DIFFERENCES=10

    if is_partition_empty "$target_board" "$slot_num"; then
        return 1
    fi

    ssh root@"$target_board" -n "rsu_client --copy /lib/firmware/current_qspi_slot${slot_num}.bin --slot $slot_num"

    #count the number of differences between the requested file and the programmed file 
    num_diff=$(ssh root@"$target_board" -n "cmp -l /lib/firmware/$requested_qspi_file /lib/firmware/current_qspi_slot${slot_num}.bin | wc -l")
    #clean-up
    ssh root@"$target_board" -n "rm /lib/firmware/current_qspi_slot${slot_num}.bin"

    echo -n "There are $num_diff differences (of $ALLOWED_NUMBER_OF_DIFFERENCES allowed) between the programmed partition and the requested partition. "

    if [[ "$FORCE_QSPI_PROGRAM" == false ]] && [[ "$num_diff" -lt "$ALLOWED_NUMBER_OF_DIFFERENCES" ]] ; then
        echo "Skipping programming. Only $num_diff differences (and FORCE_PROGRAMMING is $FORCE_QSPI_PROGRAM), QSPI slot $slot_num is likely already programmed."
        return 0
    else 
        echo "Continuing with programming..."
        return "$num_diff"
    fi
}

check_error()
{
    local exit_code;
    local error_message;
    exit_code=$1
    error_message=$2

    if [ "$exit_code" -ne 0 ]; then
        echo "Error programming the QSPI slot${TARGET_QSPI_SLOT}"
        if [ -z "$error_message" ]; then
            echo_red "$error_message: $exit_code"
        fi
        cleanup_exit "$exit_code"
    fi  
}

# search the given hash in a look-up table and return the version string.
look_up_official_hash()
{
    local computed_hash_string;
    local official_version;
    local __resultVar=$2; #variable is passed by "reference"

    computed_hash_string=$1

    case $computed_hash_string in

    "ee118626efa7ecc8754b26649417f969")
        __official_version="0.5.0"
        ;;
    "eae18ec2daf5749fdd3168b513e84e11")
        __official_version="0.2.6"
        ;;
    "a9cd73a54842252e0832dc23fce6d32e")
        __official_version="0.2.5"
        ;;
    "68c953ebcef1eed314bb67d0be3a9141")
        __official_version="0.2.4"
        ;;
    "7cd5b078d061864d5f8a761bd6138f72")
        __official_version="0.2.3"
        ;;
    "a015c874c4569caf09139d3e99341770")
        __official_version="0.2.2"
        ;;
    *)
        echo "Warning, the computed hash of .rpd file $computed_hash_string is not an official release"
        echo "Remote update is supported starting from version 0.2.2"
        __official_version="unofficial"
        ;;
    esac

    if [ "$__official_version" != "unofficial" ]; then
        echo "Using official version $__official_version with hash: $computed_hash_string"
    fi

    # set the passed variable to the look-up value
    eval $__resultVar="'$__official_version'"
}

remote_log_db(){
    key=$1
    value=$2
    ssh root@"$talon" -n "/bin/qspi_partition.sh -dbw $key $value"
}

remote_log_partition_version()
{
    echo "Logging info on the board"

    local slot_number;
    local partition_file;
    local off_vers; #variable to store the official version, passed by reference

    slot_number=$1
    partition_file=$2

    hash=$(md5sum "$partition_file" | cut -d" " -f1)

    look_up_official_hash "$hash" off_vers
    remote_log_db "partition{$slot_number}_hash" "${hash}_version:${off_vers}"

    current_date=$(date --utc +%F_%T_UTC)
    remote_log_db "partition{$slot_number}_dateTime" "$current_date"

    curr_user=$(whoami)
    remote_log_db "partition{$slot_number}_dev" "$curr_user"
}

#Ensure the talon board is up before programming it, blocking while loop
if ! wait_for_valid_ping "$talon" 40; then
    echo "$talon was unreachable. Aborting programming..."
    cleanup_exit $ERROR_NO_PING
fi

TEMP_DIR=$(mktemp -d -t bitstreamPKG-XXXXXX)
echo_yel "unpacking $ARCHIVE at $TEMP_DIR"
if ! tar -xzf "$ARCHIVE" -C "$TEMP_DIR"; then
    echo "Unable to unpack the archive, check if it is a tar.gz package"
    cleanup_exit $ERROR_UNPACKING_ARCHIVE
fi 

application_update=$(find "$TEMP_DIR" -name "*application.hps.rpd"); check_error $? "Unable to unpack or find the .hps.rpd in the archive"
application_update_basename=$(basename "$application_update")
echo "Using qspi_file: $application_update"

#copy the file over
scp "$application_update" root@"$talon":/lib/firmware

echo "Requesting log from rsu_client..."
ssh root@"$talon" -n "rsu_client --log"; check_error $? "failed to request the log";
echo "Requesting number of slots from rsu_client..."
ssh root@"$talon" -n "rsu_client --count"; check_error $? "failed to request the number of slots";

compare_qspi_images "$application_update_basename" "$talon" "$TARGET_QSPI_SLOT"
result=$?

if [ "$result" -eq 0 ] ; then
    #request the board to switch to the required partition if needed
    echo "Requesting a partition switch from the board..."
    ssh root@"$talon" -n "/bin/qspi_partition.sh $REQUESTED_QSPI_PARTITION $REBOOT_REQUEST"
    result=$?

    if [ $result -ne 0 ]; then
        echo "Unable to request a reboot. Please check if /bin/qspi_partition.sh exists on the target board!"
        cleanup_exit $ERROR_REBOOT_REQUEST_FAILED
    elif ! wait_for_valid_ping "$talon" 40; then
        echo "$talon was unreachable after requesting a switch. Quitting..."
        cleanup_exit $ERROR_UNREACHABLE_AFTER_SWITCH
    else
        #No need to proceed any furthur
        echo_grn "Partition switch was done!"
        cleanup_exit $ALL_OK
    fi
fi

#erase slot
echo "Erasing slot ${TARGET_QSPI_SLOT}"
ssh root@"$talon" -n "rsu_client --erase $TARGET_QSPI_SLOT"; check_error $? "failed to erase the slot";

#write and verify slot
echo "Writing the image..."
ssh root@"$talon" -n "rsu_client --add /lib/firmware/$application_update_basename --slot $TARGET_QSPI_SLOT"; check_error $? "failed to write the image";
echo "Verifying the image..."
ssh root@"$talon" -n "rsu_client --verify /lib/firmware/$application_update_basename --slot $TARGET_QSPI_SLOT"; check_error $? "failed to verify the image";

#request slot to be loaded explicitly
echo "requesting/enabling slot${TARGET_QSPI_SLOT}" 
ssh root@"$talon" -n "rsu_client --request $TARGET_QSPI_SLOT"; check_error $? "failed to request the image explicitly";
ssh root@"$talon" -n "rsu_client --enable $TARGET_QSPI_SLOT"; check_error $? "failed to enable the image explicitly";

#update the onboard log file
remote_log_partition_version "$TARGET_QSPI_SLOT" "$application_update"

if ! $SKIP_REBOOT; then

    echo "Rebooting target board..."
    ssh root@"$talon" -n "reboot -n && exit"

    echo "Sleeping for 10 seconds..."
    sleep 10

    #blocking while loop
    if ! wait_for_valid_ping "$talon" 40; then
        echo_red "Error reaching the board after reprogramming and rebooting..."
        cleanup_exit $ERROR_UNREACHABLE_AFTER_PROGRAMMING
    else
        echo_grn "Board was reachable after programming and rebooting. DONE!"
    fi

else
    echo "Reboot (reboot -n) or power cycle the board to load with the requested QSPI partition. DONE!"
fi

cleanup_exit $ALL_OK
