#!/bin/sh
#
# One updater.sh to rule them all
#
# 2006.10.24 Marcin 'Hrw' Juszkiewicz
# - started work on common updater.sh
# - works on poodle, c760, spitz
# - breaks on tosa
#
# 2007.10.08 Marcin 'Hrw' Juszkiewicz
# - do not allow to flash files bigger then partition size
# - created functions for common stuff
#
# 2007.11.18 Dmitry 'Lumag' Baryshkov
# - fixes
# - tosa unbreak
#
# 2007.11.19 Marcin 'Hrw' Juszkiewicz
# - size check unbreak
# - c760/c860 has bigger rootfs - use it
#
# 2007.11.23 Koen Kooi
# - consistent error messages
# - fix flashing from case sensitive filesystem (e.g. ext2)
#
# 2007.11.23 Matthias 'CoreDump' Hentges
# - Always treat MTD_PART_SIZE as HEX when comparing sizes
# - Thanks to ZeroChaos for debugging
#
# 2007.12.04 Matthias 'CoreDump' Hentges
# - Unb0rk flashing of Akita kernels
#
# 2007.12.10 Marcin 'Hrw' Juszkiewicz
# - Reformatted file - please use spaces not tabs
# - "version check" is only on Tosa and Poodle - breaks other machines
#
# 2007.12.23 Matthias 'CoreDump' Hentges
# - Fix kernel install on spitz machines
# - Unify format of do_flashing()...
# - Display ${PR} of zaurus-updater.bb to the user
# - Polish HDD installer messages
#
# 2007.12.25 Matthias 'CoreDump' Hentges
# - Add support for installing / updating u-boot
#
# 2008.11.23 Dmitry 'lumag' Baryshkov
# - Add support for reflashing home partitions
#
# 2010.02.02 Andrea 'ant' Adami
# - Fix nandlogical writing of kernel
#   Bug in Sharp original line...
#   /sbin/nandlogical $LOGOCAL_MTD WRITE $ADDR $DATASIZE $TMPDATA > /dev/null 2>&1
#   didn't use correctly determined block size
#
# 2010.04.18 Andrea 'ant' Adami
# - Add support for flashing pure jffs2 rootfs, without Sharp headers
#
# 2017.05.05 Andrea 'ant' Adami
# - Fix RW_MTD_SIZE
# - Fix RO_MTD_LINE in case of hardcoded partitioning
# - Define SMF_MTD_* instead of hardcoding, replace LOGOCAL_MTD
# - Add support for repartitioning
# - Limit screen output to 30 chars
#
# 2017.05.17 Andrea 'ant' Adami
# - Major Version bump: 2017.05
# - do not hardcode smf/logocal = mtd1
# - check total flash size
# - add Partition Manager: view, resize, erase partitions

DATAPATH=$1
TMPPATH=/tmp/update
TMPDATA=$TMPPATH/tmpdata.bin
TMPHEAD=$TMPPATH/tmphead.bin

FLASHED_MAINTE=0
FLASHED_KERNEL=0
FLASHED_ROOTFS=0
FLASHED_HOMEFS=0
UNPACKED_ROOTFS=0   # spitz only

SMF_MTD_LINE=`cat /proc/mtd | grep "smf" | tail -n 1`
if [ "$SMF_MTD_LINE" = "" ]; then
    SMF_MTD_LINE=`cat /proc/mtd | grep "\<NAND\>.*\<0\>" | tail -n 1`
fi
SMF_MTD_NO=`echo $SMF_MTD_LINE | cut -d: -f1 | cut -dd -f2`
SMF_MTD=/dev/mtd$SMF_MTD_NO
SMF_SIZE=`echo $SMF_MTD_LINE | cut -d" " -f2`
SMF_SIZE_MB=`dc 0x$SMF_SIZE 1024 / 1024 /`

RO_MTD_LINE=`cat /proc/mtd | grep "root" | tail -n 1`
if [ "$RO_MTD_LINE" = "" ]; then
    RO_MTD_LINE=`cat /proc/mtd | grep "\<NAND\>.*\<1\>" | tail -n 1`
