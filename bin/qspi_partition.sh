#!/bin/sh

# This script must live on the talon boards at talon:/bin/
# It is used by other scripts to provide uitlity and simplifcation of varoius-
# Remote system Update (RSU) feature to the user.
#
# Author: Abtin Ghodoussi | abtin.ghodoussi@mda.space
# Date: June 26 2023

display_help_banner () 
{
    echo "\
    ****************************************************************************
    qspi_partiton.sh [-i] PARTITION [-no_reboot] 

    This script must live on the talon boards at /bin/
    
    -i (optional):
        Print the status of the flash partitions and exit
    PARTITION:
        software    | SOFTWARE  | sw    | SW    | s | 0
        hardware    | HARDWARE  | hw    | HW    | h | 1
        test        | TEST      | tst   | t     | 2
    -no_reboot (optional):
        skip the automatic linux reboot after programming.
    ****************************************************************************
    "
}

DATABASE_FILE=/home/root/talon_log.db

REQUESTED_QSPI_PARTITION=$1
TARGET_QSPI_SLOT="INVALID"

main(){

    #special case, database entry and query
    if [ "$1" = "-dbw" ]; then
        echo_h "Writing to file at ${DATABASE_FILE}"
        db_set "$2" "$3"
        exit 0
    fi

    #special case, board status argument
    if [ "$1" = "-i" ]; then
        get_current_loaded_partition
        cat $DATABASE_FILE
        exit 0
    fi;

    # normal operation, first argument is mandatory
    if [ -z "$1" ]; then
        display_help_banner
        exit 1
    fi

    # check for optional argument
    if [ "$2" = "-no_reboot" ]; then
        echo_h "Skipping reboot..."
        SKIP_REBOOT=true
    else
        SKIP_REBOOT=false
    fi

    get_desired_partition

    get_current_loaded_partition
    
    if [ $? = $TARGET_QSPI_SLOT ]; then
        echo_h "Loaded partition is the same as the requested partition, nothing to do. DONE!"
        exit 0
    fi

    if ! /bin/rsu_client --enable $TARGET_QSPI_SLOT; then
        echo_h "error! unable to enable the desired partition"
        exit 3
    fi

    if ! /bin/rsu_client --request $TARGET_QSPI_SLOT; then
        echo_h "error! unable to request the desired partition"
        exit 5
    fi

    if ! $SKIP_REBOOT; then
        echo_h "Rebooting..."
        reboot -n & exit 0
    else
        echo_h "Reboot (reboot -n) or power cycle the board to load with the requested QSPI partition"
    fi
}

db_set() {
    #check if the key exists first
    if grep -qs "^$1," "$DATABASE_FILE"; then
        #it exists, replace the value (by replacing the entire line in-place)
        sed -i "s/^$1,.*/$1,$2/" $DATABASE_FILE
    else
        #it does not exist, insert a new key-value pair into the file
        echo "$1,$2" >> "$DATABASE_FILE"
    fi
}
 
db_get() {
    grep "^$1," "$DATABASE_FILE" | sed -e 's/^$1,//' | tail -n 1
}
 
echo_h ()
{
    h_name=$(hostname)
    echo "$h_name: $1"
}

get_desired_partition()
{
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
            echo_h "Invalid partition requested"
            display_help_banner
            exit 2
            ;;
    esac

    echo_h "Selecting slot:${TARGET_QSPI_SLOT} for requested partition:$REQUESTED_QSPI_PARTITION"
}

get_current_loaded_partition ()
{
    loaded_address_offset=$(rsu_client --log | awk '/CURRENT IMAGE/ {print $3}')
    current_loaded_partition=""

    case $loaded_address_offset in
        0x0000000001000000)
            current_loaded_partition="0 (software)"
            ;;
        0x0000000002000000)
            current_loaded_partition="1 (hardware)"
            ;;
        0x0000000003000000)
            current_loaded_partition="2 (test)"
            ;;
        *)
            echo_h "Unknown loaded partition(slot) at $loaded_address_offset, aborting..."
            exit 4
            ;;
    esac

    echo_h "Currently loaded slot: $current_loaded_partition"

    return $current_loaded_partition
}

main "$@"; exit 
