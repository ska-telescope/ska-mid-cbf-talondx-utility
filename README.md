# ska-mid-cbf-talondx-utility

Various scripts for programming the bitstream and QSPI for the talon boards.

### Usage
change the `$SCRIPT_ROOT_DIR` within `program_bitstrea.sh` script to the directory where the repo is cloned, then run:
```
program_bitstream.sh ska-mid-cbf-talondx-0.5.0.tar.gz talon5 hw
```
### program_bitstream.sh
programs the bitstream on the talon boards. It relies on the `update_qspi_remote.sh` and `qspi_partition.sh` internally and will update the QSPI automatically if neccessary. User needs to only call this upper level script. 

run `-h` for help.

### update_qspi_remote.sh
remotely updates the QSPI. It requires the QSPI to be already 'primed' for remote update using JTAG once (which should be normally be done at MDA already).

run `-h` for help.
### qspi_partition.sh
utlity scirpt placed on the talon boards at `/bin`. It facicilates remotely updating the QSPI. It also does some basic logging on the talon boards. This script is called internally by the other scripts. User can querry the basic logs from the talon boards by running:
``` 
root@talon5: qspi_partition.sh -i

talon8: Currently loaded slot: 2 (test)
partition{0}_hash,ee118626efa7ecc8754b26649417f969_version:unofficial
partition{0}_dateTime,2024-08-02_23:16:10_UTC
partition{0}_dev,jso
partition{1}_hash,e0d8b5cea7deb00310e5b950daae3d2f_version:unofficial
partition{1}_dateTime,2024-08-14_22:09:53_UTC
partition{1}_dev,ab005920
partition{2}_hash,212c2d9f0b784d32a8821aad786d4140_version:unofficial
partition{2}_dateTime,2024-08-15_14:35:49_UTC
partition{2}_dev,ji003314

```
run `-h` for help.