fi
RO_MTD_NO=`echo $RO_MTD_LINE | cut -d: -f1 | cut -dd -f2`
RO_MTD=/dev/mtd$RO_MTD_NO
ROOTFS_SIZE=`echo $RO_MTD_LINE | cut -d" " -f2`
ROOTFS_SIZE_MB=`dc 0x$ROOTFS_SIZE 1024 / 1024 /`

RW_MTD_LINE=`cat /proc/mtd | grep "home" | tail -n 1`
if [ "$RW_MTD_LINE" = "" ]; then
    RW_MTD_LINE=`cat /proc/mtd | grep "\<NAND\>.*\<2\>" | tail -n 1`
fi
RW_MTD_NO=`echo $RW_MTD_LINE | cut -d: -f1 | cut -dd -f2`
RW_MTD=/dev/mtd$RW_MTD_NO
HOMEFS_SIZE=`echo $RW_MTD_LINE | cut -d" " -f2`
HOMEFS_SIZE_MB=`dc 0x$HOMEFS_SIZE 1024 / 1024 /`

MAX_FSRO_SIZE_MB=`expr $ROOTFS_SIZE_MB + $HOMEFS_SIZE_MB - 1`

VERBLOCK=0x48000
MVRBLOCK=0x70000

RESULT=0
SEP="------------------------------"

Cleanup()
{
    rm -f $VTMPNAME > /dev/null 2>&1
    rm -f $MTMPNAME > /dev/null 2>&1
    exit $1
}

trap 'Cleanup 1' 1 15
trap '' 2 3

get_dev_pcmcia()
{
    while read SOCKET CLASS DRIVER INSTANCE DEVS MAJOR MINOR;
    do
        echo $DEVS
    done
}

get_dev_pcmcia_slot()
{
    grep "^$1" /var/lib/pcmcia/stab | get_dev_pcmcia
}

check_for_hdd()
{
    IDE1=`get_dev_pcmcia_slot 1`
    if [ "$IDE1" = "" ]; then
        echo 'Error: There is no microdrive. Retrying...'
        while [ "$IDE1" = "" ]; do
            IDE1=`get_dev_pcmcia_slot 1`
        done
        echo 'Microdrive found.'
    fi

    LINUXFMT=ext3
    MKE2FSOPT=-j
}

check_for_tar()
{
    ### Check that we have a valid tar
    for TARNAME in gnu-tar GNU-TAR
    do
        if [ -e $DATAPATH/$TARNAME ]
        then
            TARBIN=$DATAPATH/$TARNAME
        fi
    done

    if [ ! -e $TARBIN ]; then
        echo 'Error: Please place a valid copy of tar as "gnu-tar" on your card.'
        echo 'Please reset'
        while true
        do
        done
    fi
}

do_rootfs_extraction()
{
    UNPACKED_ROOTFS=1
    echo 'Installing HDD root file system'
    if [ ! -f /hdd1/NotAvailable ]; then
        umount /hdd1
    fi
    echo -n '* Now formatting...'
    mke2fs $MKE2FSOPT /dev/${IDE1}1 > /dev/null 2>&1
    e2fsck -p /dev/${IDE1}1 > /dev/null
    if [ "$?" != "0" ]; then
        echo 'FAILED'
        echo 'Error: Unable to create filesystem on microdrive!'
        exit "$?"
    else 
        echo 'done'
    fi

    mount -t $LINUXFMT -o noatime /dev/${IDE1}1 /hdd1
    if [ "$?" != "0" ]; then
        echo 'Error: Unable to mount microdrive!'
        exit "$?"
    fi

    cd /hdd1
    echo -n '* Now extracting (this can take over 5m)...'
    gzip -dc $DATAPATH/$TARGETFILE | $TARBIN xf -
    if [ "$?" != "0" ]; then
        echo 'FAILED'
        echo 'Error: Unable to extract root filesystem archive!'
        exit "$?"
    else
        echo 'done'
    fi

    echo 'HDD Installation Finished.'

    # remount as RO
    cd /
    umount /hdd1
    mount -t $LINUXFMT -o ro,noatime /dev/${IDE1}1 /hdd1
}

