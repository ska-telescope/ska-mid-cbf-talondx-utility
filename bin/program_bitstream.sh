#!/bin/bash

display_help_banner()
{
    echo "\
    ****************************************************************************
    program_bitstream.sh [ARCHIVE] [TALON_BOARD] [PARTITION] [-no_reboot] [-f]

    NOTE: passing only 2 arguments attempts to program the bitstream in legacy mode, 
          where no checks are made for the QSPI partitions or the RSU feature.

    ARCHIVE:
        The .tar.gz archive containing a valid bitstream, JSON file and dtb overlay file
    TALON_BOARD:
        talon1, talon2, talon3, etc...
    PARTITION:
        software    | SOFTWARE  | sw    | SW    | s | 0
        hardware    | HARDWARE  | hw    | HW    | h | 1
        test        | TEST      | tst   | t     | 2
    -no_reboot (optional):
        skip the automatic linux reboot after programming the QSPI
    -f (optional)
        Force programming the QSPI partition regardless of
        the number of differences between the requested partition and the loaded partition.
    ****************************************************************************
    "
}

SCRIPT_ROOT_DIR="/shared/talon-dx-utilities/bin"

ARCHIVE=$1
BOARD_ARG=$2
REQUESTED_QSPI_PARTITION=$3

LEGACY_MODE=false
REBOOT_REQUEST=""
FORCE_QSPI_PROGRAM=""

# extract the board/ip only in case the "user" was also provided
# for example from "root@talon1" extract "talon1"
# or from "root@192.168.8.1" extract "192.168.8.1"
BOARD=$(echo "$BOARD_ARG"| cut -d'@' -f 2)

#Check for optional arguments
for arg in "$@"; do
    if [ "$arg" = "-no_reboot" ]; then
        REBOOT_REQUEST=$arg
    fi
    if [ "$arg" = "-f" ]; then
        FORCE_QSPI_PROGRAM=$arg
    fi
done

if [ "$#" -eq 2 ]; then
    echo "Programming bitstream in legacy mode"
    LEGACY_MODE=true 
fi

if ! $LEGACY_MODE; then
    if [[ -z $BOARD ]] || [[ -z $ARCHIVE ]] || [[ -z $REQUESTED_QSPI_PARTITION ]]; then
        display_help_banner
        exit 1
    fi
    echo "Programming bitstream in RSU mode"
fi

program_bitstream()
{
    echo "--------------------------------------------------BITSTREAM PROGRAMMING--------------------------------------------------"

    local ARCHIVE;
    local BOARD;
    local path;
    local name;

    ARCHIVE=$1
    BOARD=$2
    path="/sys/kernel/config/device-tree/overlays"
    name="base"

    temp_dir=$(mktemp -d -t bitstreamPKG-XXXXXX)
    echo "unpacking $ARCHIVE at $temp_dir"
    tar -xvzf "$ARCHIVE" -C "$temp_dir"

    bs_core=$(find "$temp_dir" -name "*.rbf")
    dtb=$(find "$temp_dir" -name "*.dtb")
    json=$(find "$temp_dir" -name "*.json")

    scp "$bs_core" "$dtb" "$json" root@"$BOARD":/lib/firmware
    ssh root@"$BOARD" -n "rmdir $path/*; mkdir $path/$name" # trigger removal of old device tree and setup the next image.
    ssh root@"$BOARD" -n "cd /lib/firmware && echo $(basename "$dtb") > $path/$name/path"
    ssh root@"$BOARD" -n "dmesg | tail -n 10"

    echo "removing $temp_dir before exit"
    rm -rf "$temp_dir"
}

#reprogram the QSPI if needed
if ! $LEGACY_MODE; then
    if ! "$SCRIPT_ROOT_DIR"/update_qspi_remote.sh "$ARCHIVE" "$BOARD" "$REQUESTED_QSPI_PARTITION" "$FORCE_QSPI_PROGRAM" "$REBOOT_REQUEST"; then
        echo "Error updating the QSPI, aborting bitstream programming..."
        exit 2
    else
        echo "Proceeding to program the bitstream..."
    fi
fi

program_bitstream "$ARCHIVE" "$BOARD"