do_flashing()
{
        if [ $DATASIZE -gt `printf "%d" $MTD_PART_SIZE` ]
        then
                echo 'Error: File is too big to flash!'
                echo "$FLASH_TYPE: [$DATASIZE] > [`printf "%d" ${MTD_PART_SIZE}`]"
                return
        fi

        #check version (common to all models)
        /sbin/bcut -s 6 -o $TMPDATA $TMPHEAD
        if [ `cat $TMPDATA` != "SHARP!" ] > /dev/null 2>&1
        then
            #check for known fake headers
            if [ `cat $TMPDATA` != "OZ!3.1" ] > /dev/null 2>&1
            then
                #no version info...
                rm -f $TMPHEAD > /dev/null 2>&1
                DATAPOS=0
            fi
        fi

        if [ $ISFORMATTED = 0 ]
        then
                echo -n 'Flash erasing...'
                /sbin/eraseall $TARGET_MTD > /dev/null 2>&1
                echo 'done'
                ISFORMATTED=1
        fi

        if [ -e $TMPHEAD ]
        then
                VTMPNAME=$TMPPATH'/vtmp'`date '+%s'`'.tmp'
                MTMPNAME=$TMPPATH'/mtmp'`date '+%s'`'.tmp'
                /sbin/nandlogical $SMF_MTD READ $VERBLOCK 0x4000 $VTMPNAME > /dev/null 2>&1
                /sbin/nandlogical $SMF_MTD READ $MVRBLOCK 0x4000 $MTMPNAME > /dev/null 2>&1

                /sbin/verchg -v $VTMPNAME $TMPHEAD $MODULEID $MTD_PART_SIZE > /dev/null 2>&1
                /sbin/verchg -m $MTMPNAME $TMPHEAD $MODULEID $MTD_PART_SIZE > /dev/null 2>&1
        fi

        # Looks like Akita and Spitz are unique when it comes to kernel flashing
        if [ "$ZAURUS" = "akita" -o "$ZAURUS" = "c3x00" ] && [ "$FLASH_TYPE" = "kernel" ]
        then
                echo ''
                echo -n 'Installing SL-Cxx00 kernel...'
                echo '                ' > /tmp/data
                test "$ZAURUS" = "akita" && /sbin/nandlogical $SMF_MTD WRITE 0x60100 16 /tmp/data > /dev/null 2>&1
                /sbin/nandlogical $SMF_MTD WRITE 0xe0000 $DATASIZE $TARGETFILE > /dev/null 2>&1
                test "$ZAURUS" = "akita" && /sbin/nandlogical $SMF_MTD WRITE 0x21bff0 16 /tmp/data > /dev/null 2>&1
                echo 'done'
        else
                echo ''
                echo '0%                   100%'
                PROGSTEP=`expr $DATASIZE / $ONESIZE + 1`
                PROGSTEP=`expr 25 / $PROGSTEP`

                if [ $PROGSTEP = 0 ]
                then
                    PROGSTEP=1
                fi

                #loop
                while [ $DATAPOS -lt $DATASIZE ]
                do
                        #data create
                        bcut -a $DATAPOS -s $ONESIZE -o $TMPDATA $TARGETFILE
                        TMPSIZE=`wc -c $TMPDATA`
                        TMPSIZE=`echo $TMPSIZE | cut -d' ' -f1`
                        DATAPOS=`expr $DATAPOS + $TMPSIZE`

                        #handle data file
                        if [ $ISLOGICAL = 0 ]
                        then
                                next_addr=`/sbin/nandcp -a $ADDR $TMPDATA $TARGET_MTD  2>/dev/null | fgrep "mtd address" | cut -d- -f2 | cut -d\( -f1`
                                if [ "$next_addr" = "" ]; then
                                        echo 'Error: flash write'
                                        rm $TMPDATA > /dev/null 2>&1
                                        RESULT=3
                                        break;
                                fi
                                ADDR=$next_addr
                        else
                                /sbin/nandlogical $SMF_MTD WRITE $ADDR $TMPSIZE $TMPDATA > /dev/null 2>&1
                                ADDR=`expr $ADDR + $TMPSIZE`
                        fi

                        rm $TMPDATA > /dev/null 2>&1

                        #progress
                        SPNUM=0
                        while [ $SPNUM -lt $PROGSTEP ]
                        do
                                echo -n '.'
                                SPNUM=`expr $SPNUM + 1`
                        done
                done
        fi
        echo ''

        #finish
        rm -f $TMPPATH/*.bin > /dev/null 2>&1

        if [ $RESULT = 0 ]
        then
                if [ -e $VTMPNAME ]
                then
                    /sbin/nandlogical $SMF_MTD WRITE $VERBLOCK 0x4000 $VTMPNAME > /dev/null 2>&1
                    rm -f $VTMPNAME > /dev/null 2>&1
                fi

                if [ -e $MTMPNAME ]
                then
                    /sbin/nandlogical $SMF_MTD WRITE $MVRBLOCK 0x4000 $MTMPNAME > /dev/null 2>&1
                    rm -f $MTMPNAME > /dev/null 2>&1
                fi

                [ "$FLASH_TYPE" != "kernel" ] && echo 'done.'
        else
                echo 'Error!'
        fi
}

mainte_fix()
{
    # binaries taken from Cacko 1.23 installer
    case "$MODEL" in
        SL-C760|SL-C860|SL-C1000|SL-C3100|SL-C3200)
            echo -n 'Flashing Mainte fix for 128M flash...'
            if ( /sbin/nandlogical $SMF_MTD WRITE 0x00, 327680, $TARGETFILE ) > /dev/null 2>&1
            then
                echo 'done'
                # unnecessary fix for FSRW end addr / size ? (kernel parser sharpslpart ignores it)
                # OUTFILE=$TMPPATH/128M_fix.bin
                # printf '\x08' > $OUTFILE
                # /sbin/nandlogical $LOGOCAL_MTD WRITE 0x60027, 1, $OUTFILE > /dev/null 2>&1
                # /sbin/nandlogical $LOGOCAL_MTD WRITE 0x64027, 1, $OUTFILE > /dev/null 2>&1
                # rm -f $OUTFILE > /dev/null 2>&1
                exit 0
            fi
            ;;
        *)
            ;;
    esac
}

check_partitions()
{
    if [ $FLASH_SIZE_MB -gt `expr $SMF_SIZE_MB + $ROOTFS_SIZE_MB + $HOMEFS_SIZE_MB` ]
    then
        printf "%b\n" "$SEP\n\033[1;31mFlash size mismatch!\033[0m\nThis unit is repartitioned and\nyou \033[1;31mmust\033[0m flash  \033[1;33mmainte_fix.bin\033[0m"
        printf "%b\n" "to keep this partition layout,\notherwise resize root to \033[1;32m$DEF_ROOTFS_SIZE_MB\033[0m MB"
        printf "%b\n" "\nReset to factory settings  can\nbe done entering  \033[1;33mService Menu\033[0m\nand running \033[1;32mNAND Flash Restore\033[0m\n$SEP\n"
    fi
}

partition_manager()
{
    while true; do
        ANSW=""
        read -p "Partition Manager? (y/n): " ANSW
        if expr "$ANSW" : '[Yy]\+$' > /dev/null 2>&1
        then
            break
        elif expr "$ANSW" : '[Nn]\+$' > /dev/null 2>&1
        then
            return
        fi
    done

    clear
    printf "%b\n" "\n\033[1;31mZAURUS\033[1;32m PARTITION MANAGER\033[0m\n$SEP\n1 View\n2 Resize\n3 Erase\n\n0 Exit\n$SEP"

    while true; do
        ANSW=""
        read ANSW

        case "$ANSW" in
            1)  view_partitions
                ;;
            2)  change_partitions
                ;;
            3)  erase_partitions
                ;;
            0)  exit 0
                ;;
            *)
                ;;
        esac
    done
}

view_partitions()
{
    printf "%b\n" "$SEP\nPartition  \033[1msmf    root    home\033[0m"
    printf "%b\n" "Size (MB)   \033[1;32m$SMF_SIZE_MB      $ROOTFS_SIZE_MB      $HOMEFS_SIZE_MB\033[0m\n$SEP"
}


erase_partitions()
{
    while true; do
        ANSW=""
        read -p "Erase partitions? (y/n): " ANSW
        if expr "$ANSW" : '[Yy]\+$' > /dev/null 2>&1
        then
            break
        elif expr "$ANSW" : '[Nn]\+$' > /dev/null 2>&1
        then
            return
        fi
    done

    echo -n 'Erasing root partition... '
    /sbin/eraseall $RO_MTD > /dev/null 2>&1
    echo 'done'
    echo -n 'Erasing home partition... '
    /sbin/eraseall $RW_MTD > /dev/null 2>&1
    echo 'done'
}

change_partitions()
{
    while true; do
        ANSW=""
        read -p "Resize partitions? (y/n): " ANSW
        if expr "$ANSW" : '[Yy]\+$' > /dev/null 2>&1
        then
            break
        elif expr "$ANSW" : '[Nn]\+$' > /dev/null 2>&1
        then
            return
        fi
    done

    while true; do
        FSRO_SIZE_MB=""
        read -p "New root size (1-$MAX_FSRO_SIZE_MB): " FSRO_SIZE_MB
        if expr "$FSRO_SIZE_MB" : '[0-9]\+$' > /dev/null 2>&1 &&
           [ $FSRO_SIZE_MB -gt 0 ] > /dev/null 2>&1 &&
           [ $FSRO_SIZE_MB -le $MAX_FSRO_SIZE_MB ] > /dev/null 2>&1
        then
            break
        fi
    done

    FSRW_SIZE_MB=`expr $ROOTFS_SIZE_MB + $HOMEFS_SIZE_MB - $FSRO_SIZE_MB`

    FSRO_END_B=`expr $(($(($SMF_SIZE_MB + $FSRO_SIZE_MB)) << 20))`

    B1=`printf '%08x' $FSRO_END_B | cut -c1-2`
    B2=`printf '%08x' $FSRO_END_B | cut -c3-4`
    B3=`printf '%08x' $FSRO_END_B | cut -c5-6`
    B4=`printf '%08x' $FSRO_END_B | cut -c7-8`

    OUTFILE=$TMPPATH/fsro_end_le.bin
    printf '\x'$B4'\x'$B3'\x'$B2'\x'$B1 > $OUTFILE
    /sbin/nandlogical $SMF_MTD WRITE 0x60014, 4, $OUTFILE > /dev/null 2>&1
    /sbin/nandlogical $SMF_MTD WRITE 0x60020, 4, $OUTFILE > /dev/null 2>&1
    /sbin/nandlogical $SMF_MTD WRITE 0x64014, 4, $OUTFILE > /dev/null 2>&1
    /sbin/nandlogical $SMF_MTD WRITE 0x64020, 4, $OUTFILE > /dev/null 2>&1
    rm -f $OUTFILE > /dev/null 2>&1

    printf "%b\n" "$SEP\nPartition  \033[1msmf    root    home\033[0m"
    printf "%b\n" "Size (MB)   \033[1;33m$SMF_SIZE_MB      $FSRO_SIZE_MB      $FSRW_SIZE_MB\033[0m\n$SEP"

    exit 0
}

### Check model ###
/sbin/writerominfo
MODEL=`cat /proc/deviceinfo/product`

case "$MODEL" in
    SL-B500|SL-5600)
        ZAURUS='poodle'
        FLASH_SIZE_MB=64
        DEF_ROOTFS_SIZE_MB=22
        ;;
    SL-C700|SL-C750|SL-C7500)
        ZAURUS='c7x0'
        FLASH_SIZE_MB=64
        DEF_ROOTFS_SIZE_MB=25
        ;;
    SL-C760|SL-C860)
        ZAURUS='c7x0'
        FLASH_SIZE_MB=128
        DEF_ROOTFS_SIZE_MB=53
        ;;
    SL-C1000)
        ZAURUS='akita'
        FLASH_SIZE_MB=128
        DEF_ROOTFS_SIZE_MB=58
        ;;
    SL-C3000)
        ZAURUS='c3x00'
        check_for_hdd
        check_for_tar
        FLASH_SIZE_MB=16
        DEF_ROOTFS_SIZE_MB=5
        ;;
    SL-C3100)
        ZAURUS='c3x00'
        check_for_hdd
        check_for_tar
        FLASH_SIZE_MB=128
        DEF_ROOTFS_SIZE_MB=32
        ;;
    SL-C3200)
        ZAURUS='c3x00'
        check_for_hdd
        check_for_tar
        FLASH_SIZE_MB=128
        DEF_ROOTFS_SIZE_MB=43
        ;;
    SL-6000)
        ZAURUS='tosa'
        FLASH_SIZE_MB=128
        DEF_ROOTFS_SIZE_MB=28
        ;;
    *)
        echo 'MODEL: '$MODEL 'is unsupported'
        echo ''
        echo 'Please reset'
        while true
        do
        done
        ;;
esac

clear
printf "%b\n" "\033[1;32m--- Zaurus Updater ZAURUS_UPDATER_VERSION ---\033[0m\n    MODEL: $MODEL ($ZAURUS)\n"

check_partitions

mkdir -p $TMPPATH > /dev/null 2>&1

cd $DATAPATH/

FOUND_FILES=0
for TARGETFILE in zimage zImage zImage.bin zimage.bin ZIMAGE ZIMAGE.BIN \
                initrd.bin INITRD.BIN hdimage1.tgz HDIMAGE1.TGZ home.bin \
                HOME.BIN mainte_fix.bin MAINTE_FIX.BIN
do
    if [ ! -e $TARGETFILE ]
    then
        continue
    fi
    FOUND_FILES=1

    rm -f $TMPPATH/*.bin > /dev/null 2>&1
    DATASIZE=`wc -c $TARGETFILE`
    DATASIZE=`echo $DATASIZE | cut -d' ' -f1`

    # make TARGETFILE lowercase
    TARGETFILE_LC=`echo $TARGETFILE|tr A-Z a-z`

    case "$TARGETFILE_LC" in

    zimage|zimage.bin)
        if [ $FLASHED_KERNEL != 0 ]
        then
            continue
        fi
        echo 'kernel'
        FLASHED_KERNEL=1
        ISLOGICAL=1
        MODULEID=5
        MTD_PART_SIZE=0x13C000
        ADDR=`dc 0xE0000`
        ISFORMATTED=1
        DATAPOS=0
        ONESIZE=524288
        HDTOP=`expr $DATASIZE - 16`
        /sbin/bcut -a $HDTOP -s 16 -o $TMPHEAD $TARGETFILE
        FLASH_TYPE="kernel"
        do_flashing
        FLASH_TYPE=""
        ;;

    initrd.bin)
        if [ $FLASHED_ROOTFS != 0 ]
        then
            continue
        fi
        echo 'root file system'
        FLASHED_ROOTFS=1
        ISLOGICAL=0
        MODULEID=6
        MTD_PART_SIZE="0x$ROOTFS_SIZE"
        ADDR=0
        ISFORMATTED=0
        TARGET_MTD=$RO_MTD
        DATAPOS=16
        ONESIZE=1048576
        /sbin/bcut -s 16 -o $TMPHEAD $TARGETFILE
        FLASH_TYPE="rootfs"
        do_flashing
        FLASH_TYPE=""
        ;;

    home.bin)
        if [ $FLASHED_HOMEFS != 0 ]
        then
            continue
        fi
        echo 'home file system'
        FLASHED_HOMEFS=1
        ISLOGICAL=0
        ADDR=0
        ISFORMATTED=0
        MTD_PART_SIZE="0x$HOMEFS_SIZE"
        ADDR=0
        TARGET_MTD=$RW_MTD
        #home should not have headers but one could flash a second rootfs here
        DATAPOS=16
        ONESIZE=1048576
        FLASH_TYPE="home"
        /sbin/bcut -s 16 -o $TMPHEAD $TARGETFILE
        do_flashing
        FLASH_TYPE=""
        ;;

    hdimage1.tgz)
        if [ $UNPACKED_ROOTFS = 0 ]
        then
                do_rootfs_extraction
        fi
        ;;

    mainte_fix.bin)
        echo 'Mainte fix for models with 128M flash'
        if [ $FLASHED_MAINTE != 1 ]
        then
                mainte_fix
                FLASHED_MAINTE="1"
        fi
        ;;

    *)
        ;;

    esac
done

if [ $FOUND_FILES = 0 ]
then
    printf "%b\n" "$SEP\n\033[1;33mNo files found to flash!\033[0m\n$SEP\n"
    partition_manager
fi

# reboot
exit 0

# bcut usage: bcut [OPTION] <input file>

# -a: start position
# -s: cut size
# -o: output file

# ModuleId informations used by verchg Sharp binary:
#
# 0 - master
# 1 - Maintaince
# 2 - Diagnostics
# 3 - rescue kernel
# 4 - rescue rootfs
# 5 - normal kernel
# 6 - normal rootfs
# 7 - /home/
# 8 - parameter (whatever it means)
#
