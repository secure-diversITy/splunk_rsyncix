#!/bin/bash
##################################################################################################################################
#
# Sync LOCAL indices to remote destination (will REMOVE existing files @ DESTINATION!)
# Author: Thomas Fischer <mail@sedi.one>
# Copyright: 2017-2020 Thomas Fischer <mail@sedi.one>
#
VERSION="5.3.12"
###################################################################################################################################
#
### who am I ?
TOOLX="${0##*/}"
TOOL="${TOOLX/\.sh/}"
### LICENSE
# This code is licensed under the Creative Commons License: CC BY-SA 4.0
#
### DISCLAIMER
#
# The following deed **highlights only** some of the key features and terms of the actual license.
# It is NOT a license and has NO legal value. You should carefully review ALL of the terms and conditions of the actual
# license before using the licensed material.
#
# Please check the following link for details and the full legal content:
#
# http://creativecommons.org/licenses/by-sa/4.0/legalcode
#
##### You are free to:
#
# * Share - copy and redistribute the material in any medium or format
# * Adapt - remix, transform, and build upon the material
# 
# for any purpose, even commercially.
#
# The licensor cannot revoke these freedoms as long as you follow the license terms.
#
##### Under the following terms:
#
# * Attribution:
# 
#   You must give appropriate credit, provide a link to the license, and indicate if changes were made.
#   You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.
#   
# * ShareAlike:
# 
#   If you remix, transform, or build upon the material, you must distribute your contributions under the same
#   license as the original.
#
##################################################################################################################################

# path to the (maybe patched) rsync bin
RSYNC=/usr/bin/rsync

# shelper: https://github.com/secure-diversITy/splunk
# required on the REMOTE server as well!
# check --help-install
SHELPER=/usr/local/bin/shelper

# a list of tools required to run this script
# check --help-install
REQUIREDTOOLS="/usr/bin/bc $RSYNC /usr/bin/mail /usr/bin/ssh /usr/bin/scp $SHELPER"

# LOCAL(!) SPLUNK installation dir! Adjust to match your installation!
# local = where you start this script.
SPLDIR=/opt/splunk

# the full path to the REMOTE splunk installation dir (must be identical for all remote servers)
# remote = your sync targets.
REMSPLDIR=/opt/splunk

# full path to the REMOTE splunk pid, needed for pausing sync while splunk is stopped
# check systemd/init script for the correct path
#REMLCKSPL=/var/lock/subsys/splunk

# when checking if splunk daemon is running this defines the amount of time you want to give splunkd
# to settle up properly after starting (i.e. REMLCKSPL is there but splunkd reads in data etc)
# format: sleep syntax (i.e. 300s, 5m, 10d ..)
WAITINITDELAY=2m

###########################################################################################################
##### E-MAIL settings start 
###########################################################################################################

# enable or disable E-Mail notifications (1 = enabled, 0 = disabled)
MAILSYNC=0

# mail recipients need to be specified on CLI. Check --help!
# The next both options handle the amount of emails to send.
# Choose the one best matching your needs or disable completely.

# email after each sync block = 1 otherwise set this to 0.
# Can be overwritten at CLI (check --help)
MAILJOBBLOCK=0

# email after a full sync run (1 = enable, 0 = disable)
# Can be overwritten at CLI (check --help)
MAILSYNCEND=0

# define what is a long duration. This will be used to filter out fast sync runs
# within the email when you also set MAILONLYLONG=1
# Format: "X.yz" (time in hours)
# ATTENTION: If you want to specify anything lower then 1 hour do not write the leading 0
# Examples:
# LONGRUN="2.00" means you will see in the email output sync runs only which taken 2 hours or longer
# LONGRUN=".50" means 30 minutes (do not write leading 0)
LONGRUN=".50"

# if you want a FULL / UNFILTERED log set this to 0.
# otherwise set to 1 and depending on the above LONGRUN setting you will receive in the mail output only
# those data where the sync takes longer then LONGRUN
# Can be overwritten at CLI (check --help)
MAILONLYLONG=1

# Throttle mails is a feature you may want to enable to avoid massive mail amounts.
# Some time your source and destination will hopefully are fully in sync and when this happens you will run
# through each job very fast. This will result in multiple mails in a minute which can easily fill up your mail box.
# To avoid this simply adjust the following value and within the given amount of seconds you will not receive any
# mail! e.g. when MAILTHROTTLESEC=3600 it means you will receive 1 mail / hour even if there would be more.
# Set this to a very high value (e.g. MAILTHROTTLESEC=999999999999999) and you will receive ALWAYS a mail.
MAILTHROTTLESEC=3600

###########################################################################################################
##### E-MAIL settings END 
###########################################################################################################

###########################################################################################################
##### GENERAL settings start 
###########################################################################################################

# default IO priority (take also a look at FULLSPEEDPRIO to find out how to optimize sync speed)
DEFIOPRIO=5

# Debug mode (should be better set on the cmdline - check --help)
DEBUG=0

# heavy debug mode (should be set on the cmdline -> check --help)
# This mode will enable set -x so if you do not want to see your terminal explode ... then better never use this! ;)
HEAVYDEBUG=0

# set to 1 to run forever (endless rsync) or to 0 to run it once only
# overriding possible and recommended at cmdline (check --help)
ENDLESSRUN=0

# when debugging you can specify a time value for the very first pseudo sync process.
# we wait that amount of time which can be helpful for debugging several functions like ionice change
# time eval etc. It is highly recommended to specify something really unusual like 324s and not 60s
# because we filter the process list for exact this setting
# Format: sleep syntax (e.g. 17s = 17 seconds, 14m = 14 minutes , ...)
SLEEPTIME=0s

# the following list seperated by pipe "|" will NOT be synced
# everything in that list will be EXCLUDED from the sync process
DEFDISABLEDIX="historydb|fishbucket|internal|audit|introspection|defaultdb|blockSignature|^_.*"

# The SCP cipher for processing the file copy
# check --help-speed for getting an idea which one is the best in your environment!
SCPCIPHER="aes192-cbc"

# EXCLUSIONS
# e.g. (cluster specific): do you want to copy REPLICATED buckets? Usually not so this is for excluding these
# EXCLON=true enables the list of excludes while setting it to false will not exclude anything at all
EXCLON=true
# the (local) file name to be used for handling the exclude pattern list (usually never touch this)
SYNCEXCLUDES=/tmp/${TOOL}.excluded
# rb_*: replicated copies from another indexer in the cluster
# *.rbsentinenel: special lock files used on windows based systems
# hot_*: copying hot buckets WILL causes issues due to different bucket rolling etc, also see HOTSYNC
# each pattern must be on a new line and this list can be extended as you wish ofc.
# https://docs.splunk.com/Documentation/Splunk/latest/Indexer/HowSplunkstoresindexes#Bucket_names
cat >$SYNCEXCLUDES<<EOFEXCL
rb_*
*\.rbsentinel
hot_*
GlobalMetaData
_splunktemps
EOFEXCL
GREPSYNCEXCLUDES='rb_|hot_|\.rbsentinel|GlobalMetaData|_splunktemps'

# do you want to sync hot buckets?
# can be 0 (no) or 1 (yes).
# when set to 1 ensure you adjust indexes.conf on the REMOTE servers so no bucket rolling occurs and
# splunkd init/systemd script should be adjusted to remove hot buckets before actually starting splunk.
# hot buckets will be *not* added to the local sync-fishbucket as we cannot determine when a sync is
# needed or not
HOTSYNC=0

if [ $HOTSYNC -eq 1 ];then
    cat >$SYNCEXCLUDES<<EOFEXCL
rb_*
*\.rbsentinel
GlobalMetaData
_splunktemps
EOFEXCL
    GREPSYNCEXCLUDES="${GREPSYNCEXCLUDES/hot_/}"
fi

# when new buckets have been synced (i.e. REALLY new ones which NEVER been synced before)
# the remote system can be notified about the new bucket arrival.
# can be 1 (yes) or 0 (no)
IWANTREMOTENOTIFY=1

# the remote notify command to use (will be executed on the REMOTE server)
#EXECREMNOTIFY="shelperstatus"

# the remote splunk binary (needs usually no adjustment)
REMSPLUNKBIN=${REMSPLDIR}/bin/splunk

# the WAITNOTIFY sets the minimal waiting time in SECONDS before the next notify happens.
# this is to avoid situations where a notify would be done on every run etc.
# requires IWANTREMOTENOTIFY=1
WAITNOTIFY=60

# log file
LOG=./${TOOL}.log

# Logging needs rotate cleanups:
MINLOGMB=100         # only rotate when log is bigger then ... MB.
MAXGLOG=8           # keep that amount of general log files
MAXSLOG=10          # keep that amount of summaryinfo log files

ARCHDIR=./${TOOL}_archive   # directory where to store rotated logs

# splunk authentication credentials
# these are usually better given on the CLI but you if you like to have it hard-coded here..
# ensure you have read --help-install to know about the needed splunk user credentials and
# where and when they are needed
# format is: "<username>:<password>"
[ -z "$SPLCREDS" ] && \
SPLCREDS="admin:changeme"

# the fishbucket db paths where all the sync mappings are stored
FDBPATH=./fishbucket

###########################################################################################################
##### GENERAL settings END
###########################################################################################################

###########################################################################################################
##### PRIORITY settings start
###########################################################################################################
# Flexible priority based on weekend and / or time of day
# Hint: The prio will be changed for NEW and already RUNNING rsync jobs!
# You can specify this fullspeedprio value directly from the commandline (check --help)
DEFFULLSPEEDPRIO=3

# Full speed time means that we run with a higher priority within a given time range.
# You can define as many time ranges you want delimited by a space!
# FULLSPEEDTIME0 = Sunday
# FULLSPEEDTIME1 = Monday
# FULLSPEEDTIME2 = Tuesday
# FULLSPEEDTIME3 = Wednesday
# FULLSPEEDTIME4 = Thursday
# FULLSPEEDTIME5 = Friday
# FULLSPEEDTIME6 = Saturday
# TIMExPRIO value can be changed to whatever you want. Otherwise the above default FULLSPEEDPRIO above will be used.
# Order: time ranges are iterated from left to right so a good choice is to write the biggest range left
# Format: "HH:MM-HH:MM HH:MM-HH:MM HH:MM-HH:MM" (2 digit hour:2 digit minutes - 2 digit hour:2 digit minutes)
# Examples:
#   FULLSPEEDTIME0="00:00-23:59" (whole sunday)
#   FULLSPEEDTIME6="04:12-14:33 18:10-22:00" (both given time ranges on saturday)

FULLSPEEDTIME0="00:00-23:59"
TIME0PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME1="00:00-06:59 20:00-23:59"
TIME1PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME2="00:00-06:59 20:00-23:59"
TIME2PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME3="00:00-06:59 20:00-23:59"
TIME3PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME4="00:00-06:59 20:00-23:59"
TIME4PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME5="00:00-06:59 20:00-23:59"
TIME5PRIO=$DEFFULLSPEEDPRIO

FULLSPEEDTIME6="00:00-23:59"
TIME6PRIO=$DEFFULLSPEEDPRIO

#########
# some defaults for the included speed tester

# default ssh ciphers (can be overwritten by cmdline, check --help)
# these ciphers will be used in speed test.
# Format: cipher,cipher,...
DEFSPEEDCIPHER="aes192-cbc,arcfour256,arcfour,arcfour128,hostdefault"

# default round count (can be overwritten by cmdline, check --help)
DEFSPEEDROUNDS=5

# default test size (in Megabytes) / amount of data to be used (can be overwritten by cmdline, check --help)
DEFTESTSIZE=512

# default block size to use for dd data input. This setting can be overwritten at cmdline, check --help.
# For details about this setting checkout "--help", too.
DEFBSSIZE="1M"

###########
# Calculating sizes
 
# Do you want to calculate the index sizes for comparison and so check a successful sync?
# no action will be taken other then informing you (log file entry + mail when set) that there are diffs.
# Set to 1 if yes otherwise 0. This setting can be overwritten at cmdline, check --help!
# FORMAT: 1 or 0
CALCSIZES=1

# the maximum allowed diff for local vs. remote dir size in Kibibytes.
# e.g. 5242880 means 5 GB
# If CALCSIZES is set to 1 we will write a log entry for all indices where the local size differs more then
# the given amount. Set this to 0 to write a calc size log entry for each index.
MAXSYNCDIFFKB=5242880

###########################################################################################################
##### PRIORITY settings END
###########################################################################################################

#
# Do NOT walk behind this line
########################################################################################################
########################################################################################################
########################################################################################################
#
#

# mail throttle indicator file
LASTMAILFILE="${TOOL}.lastmail"

# the splunk binary
SPLUNKX=$SPLDIR/bin/splunk
[ ! -x "$SPLUNKX" ] && echo -e "ERROR: cannot find splunk binary >$SPLUNKX<. Please adjust SPLDIR variable inside $TOOLX and try again" && exit 2

# the internal rsync fishbucket (successfully synced bucket list)
#FISHBUCKET=./fishbucket_${TOOL}.db
#[ ! -f $FISHBUCKET ] && > $FISHBUCKET

# origin logfile
OLOG=$LOG

# file with the current detected IO prio (needed for re-nice later)
IOHELPERFILE="${TOOL}.ioprio"

# generate a current time value
F_GENTIME(){
    unset GENTIMEF
    GENTIMEF="$1"
    if [ -z "$GENTIMEF" ];then 
        GENTIME=$(date +%F__%T)
    else
        GENTIME=$(date +${GENTIMEF})
    fi
}

# rotate a logfile
F_ROTATELOG(){
    # rotate log
    if [ -z "$1" ];then
        F_LOG "ERROR MISSING LOG NAME FOR ROTATE!"
        return 2
    else
        F_GENTIME "%s"
        [ ! -d ${TOOL}_archive ] && mkdir ${TOOL}_archive
        LOGSZ=$(stat -c %s "$1")
        LOGSZMB=$((LOGSZ / 1024 / 1024))
        if [ $LOGSZMB -ge $MINLOGMB ];then
            gzip -c $1 > "./${TOOL}_archive/${1}_${GENTIME}.log.gz" && rm ${1}
        else
            F_LOG "skipping log rotate as size of $1 is less then $MINLOGMB MB ($LOGSZMB MB)"
            return 0
        fi
    fi
    
    if [ -d "$ARCHDIR" ];then
        # cleanup summary infos
        LFILES=$(find $ARCHDIR -maxdepth 1 -mindepth 1 -type f -name 'summaryinfo_*.log.gz')
        AMNT=$(echo -e "$LFILES" | sort | wc -l)
        F_LOG "summary log: $ARCHDIR has $AMNT files of $MAXSLOG allowed"
        while [ $AMNT -gt $MAXSLOG ];do
            F_LOG "summary log: $ARCHDIR has more then $MAXSLOG files. DELETING ......!"
            DELF=$(find $ARCHDIR -maxdepth 1 -mindepth 1 -type f -name 'summaryinfo_*.log.gz' -printf "%T@:%p\n" | sort -n |cut -d ":" -f 2 | head -n 1)
            [ -f "$DELF" ] && rm -vf "${DELF}" >> $LOG
            AMNT=$(($AMNT - 1))
            F_LOG "summary log: new amount: $AMNT"
        done
    
        # cleanup general log
        GFILES=$(find $ARCHDIR -maxdepth 1 -mindepth 1 -type f -name "${TOOL}*.log.gz")
        AMNT=$(echo -e "$GFILES" | sort | wc -l)
        F_LOG "general log: $ARCHDIR has $AMNT files of $MAXGLOG allowed"
        while [ $AMNT -gt $MAXGLOG ];do
            F_LOG "general log: $ARCHDIR has more then $MAXGLOG files. DELETING ......!"
            DELF=$(find $ARCHDIR -maxdepth 1 -mindepth 1  -type f -name "${TOOL}*.log.gz" -printf "%T@:%p\n" | sort -n |cut -d ":" -f 2 | head -n 1)
            [ -f "$DELF" ] && rm -vf "${DELF}" >> $LOG
            AMNT=$(($AMNT - 1))
            F_LOG "general log: new amount: $AMNT"
        done
    else
        F_LOG "Skipping rotating of $ARCHDIR as it does not exist"
    fi
}

# write a log entry with current time value
F_LOG(){
    F_GENTIME
    echo -e "$TOOL v${VERSION} - $GENTIME: $1" >> $LOG
}

# write to the original log instead of the dynamic one
F_OLOG(){
    F_GENTIME
    echo -e "$TOOL v${VERSION} - $GENTIME: $1" >> $OLOG
}

# e.g. when CTRL C pressed or a usual (p)kill happened
F_ABORT(){
    F_OLOG "!!!!! ABORTED ON USER REQUEST (SIGINT or SIGTERM was met) !!!!!!"
    rm -vf $LOCKFILE
    F_OLOG "Deleted last lock file <$LOCKFILE>."
    [ ! -z $SHPID ] && kill $SHPID >> $OLOG 2>&1 && F_OLOG "Stopped starthelper"
    rm -fv $IOHELPERFILE && F_OLOG "Removed ioprio file to auto kill starthelper(s)"
    exit
}
    
# rotate log
[ -f $LOG ] && echo "compressing previous logfile... this can take some seconds.." && F_ROTATELOG "$LOG"
echo "sync daemon started.."

# trap keyboard interrupt (e.g. control-c)
trap F_ABORT SIGINT SIGTERM

# get splunk environment!
F_GETSPLENV(){
    eval $($SPLUNKX envvars)  
    if [ -z "$SPLUNK_DB" ]||[ ! -d "$SPLUNK_DB" ];then
        F_OLOG "ERROR!!!! Cannot get valid splunk env!!!"
        F_ABORT
    fi
}

# check if date IO prio need to be adjusted
F_DATEIOCHECK()
{
    unset USEFULLSPEED FULLSPEEDTIME TIMEPRIO
    CURDAY=$(date +%w)
    CURTIME=$(date +%H%M)
    BEFOREIOPRIO=$IOPRIO

    [ -z $FULLSPEEDPRIO ] && FULLSPEEDPRIO=$DEFFULLSPEEDPRIO && F_LOG "$FUNCNAME: Using default full speed prio ($DEFFULLSPEEDPRIO)"
    TIMEPRIO=$FULLSPEEDPRIO
    
    case $CURDAY in
        0)
        FULLSPEEDTIME="$FULLSPEEDTIME0"
        #TIMEPRIO=$TIME0PRIO
        ;;
        1)
        FULLSPEEDTIME="$FULLSPEEDTIME1"
        #TIMEPRIO=$TIME1PRIO
        ;;
        2)
        FULLSPEEDTIME="$FULLSPEEDTIME2"
        #TIMEPRIO=$TIME2PRIO
        ;;
        3)
        FULLSPEEDTIME="$FULLSPEEDTIME3"
        #TIMEPRIO=$TIME3PRIO
        ;;
        4)
        FULLSPEEDTIME="$FULLSPEEDTIME4"
        #TIMEPRIO=$TIME4PRIO
        ;;
        5)
        FULLSPEEDTIME="$FULLSPEEDTIME5"
        #TIMEPRIO=$TIME5PRIO
        ;;
        6)
        FULLSPEEDTIME="$FULLSPEEDTIME6"
        #TIMEPRIO=$TIME6PRIO
        ;;
        *)
        echo "$FUNCNAME: We should never reach this --> We cannot detect the week day! ABORTED"
        exit 3
        ;;
    esac

    F_LOG "$FUNCNAME: Weekday: $CURDAY --> effective time range for full speed: $FULLSPEEDTIME"

    for t in $(echo "$FULLSPEEDTIME") ;do
        F_LOG "$FUNCNAME: Checking given time range: $t" 
        FSTART=$(echo ${t} | cut -d "-" -f1 |tr -d ":")
        FEND=$(echo ${t} | cut -d "-" -f2 |tr -d ":")
        F_LOG "$FUNCNAME: \t--> effective start time for full speed: $FSTART" 
        F_LOG "$FUNCNAME: \t--> effective end time for full speed: $FEND" 
        if [ $CURTIME -ge $FSTART ] && [ $CURTIME -le $FEND ];then
            USEFULLSPEED=$((USEFULLSPEED + 1))
            F_LOG "$FUNCNAME: Yeeeha! Full speed time ;-). Let the cable glow...!!" 
            F_LOG "$FUNCNAME: Skipping any other time ranges we may have because 1 ok is enough!" 
            break
        else
            USEFULLSPEED=0
            F_LOG "$FUNCNAME: We're not in full speed time range ($FSTART - $FEND)"  
        fi
    done

    # adjust - or not - the prio based on the time check
    if [ $USEFULLSPEED -gt 0 ];then
        [ $DEBUG -eq 1 ] && F_LOG "DEBUG: $FUNCNAME: time prio $TIMEPRIO, usefullspeed $USEFULLSPEED"
        # adjust the prio to run with full speed
        IOPRIO=$TIMEPRIO
    else
        [ $DEBUG -eq 1 ] && F_LOG "DEBUG: $FUNCNAME: time prio $IOPRIOUNTOUCHED, usefullspeed $USEFULLSPEED"
        # adjust the prio to run with given speed (either by -i or the default one)
        IOPRIO=$IOPRIOUNTOUCHED
    fi
    F_LOG "$FUNCNAME: Prio was set to: $IOPRIO"
    # write the current prio to a file so our ionice helper knows about
    echo "IOPRIO=$IOPRIO" > $IOHELPERFILE
}

# speed test
F_SPEED(){
    [ -z "$SPEEDTARGET" ]&& echo -e 'missing HOST arg ! aborted!' && exit
    [ -z "$SPEEDCIPHER" ]&& echo -e "Using default ssh cipher: $DEFSPEEDCIPHER" && SPEEDCIPHER=$DEFSPEEDCIPHER
    [ -z "$SPEEDROUNDS" ]&& echo -e "Using default test rounds: $DEFSPEEDROUNDS" && SPEEDROUNDS=$DEFSPEEDROUNDS
    [ -z "$TESTSIZE" ]&& echo -e "Using default test size: $DEFTESTSIZE" && TESTSIZE=$DEFTESTSIZE
    [ -z "$BSSIZE" ]&& echo -e "Using default block size: $DEFBSSIZE" && BSSIZE=$DEFBSSIZE
    SAVELOCATION="$1"
    
    CIPHERS=$(echo $SPEEDCIPHER|tr "," " ")
    unset ALLDDS DDRES
  
    RNDDEV=/dev/zero
    #SPEEDLOCALTMPF=/tmp/speedy.file
    
    #echo -e "\nGenerating local test file ..."
    #dd if=$RNDDEV bs=$BSSIZE count=$TESTSIZE of=$SPEEDLOCALTMPF >> /dev/null 2>&1
    
    for cipher in $CIPHERS ; do
        ALLDDS=0
        if [ "$cipher" == "hostdefault" ];then
            echo -e "\nUsing default cipher ($SPEEDROUNDS rounds):"
            for try in $(seq $SPEEDROUNDS); do
                DDRES=$((dd if=$RNDDEV bs=$BSSIZE count=$TESTSIZE | ssh -o "Compression no" $SPEEDTARGET "cat - > $SAVELOCATION") 2>&1 | grep "MB/s" |cut -d "," -f 3 | cut -d " " -f 2)
                echo "Current speed of this run: $DDRES MB/s"
                F_CALC "scale=2;$ALLDDS+$DDRES"
                ALLDDS="$CALCRESULT"
            done
        else
            echo -e "\nUsing $cipher ($SPEEDROUNDS rounds):"
            for try in $(seq $SPEEDROUNDS); do
                DDRES=$((dd if=$RNDDEV bs=$BSSIZE count=$TESTSIZE | ssh -c $cipher -o "Compression no" $SPEEDTARGET "cat - > $SAVELOCATION") 2>&1 | grep "MB/s" |cut -d "," -f 3 | cut -d " " -f 2)
                #echo "dd if=/dev/zero bs=$BSSIZE count=$TESTSIZE | ssh -c $cipher -o 'Compression no' $SPEEDTARGET 'cat - > $SAVELOCATION'"
                echo "Current speed of this run: $DDRES MB/s"
                F_CALC "scale=2;$ALLDDS+$DDRES"
                ALLDDS="$CALCRESULT"
            done
        fi
        F_CALC "scale=2;$ALLDDS/$SPEEDROUNDS"
        echo "AVERAGE SPEED: $CALCRESULT MB/s"
        unset DDRES
    done
}

F_FILESPEED(){
    [ -z "$STORE" ]&& F_LOG 'missing STORAGE arg ! aborted!' && exit
    F_SPEED "$STORE/.speedtestfile"
}

F_NETSPEED(){
  F_SPEED "/dev/null"
}

# well the "header" and basic intro
F_HELP(){
    cat <<EOHELP

    ... brought to you by secure diversITy <mail@sedi.one>
    
    
   $TOOL v${VERSION} USAGE / HELP
   ------------------------------
   
        -h|--help
        This output
        
        --help-install
        Installation notes for the sync tool setup
        
        --help-sync
        The help / usage info for the sync process
        
        --help-speed
        The help / usage info for the builtin speed tester
        
        --help-patch-rsync
        The help / usage info for how to patch rsync (required for -G | --remoteguid option only)
        
        --help-all
        All of the above


EOHELP
}

F_HELPINSTALL(){
    cat <<EOHELPINS
    
    ... brought to you by secure diversITy <mail@sedi.one>
    
    
    $TOOL v${VERSION} INSTALL NOTES
    ---------------------------------
    
    1) $TOOL expects the following tools installed:
    
       $REQUIREDTOOLS
    
       If those are installed in different locations adjust the REQUIREDTOOLS variable.


    2) The special helper tool "shelper" must be installed separately on the SOURCE server
       and on all REMOTE/TARGET servers as well (I recommend using ansible or similar):
    
       https://github.com/secure-diversITy/splunk
       (checkout the README there for the install/update steps)
    
    
    3) Some commands within $TOOL requires to have a valid CLI / API authToken and so it is
       recommended to add a specific user and role for that on the SOURCE and on ALL REMOTE
       servers as well.
       
       Required capabilities on the REMOTE servers:
    
            - indexes_edit (when IWANTREMOTENOTIFY=1 to inform REMOTE server about new bucket arrival)

            For a basic setup (with just the needed capabilities above):
        
            $> splunk add role syncrole -capability indexes_edit
            $> splunk add user syncuser -password 'YOURSECRET' -role syncrole

            Either adjust the SPLCREDS variable with: "syncrole:YOURSECRET" or start the sync with:
            
            $> SPLCREDS="syncrole:YOURSECRET" $TOOL ...
            
        Required capabilities on the LOCAL servers:
            
            - N/A no credentials or user required



EOHELPINS
}

F_HELPSPEED(){
    cat <<EOHELPSPEED

    ... brought to you by secure diversITy <mail@sedi.one>
    
    
   $TOOL v${VERSION} USAGE / HELP for the builtin speed tester
   --------------------------------------------------------------

   This speed test can only be an indicator and heavily depends on the current load on both machines
   i.e. when you are doing tests 10 min later the results might differ.
   
   I recommend to choose at least 50 rounds (the more the better) and testing once with
   filesize ("-b") of 128M, 1024M, 5120M and 10240M or any other values you are using as your bucket size.
   
   Of course this should be repeated for every different storage on the remote site (e.g. once for your FLASH
   storage, once for your HDD etc).
   
   The following both options can be used EXCLUSIVELY only and they HAVE TO be the first argument!
        
        -netspeed -s TARGETSERVER [-r ROUNDS -b BLOCKSIZE -m AMOUNT -c SSH-CIPHER]
            Test your connection by transferring data without any disk I/O
            The amount of data will be transferred without any disk IO.
            It uses the logic: local /dev/zero --> remote /dev/null
        
            -r ROUNDS
            Give a value of rounds. Each cipher - or the one you specified -
            will be check this amount of rounds (Current set default is $DEFSPEEDROUNDS).
            
            -b BLOCKSIZE
            We use "dd" for reading in data and therefore you can specify a blocksize in dd syntax here.
            Current set default: $DEFBSSIZE
            Example: "-b 150M" combined with "-m 1" will send 1 file with the size of (about) 150 MB
            
            -m SIZE/AMOUNT (ALWAYS: without unit! SIZE is ALWAYS in MB)
            Current set default file size: $DEFTESTSIZE * $DEFBSSIZE
            (how many data should be transferred)
            Example: "-b 1M" combined with "-m 1024" will send 1 file with the size of (about) 1024 MB and a block size of 1 MB
            
            -c SSH-CIPHER
            You can specify more then one cipher delimited by comma and within quotes (e.g. -c "blowfish-cbc,arcfour128")
            Default (if not set): $DEFSPEEDCIPHER
            To check available ciphers on the target execute this on the $TARGET(!):\n#> ssh -Q cipher localhost
            Best performance ciphers are usually (in that order):
                1) aes192-cbc
                2) arcfour256   (usually requires sshd_config adjustment)
                3) arcfour      (usually requires sshd_config adjustment)
                4) arcfour128   (usually requires sshd_config adjustment)
    
        -filespeed -s TARGETSERVER -p STORAGE-PATH [-r ROUNDS -b BLOCKSIZE -m AMOUNT -c SSH-CIPHER ]
        
            -p STORAGE-PATH
            The remote storage path where the test file should get written.
            The amount of data will be transferred and written to disk on the target.
            This WILL produce no local IO but on the remote site and is a more realistic check of the end result.
            It uses the logic: local /dev/null --> remote /path/.speedtestfile
            
            -r  --> SEE 'netspeed' above
            -m  --> SEE 'netspeed' above
            -c  --> SEE 'netspeed' above
            -b  --> SEE 'netspeed' above
   
EOHELPSPEED
}

F_HELPSYNC(){
    cat <<HELPSYNC
 
    ... brought to you by secure diversITy <mail@sedi.one>
    
    
   $TOOL v${VERSION} USAGE / HELP for the sync process
   --------------------------------------------------------------

    -y          This actually enables syncing. One of --ixdirmap or --ixmap is required, too
                (checkout the optional args if you want to override default options or starting in special modes).
    
    HINT: volume based index configuration is NOT supported yet!!!
    
    FULL SPEED time ranges are set within $TOOL and are checked every 60 seconds. This is done by an extra
    helper running independent from the current sync process.
    
    What happens when we enter or left the full speed time range?
      1) All RUNNING rsync processes started by $TOOL will be adjusted on-the-fly(!) either by full speed or by low speed!
      2) Any new rsync process will be started with the new prio
      
    The following FULL SPEED time ranges are currently set (modify the time variables to your needs within $TOOL):

            sunday:     $FULLSPEEDTIME0
            monday:     $FULLSPEEDTIME1
            tuesday:    $FULLSPEEDTIME2
            wednesday:  $FULLSPEEDTIME3
            thursday:   $FULLSPEEDTIME4
            friday:     $FULLSPEEDTIME5
            saturday:   $FULLSPEEDTIME6
    
    
    Sync: REQUIRED arguments
    --------------------------------------------------------------
    
    You have to choose one of the following to actually start syncing:
    
            --ixdirmap="<localdir,dbtype,remote-server:/remote/rootpath>"
                                
            The *ixdirmap* defines:
                
                    1) the local(!) directory you want to sync
                    2) the db type which can be either one of: db, colddb or summary
                    3) the remote SERVER where the local dir should be synced to (FQDN or IP)
                    4) the remote DIR where the local dir should be synced to (without index name|so the root dir)
                    
            This whole thing is ultra flexible and you can specify more then 1 mapping, of course!
            If you want to define more then 1 mapping just use space as delimeter and regardless
            of one or multiple mappings always use QUOTES!
     
    or alternatively if you are lazy and want to autodetect the LOCAL index path name:
    
        ATTENTION:
        ixmap is LEGACY and will not get any new features like GUID replacement etc. for this ixdirmap is needed.
        ixmap might get removed in v6 or later so better switch to ixdirmap NOW!
    
            --ixmap="<indexname,dbtype,remote-server:/remote/rootpath>"
                                
            The *ixmap* defines:
                    
                    1) The local index name you want to sync
                    2) the db type which can be either one of: db, colddb or summary                                    
                    3) the remote SERVER where the local dir should be synced to (FQDN or IP)
                    4) the remote DIR where the local index should be synced to (without index name|so the root dir)
                    
            This whole thing is ultra flexible and you can specify more then 1 mapping, of course!
            If you want to define more then 1 mapping just use space as delimeter and regardless
            of one or multiple mappings always use QUOTES!
    
    NONE of the above will actually start any workers in *PARALLEL*!
    That means if you have multiple mapping definitions in either ixdirmap or ixmap they run *sequential*, i.e. one after
    the other.
    BUT: if you want to run in parallel this is possible as well, of course! For this you need just a little preparation first:
        
        1) create a symlink for each worker like this:
            $> ln -s $TOOLX ${TOOLX}_XXX (e.g replace XXX with a number or custom name)
        
        2) execute ${TOOLX}_XXX with --ixmap or --ixdirmap option:
            $> ./${TOOLX}_XXX -y --ixdirmap="/var/dir1,colddb,srv1:/mnt/dir1 /var/dir2,db,srv1:/mnt/dir2"
            or
            $> ./${TOOLX}_XXX -y --ixmap="ix01,db,srv1:/mnt/fastdisk ix01,colddb,srv2:/mnt/slowdisk"
        
        3) repeat steps 1-2 for as many workers as you want to start

    
    Sync: OPTIONAL arguments
    --------------------------------------------------------------
    
    The following OPTIONAL parameters are available to override global defaults:

        You can specify - if you like - the priorities for either the default or the fullspeed
        or both (we always use the 'best-effort' scheduling class)
        -i [0-7]                    ionice prio for normal workhours (default is: $DEFIOPRIO)
                                    --> 0 means highest prio and 7 lowest
        -f [0-7]                    ionice full speed prio using more ressources on the server (default: $DEFFULLSPEEDPRIO)
                                    --> 0 means highest prio and 7 lowest
        
        -E [0|1]                    1 will let run $TOOL forever - 0 means one shot only. Overrides default setting.
                                    If choosing 1 the rsync jobs will run in a never ending loop
                                    (useful to minimize the delta between old and new environment)
                                    Currently it is set to: $ENDLESSRUN (0 oneshot, 1 endless loop)
                                                                
        --calcsizes=[0|1]           If set to 1 local size and remote size of each index will be calculated and written to
                                    summaryinfo_xxx logfile. Overrides default (currently set to $CALCSIZES).
                                
        -G  <REMOTE GUID>           This will replace a local (auto detected) splunk GUID with the given GUID on the remote server.
        --remoteguid=<REMOTE GUID>  you can identify the server GUID here: $SPLDIR/etc/instance.cfg
                                    i.e. the bucket directories will be renamed so they match with the remote running splunk instance.
                                    Keep in mind that this is completely unsupported by splunk - while working well (afaik).
                                    the special keyword: REMOVE will not replace the GUID but just remove it from the buckets instead.
                                    NOTE:
                                    This requires to have a detect-renamed patched version of rsync running on BOTH sites, i.e. the
                                    source and the target!
                                    see --help-patch-rsync for details on that.

        --renumber                  If you plan to sync from multiple servers to the same target you have to ensure unique bucket
                                    id numbering. This parameter takes no arguments and works fully automated.
                                    If you are unsure: use it, just to be safe.
                                    
                                    Example for a bucket collision:
                                        db_1576766743_1576650640_422_3D4AAFFC-979E-4FFE-AE82-52997802E3B3
                                        db_1583402308_1583186397_422_3D4AAFFC-979E-4FFE-AE82-52997802E3B3
                                    The timeframes are different but the bucket number/id (422) is not.
                                    This will prevent splunk from starting and so must be avoided.
                                    
                                    The renumbering logic is as follows (used for anything other then HOT buckets):
                                        1. the starting timestamp is parsed from the bucket
                                        2. the current bucket number gets replaced by the result from 1
                                        3. the resulting full bucket name will be checked against a CENTRAL
                                           fishbucket db on the REMOTE server:
                                            a. check lock state
                                            b. if db lock loop wait until its unlocked
                                            c. remote db will be locked
                                        4. if the name is unique it will be used and added to the local and remote db
                                           and the remote db will be unlocked
                                        5. if the name is already defined the number will be +1'd
                                        6. looping until 4 is true
                                        7. remote db will be unlocked
                                        
                                    The logic to prevent duplicates handles even HOT-buckets but slightly different:
                                        1. as there is no starting timestamp for hot buckets the current timestamp will be generated
                                        2. the current bucket number gets replaced by the result from 1
                                        3. the resulting full bucket name will be first checked against a LOCAL
                                           fishbucket db for hot buckets:
                                            a. if the current bucket number is found it will use the PREVIOUS generated one
                                            b. if the bucket number is NOT found the bucket number of 1 will be used
                                        4. steps 3-7 from above
                                        5. if 3b is true the local DB gets updated as well
                                    
        
        Mail related options:
        -------------------------------------------
 
        --maileachjob=[0|1]         Send an email after each JOB (1) or not (0) - Overrides default.
                                    Can be combined with all other mail* options.
                    
        --mailsyncend=[0|1]         Send an email after all JOBs are done (1) or not (0) - Overrides default.
                                    Can be combined with all other mail* options.
                                    If you use the -E option (endless run mode) after each full sync an email will be send.
                
        --mailto="<mailaddr>"       The receiver(s) of mails. You can specify more then 1 when delimiting by comma.
                                    e.g.: --mailto="here@there.com,none@gmail.com"
                                    You HAVE to use quotes here.
               
        --mailonlylong=[0|1]        Attach logfiles where a rsync took longer then >$LONGRUN< - Overrides default.
                                    Can be combined with all other mail* options.
    
        Debug options:
        -------------------------------------------
        
        --forcesync                 $TOOL uses an intelligent handling and detection of multiple running sync
                                    processes and will skip to sync a folder when another sync is currently processing it!
                                    With this setting you can force to sync even when another sync process is still running!
                                    Use this option with care because it could result in unexpected behavior - It is better to stop
                                    all other sync processes instead or take another run when the other sync job has finished.
        
        -D|--dry                    Using the D option enables the debug mode. In this mode NO real rsync job will be made!
                                    It will do a dry-run instead and the very first index will sleep for >$SLEEPTIME<
                                    Besides that some extra debug messages gets written into the logfile and you will get the
                                    summary info printed on stdout.
                                
        --heavydebug                Auto enables "-D". The absolute overload on debug messages. Actually will do 'set -x' so
                                    you will see really EVERYTHING. Use with care!!!
                                    Best practice is to redirect everything to a local file instead of stdout
                                    e.g: $TOOLX -y --heavydebug > ${TOOL}.debug
                                
HELPSYNC
}

F_HELPPATCHRSYNC(){
    cat <<HELPPATCHRSYNC
    
    ... brought to you by secure diversITy <mail@sedi.one>
    
    
    $TOOL v${VERSION} USAGE / HELP for patching rsync
    --------------------------------------------------------------
    
    rsync is not able to detect renamed files but this is what actually will happen in the sync
    process when using the -G | --remoteguid parameter. Regardless if you choose to REMOVE the GUID or
    replace it by another it will make rsync copy everything again the next time when it runs.
    
    For this to work properly a patch of rsync is needed and it is very easy to do.
    I recommend to build a package out of it so it does not conflict with your package manager
    and so may get overwritten or causes other issues.
    
    We use the official rsync sources here and the also official hosted rsync patches.
    
    Important note:
    the patched rsync must be installed on both the local and the target server
    
    
    Example to patch rsync v3.1.3
    ---------------------------------------------
    
    
    BUILD
    ----------------
    
    yum install rpmbuild make patch
    
    wget https://download.samba.org/pub/rsync/src/rsync-patches-3.1.3.tar.gz
    wget https://download.samba.org/pub/rsync/src/rsync-3.1.3.tar.gz

    tar xvzf rsync-3.1.3.tar.gz
    tar xvzf rsync-patches-3.1.3.tar.gz
    
    cd rsync-3.1.3/
    patch -p1 < patches/detect-renamed.diff
    
    ./configure
    make
    
    test that the rsync binary has the patch:
    
    ./rsync --help |grep detect
    

    PACKAGING (rpm)
    ------------------
    
    mv rsync-3.1.3 rsync-3.1.3-detectrenamed-patch01
    tar cvzf rsync-3.1.3-detectrenamed-patch01.tar.gz rsync-3.1.3-detectrenamed-patch01/
    cp rsync-3.1.3-detectrenamed-patch01.tar.gz ~/rpmbuild/SOURCES/
    cp rsync-3.1.3/packaging/lsb/rsync.spec ~/rpmbuild/SPECS/
    
    edit ~/rpmbuild/SPECS/rsync.spec:
    
        %define fullversion %{version}-detectrenamed-patch01
        Release: detectrenamed01
    
    cd ~/rpmbuild/SPECS/
    rpmbuild -ba rsync.spec
    
    rpm -qip ~/rpmbuild/RPMS/rsync-3.1.3-detectrenamed01.x86_64.rpm
    
    
    INSTALL (rpm)
    --------------------
    
    remove rsync (rpm -e rsync)
    install the created package (rpm -i rsync-3.1.3-detectrenamed01.x86_64.rpm)
    
    
    
    

HELPPATCHRSYNC
}

F_HELPALL(){
    F_HELPINSTALL
    F_HELPSPEED
    F_HELPSYNC
    F_HELPPATCHRSYNC
}
        
F_GETOPT(){
    [ $DEBUG -eq 1 ]&& echo "Reached F_GETOPT"
    while getopts G:p:s:m:i:yf:E:Dr:c:b:j:-: OPT; do
            [ $DEBUG -eq 1 ]&& echo "Checking $OPT"
            case "$OPT" in
            s)  SPEEDTARGET="$OPTARG" ;;
            p)  STORE="$OPTARG" ;;
            m)  TESTSIZE="$OPTARG" ;;
            i)  IOPRIO="$OPTARG" ;;
            f) 
            FULLSPEEDPRIO="$OPTARG"
            F_LOG "Fullspeed prio set on the commandline ($FULLSPEEDPRIO) - overwrites default"
            ;;
            E)
            ENDLESSRUN="$OPTARG"
            F_LOG "Set run mode to: $ENDLESSRUN"
            ;;
            D)  DEBUG=1 ;;
            G)  REMGUID="$OPTARG" ;;
            r)  SPEEDROUNDS="$OPTARG" ;;
            c)  SPEEDCIPHER="$OPTARG" ;;
            b)  BSSIZE="$OPTARG" ;;
            j)  JOBS="$OPTARG" ;;
            -) # hacking the bash to support long options
            [ $DEBUG -eq 1 ]&& echo "checking $OPTARG for long args..."
            LONG_OPTARG="${OPTARG#*=}"
            case $OPTARG in
               maileachjob=?*   )  MAILJOBBLOCK="$LONG_OPTARG" ; F_LOG "Setting MAILJOBBLOCK (new value: $LONG_OPTARG)";;
               maileachjob*     )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               mailsyncend=?*   )  MAILSYNCEND="$LONG_OPTARG" ; F_LOG "Setting MAILSYNCEND (new value: $LONG_OPTARG)";;
               mailsyncend*     )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               maillongrun=?*   )  LONGRUN="$LONG_OPTARG" ; F_LOG "Setting LONGRUN (new value: $LONG_OPTARG)";;
               maillongrun*     )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               mailonlylong=?*  )  MAILONLYLONG="$LONG_OPTARG" ; F_LOG "Setting MAILONLYLONG (new value: $LONG_OPTARG)";;
               mailonlylong*    )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               mailto=?*        )  MAILRECPT="$LONG_OPTARG" ; F_LOG "Setting MAILRECPT (new value: $LONG_OPTARG)";;
               mailto*          )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               calcsizes=?*     )  CALCSIZES="$LONG_OPTARG" ; F_LOG "Setting CALCSIZES (new value: $LONG_OPTARG)";;
               calcsizes*       )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               ixmap=?*         )  IXMAPARRAY="$LONG_OPTARG" ; F_LOG "ixmap option set (value(s): $LONG_OPTARG)";;
               ixmap*           )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               ixdirmap=?*      )  IXDIRMAPARRAY="$LONG_OPTARG" ; F_LOG "ixdirmap option set (value(s): $LONG_OPTARG)";;
               ixdirmap*        )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               heavydebug*      )  echo "DEBUG: DEBUG OVERLOAD MODE!!! THIS PRODUCES HEAVY OUTPUT VOLUME!!"; DEBUG=1; HEAVYDEBUG=1;;
               forcesync*       )  F_OLOG "WARNING: forcesync set! Will ignore currently running sync processes! This can result in unexpected behaviour and it would be a better idea to stop all other sync processes instead!"; FCS=1;;           
               help-speed       )  F_HELPSPEED ; exit 0 ;;
               help-all         )  F_HELPALL ; exit 0 ;;
               help-install     )  F_HELPINSTALL ; exit 0 ;;
               help-sync        )  F_HELPSYNC ; exit 0;;
               help-patch-rsync )  F_HELPPATCHRSYNC; exit 0;;
               dryrun           )  DEBUG=1 ;;
               renumber         )  BUCKNUM=1 ;; 
               remoteguid=?*    )  REMGUID="$LONG_OPTARG" ; F_LOG "Setting REMGUID (new value: $LONG_OPTARG)" ;;
               remoteguid*      )  echo "No arg for --$OPTARG option" >&2; exit 2 ;;
               '' )        break ;; # "--" terminates argument processing
               # NOT enabled here:  * )         echo "Illegal option --$OPTARG" >&2; exit 2 ;;
             esac
             ;;
            *)
            #skip the rest
            ;;
        esac
    done
    # syntax check(s)
    if [ ! -z "$REMGUID" ];then
        REMOTEGUID=$(echo "$REMGUID" | egrep -o "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}|REMOVE")
        [ -z "$REMOTEGUID" ] && F_LOG "ERROR: the given GUID $REMGUID seems to be not a valid GUID!" exit 3
    fi
}

# check required tools
F_CHKBASE(){
    for xbin in $REQUIREDTOOLS; do
        test -x $xbin
        [ $? -ne 0 ] && echo "ERROR!!! Required tool $xbin is missing or not executable! ABORTED!" && F_HELPINSTALL && F_EXIT 99
    done
    
}

F_EXIT(){
    exit $1
}

# check sync mode syntax
F_CHKSYNCTAX(){    
    # check general arg deps
    if [ -z "$IXMAPARRAY" ]&&[ -z "$IXDIRMAPARRAY" ];then
        F_OLOG "You have to specify one of --ixmap or --ixdirmap! ABORTED."
        echo "You have to specify one of --ixmap or --ixdirmap! Check $TOOLX --help. ABORTED."
        exit
    fi
    # check mail arg deps
    if [ "$MAILSYNC" == 1 ];then
        if [ "$MAILONLYLONG" -eq 1 ]||[ "$MAILJOBBLOCK" -eq 1 ]||[ "$MAILSYNCEND" -eq 1 ];then
            # check if mail rcpts are set
            if [ -z "$MAILRECPT" ];then
                F_OLOG "You have specified 1 or more mail options but not given any mail address. ABORTED."
                echo "You have specified 1 or more mail options but not given any mail address. Check $TOOLX --help. ABORTED."
                exit
            fi
        fi
    fi
}

# will check if sync lock file exists, recheck if that lock is still valid and give back the result
F_LOCK(){
    LOCKDIR="$1"
    LOCKFILE="$LOCKDIR/.rsyncactive"
    if [ -f "$LOCKFILE" ];then
        # check if lockfile still valid - this is a fallback to ensure that we re-sync crashed jobs again
        # if we wouldn't validate a stale lock file would result in a never re-synced dir!
        # TODO: This will NOT work for the new ixmap rsyncs!!!!
        ps -u splunk -o pid,args|grep -v grep | egrep -q "rsync.*$LOCKDIR"
        PSERR=$?
        if [ $FCS -eq 0 ];then
            if [ $PSERR -eq 0 ]||[ "$DEBUG" -eq 1 ];then
                # still valid / rsync in progress
                F_LOG "$LOCKDIR is currently rsynced by another process so we will skip that one (<$LOCKFILE> exists)."
                SKIPDIR=1
            else
                # lockfile not valid anymore!
                F_LOG "$LOCKDIR has a lock file set (<$LOCKFILE>) but no matching rsync process exists!! Will force resync!"
                SKIPDIR=0
            fi
        else
            F_LOG "$LOCKDIR forcesync option was set!! Will force resync regardless of current running processes!"
            SKIPDIR=0
        fi
            
    else
        F_LOG "Creating lock file <$LOCKFILE>"
        touch "$LOCKFILE"
        SKIPDIR=0
    fi
}

# mapping for local bucket VS. remote generated id
# param 1: add | delete | check | latest
# param 2: bucket type (db,colddb,..)
# param 3: index name
# param 4: original local bucketname
# param 5: generated remote bucketname
#
# return states:
#  "check" 
#       0 : found       => also outputs the MAPPED bucketname (i.e. not necessarily the original bucketname)
#       1 : not found
#     >=2 : error
# "add":
#       0 : added successfully
#     >=1 : error
# "delete":
#       0 : deleted successfully
#     >=1 : error
# "latest"
#       0 : found           => prints the latest MAPPED bucketname
#     >=1 : empty/error
F_LOCALFISHBUCKET(){
    F_LOG "$FUNCNAME started with $1, $2, $3, $4, $5"
    WHAT="$1"
    DBTYPE="$2"
    IXNAME="$3"
    MAPDB="${FDBPATH}/${IXNAME}.${DBTYPE}"
    OBUCKETNAME="$4"
    REMNAME="$5"

    for arg in ${WHAT}x ${MAPDB}x ${OBUCKETNAME}x ${IXNAME}x ${DBTYPE}x ;do
        [ "$arg" == "x" ] && F_LOG "$FUNCNAME: wrong or missing required ARG!" && return 9
    done
    
    [ ! -d "${FDBPATH}" ] && mkdir -p "${FDBPATH}"
    [ ! -f "$MAPDB" ] && touch $MAPDB
    
    case "$WHAT" in
        add)
        [ -z "${REMNAME}" ] && F_LOG "$FUNCNAME: missing required ARG: generated remote bucket name!" && return 9
        BUCKETNUM=$(F_GETBUCKNUM "$OBUCKETNAME")
        F_LOCALFISHBUCKET check "$DBTYPE" "$IXNAME" "$OBUCKETNAME" "${REMNAME}"
        if [ $? -eq 1 ];then
            echo "${BUCKETNUM},${OBUCKETNAME},${REMNAME}" >> $MAPDB
            F_LOG "$FUNCNAME: Added $OBUCKETNAME ($REMNAME) to the fishbucket db $MAPDB .."
        else
            F_LOG "$FUNCNAME: SKIPPED adding $OBUCKETNAME to the fishbucket db $MAPDB (already found).."
        fi
        ;;
        delete)
        # FIXME: UNFINISHED !!!!!
        ;;
        check)
        CSTATE=$(grep -q "${OBUCKETNAME}" $MAPDB 2>> $LOG)
        CHKERR=$?
        case $CHKERR in
            0) # identical bucketname found! return the latest(!) db entry
            STATE=$(grep "${OBUCKETNAME}" $MAPDB | sort -g | tail -n 1)
            LOCALBUCK=$(echo "$STATE" | cut -d "," -f 2)
            MAPBUCK=$(echo "$STATE" | cut -d "," -f 3)
            F_LOG "$FUNCNAME: found existing bucket combo: $LOCALBUCK + $MAPBUCK"
            echo "${MAPBUCK}"
            ;;
            1)
            F_LOG "$FUNCNAME: bucket ${OBUCKETNAME} not found, so go go go!"
            ;;
            *)
            F_LOG "$FUNCNAME: unknown return state ($CHKERR)"
            ;;
        esac
        return $CHKERR
        ;;
        latest)
            LASTENTRY=$(sort -g "$MAPDB" | tail -n 1)
            DBLATEST="${LASTENTRY/*,/}"
            echo "$DBLATEST"
        ;;
    esac
    
    F_LOG "$FUNCNAME ended"
}

# manage remote db locking to ensure exclusive access
# param 1: check | lock | unlock
# param 2: remote server
# param 3: remote bucket path
# "check" return states:
#       0 : locked      => also outputs the hostname of the owner!
#       1 : not locked
#     >=2 : error
# "lock" return states:
#       0 : locked successfully
#       8 : timed out while waiting on a locked db
#     >=1 : error
# "unlock" return states:
#       0 : unlocked successfully
#       8 : locked by someone else or an unknown issue occured while unlocking
#     >=1 : error on unlocking
F_REMOTESYNCDB(){
    F_LOG "$FUNCNAME started with $1, $2, $3"
    WHAT="$1"
    CSVR="$2"
    MAPPATH="$3"
    MAPDBLOCK="${MAPPATH}/.${TOOL}.db.lock"
    #MAPDBLOCK=${MAPDB}.lock
    SRC=$(hostname)
    CTIME=$(date +%s)
    
    for arg in ${WHAT}x ${CSVR}x ${MAPPATH}x ;do
        [ "$arg" == "x" ] && F_LOG "$FUNCNAME: missing required ARG!" && return 9
    done
    
    case "$WHAT" in
        check)
            STATE=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "test -f $MAPDBLOCK && cat $MAPDBLOCK")
            LOCKERR=$?
            case $LOCKERR in
                0)
                LOCKHOST=$(echo "$STATE" | cut -d "," -f 1)
                LOCKTIMEST=$(echo "$STATE" | cut -d "," -f 2)
                LOCKTIME=$(date --date=@${LOCKTIMEST})
                F_LOG "$FUNCNAME: $MAPDBLOCK state is: LOCKED by: $LOCKHOST at $LOCKTIME"
                echo $LOCKHOST
                ;;
                1)
                F_LOG "$FUNCNAME: $MAPDBLOCK state is: NOT LOCKED ($LOCKERR)"
                ;;
                *)
                F_LOG "$FUNCNAME: $MAPDBLOCK state is: unknown ($LOCKERR)"
                ;;
            esac
            return $LOCKERR
        ;;
        lock)
            LOCKSTATE=99
            R=0
            COUNTER=0
            while [ "$LOCKSTATE" -ne 1 ] && [ $COUNTER -lt 1000 ];do
                while [ $R -gt 30 ];do
                    R=$((${RANDOM} / 1000))
                done
                [ $LOCKSTATE -ne 99 ] && F_LOG "$FUNCNAME: remote db is locked, have to wait ($R s)..." && sleep $R
                unset RHOST
                RHOST=$(F_REMOTESYNCDB check "${CSVR}" "${MAPPATH}")
                LOCKSTATE=$?
                CHKERR=$LOCKSTATE
                [ "$RHOST" == "$SRC" ] && F_LOG "$FUNCNAME no need to unlock as I am the owner" && LOCKSTATE=1
                #&& F_REMOTESYNCDB unlock "${CSVR}" "${MAPPATH}" && LOCKSTATE=1
                COUNTER=$((COUNTER + 1))
                R=31
            done
            [ $COUNTER -gt 1000 ] \
                            && F_LOG "$FUNCNAME: FATAL: timed out locking remote fishbucket!" \
                            && return 8
            
            ssh -T -c $SCPCIPHER -o Compression=no -x "${CSVR}" "echo '$SRC,$CTIME' > $MAPDBLOCK" >> $LOG 2>&1
            LOCKERR=$?
            if [ "$LOCKERR" -eq 0 ];then
                F_LOG "$FUNCNAME: $MAPDBLOCK LOCKED successfully"
            else
                F_LOG "$FUNCNAME: trying to lock $MAPDBLOCK ended with $LOCKERR ! That's bad."
            fi
            return $LOCKERR
        ;;
        unlock)
            unset RHOST
            RHOST=$(F_REMOTESYNCDB check ${CSVR} ${MAPPATH})
            CHKERR=$?
            if [ $CHKERR -eq 0 ] && [ -z "$RHOST" ];then
                # DB has been locked by someone but it seems to be empty! so .. delete!
                F_LOG "$FUNCNAME: unlocking $MAPDBLOCK (because no one owns it)"
                ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "rm $MAPDBLOCK" >> $LOG 2>&1
            elif [ $CHKERR -eq 0 ] && [ "$RHOST" == "$SRC" ];then
                # DB has been locked by me, so YEA unlock it baby
                F_LOG "$FUNCNAME: unlocking $MAPDBLOCK (because its mine)"
                ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "rm $MAPDBLOCK" >> $LOG 2>&1
            elif [ $CHKERR -eq 0 ] && [ ! -z "$RHOST" ];then
                # DB locked and in use by another host
                F_LOG "$FUNCNAME: $MAPDBLOCK can't be unlocked because it is owned by $RHOST.."
                return 8
            else
                F_LOG "$FUNCNAME: unknown ERROR occured while checking the remote DB ($RHOST, $SRC, $CHKERR)"
                return 8
            fi
            LOCKERR=$?
            if [ "$LOCKERR" -eq 0 ];then
                F_LOG "$FUNCNAME: $MAPDBLOCK UNLOCKED successfully"
            else
                F_LOG "$FUNCNAME: trying to unlock $MAPDBLOCK ended with $LOCKERR ! That's bad."
            fi
            return $LOCKERR
        ;;
    esac
    F_LOG "$FUNCNAME ended"
}

# handle remote sync db containing bucket names
# param 1: add | delete | check
# param 2: remote server
# param 3: remote bucket path
# param 4: index name
# param 5: bucket name to be added, deleted or checked
#
# "check" return states:
#       0 : found OR initial run => also outputs the LATEST (i.e. not necessarily the original bucketname) or the original bucketname
#       1 : not found
#     >=2 : error
# "add" return states:
#       0 : added successfully
#     >=1 : error
# "delete" return states:
#       0 : deleted successfully
#     >=1 : error
F_REMOTEFISHBUCKET(){
    F_LOG "$FUNCNAME started with $1, $2, $3, $4, $5"
    WHAT="$1"
    CSVR="$2"
    MAPDB="${3}/.${TOOL}.db"
    IXNAME="$4"
    BUCKNAME="$5"
    
    for arg in ${WHAT}x ${CSVR}x ${MAPDB}x ${IXNAME}x ${BUCKNAME}x;do
        [ "$arg" == "x" ] && F_LOG "$FUNCNAME: missing required ARG!" && return 9
    done
    
    # create db if it does not exist
    ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "test -f $MAPDB || touch $MAPDB" >> $LOG 2>&1
    
    case "$WHAT" in
        add) # NEXTSTEP: ADD BUCKET NUMBER AS FIRST COLUMN AND SORT !
        BUCKETNUM=$(F_GETBUCKNUM "$BUCKNAME")
        ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "echo '${BUCKETNUM},${IXNAME},${BUCKNAME}' >> $MAPDB" >> $LOG 2>&1
        LASTERR=$?
        F_LOG "$FUNCNAME: adding $BUCKNAME to the fishbucket db $MAPDB ended with $LASTERR.."
        return $LASTERR
        ;;
        delete)
        # FIXME: UNFINISHED!!!!
        ;;
        check)
        BUCKETNUM=$(F_GETBUCKNUM "$BUCKNAME")
        STATE=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "grep '${BUCKETNUM},${IXNAME}' $MAPDB | tail -n 1")
        CHKERR=$?
        case $CHKERR in
            0) # identical bucketname found! return the latest(!) db entry
            DBIX=$(echo "$STATE" | cut -d "," -f 2)
            DBBUCKETNAME=$(echo "$STATE" | cut -d "," -f 3)
            LASTENTRY=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "sort -g $MAPDB | tail -n 1")
            DBLATEST="${LASTENTRY/*,/}"
            
            if [ -z "$DBBUCKETNAME" ];then
                F_LOG "$FUNCNAME: bucket combo not in remote db"
                DBLATEST="${BUCKNAME}"
                CHKERR=1
            else
                F_LOG "$FUNCNAME: found existing bucket combo: $DBIX + $DBBUCKETNAME"
            fi
            if [ ! -z "$DBLATEST" ];then
                F_LOG "$FUNCNAME: last entry is: $DBLATEST"
                echo "$DBLATEST"
            else
                F_LOG "$FUNCNAME: remote db seems to be empty (should happen on the very FIRST run only)!"
                echo "${BUCKNAME}"
            fi
            ;;
            1)
            #F_LOG "$FUNCNAME: bucket ${BUCKNAME} not found, so go go go!"
            F_LOG "$FUNCNAME: bucket DB empty, so go go go!"
            ;;
            *)
            F_LOG "$FUNCNAME: unknown return state ($CHKERR)"
            ;;
        esac
        return $CHKERR
        ;;
    esac
    
    F_LOG "$FUNCNAME ended"
}

# takes a bucket name as param and returns the detected bucket numbering
# param1: bucketname (without path)
#
# returns: integer number parsed from param1
#
# return codes:
#   0 => ok
#   3 => missing parameter
#   * => error
F_GETBUCKNUM(){
    F_LOG "$FUNCNAME started with $1"
    BUCK="$1"
    
    [ -z "$BUCK" ] && F_LOG "$FUNCNAME: FATAL no bucketname given" && return 3
    
    # check hot or not first
    echo "$BUCK" |grep -q "hot_v"
    HOTB=$?
    
    if [ $HOTB -eq 0 ];then
        # hint: splunk starts numbering with 0
        BUCKETNUM=$(echo "$BUCK" |grep hot_v | cut -d "_" -f 3 | egrep '^[0-9]{1}[0-9]{0,100}$')
    else
        # hint: splunk starts numbering with 0
        BUCKETNUM=$(echo "$BUCK" | cut -d "_" -f 4 | egrep '^[0-9]{1}[0-9]{0,40}$')
    fi
    F_LOG "$FUNCNAME: identified bucket number as: $BUCKETNUM"
    F_LOG "$FUNCNAME ended"
    echo "$BUCKETNUM"
}

# parses a bucket name to identify its type (hot, db ...)
#   param1: bucketname
#
# return codes:
#       0 : parsed successfully, also outputs the type (HOT,DB)
#     =<1 : error occured
F_BUCKETTYPE(){
    F_LOG "$FUNCNAME started with $1"
    B=$1
    
    [ -z "$B" ] && F_LOG "$FUNCNAME: FATAL: missing arg!" && return 8
    
    # hot bucket check
    echo "$B" |grep -q "hot_v" && F_LOG "$FUNCNAME: hot bucket detected" && echo HOT && return
    
    # regular bucket (cold, warm ..)
    echo "$B" |grep -q "db_" && F_LOG "$FUNCNAME: regular bucket detected" && echo DB && return
    
    # .. other checks (future use)
    
    F_LOG "$FUNCNAME: FATAL: ended without determining a bucket type!"
    return 8
}

########################################################################
# generate a bucket name with dynamic bucket numbering
#   param 1: remote server
#   param 2: remote bucket path
#   param 3: db type (db, colddb, ..)
#   param 4: index name
#   param 5: original bucketname
#
# Example:
#   F_GENBUCKNUM server bucketpath buckettype index originalbucket
#
# Ideal progress:
#   1) F_REMOTESYNCDB check server bucketpath
#   2) F_REMOTESYNCDB lock server bucketpath
#   3) F_REMOTEFISHBUCKET check server bucketpath index originalbucket
#   4) RESULT_3 + 1 (so becomes a generatedname)
#   5) F_REMOTEFISHBUCKET add server bucketpath index generatedname
#   6) F_REMOTESYNCDB unlock server bucketpath
#   7) return generatedname
#
#   note: F_LOCALFISHBUCKET add will be done only when F_RSYNC completes so has been
#         removed from here
#
# return states:
#       0: a bucketname could be generated (or the origin can be used)
#       1: the bucket has been processed already (i.e. exists in local AND remote fishbucket)
#       4: bucket number cannot be extracted from the given name
#       8: fatal error in locking remote fishbucket db (for writing new bucket name)
#       9: fatal error in generating a bucketname (i.e. the local one exists remotely and we were not able to create a new numbering)
F_GENBUCKNUM(){
    REMSRV="$1"
    BUCKPATH="$2"
    DBTYPE="$3"
    IXNAME="$4"
    OBUCKETNAME="$5"
    LHOST=$(hostname)
    unset NEWHOTB
    
    # parsing bucket type
    BT=$(F_BUCKETTYPE "$OBUCKETNAME")
    if [ $? -ne 0 ] || [ -z "$BT" ]; then
        F_LOG "$FUNCNAME: FATAL: aborted due to an error in F_BUCKETTYPE" && return 8
    fi
    
    # parsing the bucket number
    CBUCKETNUM=$(F_GETBUCKNUM "$OBUCKETNAME")
    
    # do the magic
    if [ -z "$CBUCKETNUM" ];then
        F_LOG "$FUNCNAME: FATAL: cannot determine bucket number!"
        return 4
    else
        # check first if we need to generate a bucket name or using one from the DB!
        MAPBUCKET=$(F_LOCALFISHBUCKET "check" "$DBTYPE" "$IXNAME" "$OBUCKETNAME")
        LASTERR=$?
        if [ "$LASTERR" -eq 0 ];then
            GUIDBUCKET="$MAPBUCKET"
            F_LOG "$FUNCNAME: local bucket mapping found ..."
            ## check for corrupted remote DB (i.e missing entry) 
            #NEWDB=$(F_REMOTEFISHBUCKET check "${REMSRV}" "${BUCKPATH}" "$IXNAME" "$BUCKETNAME")
            #if [ $? -eq 1 ];then
            #    # fix corrupted remote DB
            #    #F_REMOTESYNCDB lock ${REMSRV} ${BUCKPATH}
            #    #F_REMOTEFISHBUCKET add "${REMSRV}" "${BUCKPATH}" "$IXNAME" "$BUCKETNAME"
            #    LASTERR=$?
            #    if [ $LASTERR -ne 0 ];then
            #        F_LOG "$FUNCNAME: FATAL: ERROR while RE-adding bucket $GUIDBUCKET to REMOTE fishbucket"
            #    fi
            #elif [ "$BT" == "HOT" ];then
            #    F_LOG "$FUNCNAME: force syncing $GUIDBUCKET as it is a HOT bucket."
            #else
            #    F_LOG "$FUNCNAME: SKIPPING processing $GUIDBUCKET as it was synced previously and is NOT a HOT bucket."
            #    return 1
            #fi
        else
            F_LOG "$FUNCNAME: no local bucket mapping found."
            # GUID check/replacement
            if [ "$REMOTEGUID" != "REMOVE" ] ;then
                F_LOG "$FUNCNAME: will replace GUID $LOCALGUID with $REMOTEGUID ..."
                GUIDBUCKET="${OBUCKETNAME/${LOCALGUID}/$REMOTEGUID}"
            elif  [ "$REMOTEGUID" == "REMOVE" ] ;then
                F_LOG "$FUNCNAME: will remove GUID $LOCALGUID from buckets"
                GUIDBUCKET="${OBUCKETNAME/_${LOCALGUID}/}"
            else
                F_LOG "$FUNCNAME: will not touch GUID $LOCALGUID from bucketname"
                GUIDBUCKET="${OBUCKETNAME}"
            fi
        fi
        # 2) F_REMOTESYNCDB lock server bucketpath
        F_REMOTESYNCDB lock "${REMSRV}" "${BUCKPATH}"
        LOCKERR=$?
        READD=0
        if [ $LOCKERR -eq 0 ];then
            # 3) F_REMOTEFISHBUCKET check server bucketpath index originalbucket
            NEWDB=$(F_REMOTEFISHBUCKET check ${REMSRV} "${BUCKPATH}" "$IXNAME" "$GUIDBUCKET")
            LASTERR=$?
            # when LASTERR 0: found, 1 or NEWDB empty: not found
            if [ -z "$NEWDB" ];then
                # bucket name does not exist remotely so we can use the original one
                BUCKETNAME="$GUIDBUCKET"
                LASTERR=0
                READD=1
            elif [ "$BT" == "HOT" ];then
                [ $LASTERR -eq 1 ] && READD=1
                BUCKETNAME="$GUIDBUCKET"
                F_LOG "$FUNCNAME: will sync existing remote path because of existing HOT bucket"
                READD=0
                LASTERR=0
            elif [ $LASTERR -eq 0 ];then
                F_LOG "$FUNCNAME: SKIPPING processing $GUIDBUCKET as it was synced previously and is NOT a HOT bucket."
                F_REMOTESYNCDB unlock "${REMSRV}" "${BUCKPATH}"
                return 1
            else
                # 4) RESULT_3 + 1 (so becomes a generatedname)
                NEWNUM=99
                COUNTER=0
                BUCKETNAME="$GUIDBUCKET"
                while [ "$NEWNUM" -ne 1 ] && [ $COUNTER -lt 1000 ];do
                    if [ "$NEWNUM" -ne 99 ];then
                        F_LOG "$FUNCNAME: trying to generate a new bucket number.."
                        NBUCKETNUM=$(F_GETBUCKNUM "$NEWDB")
                        GENNUM=$(($NBUCKETNUM + 1))
                        BUCKETNAME=$(echo "$GUIDBUCKET" | sed "s/_${CBUCKETNUM}/_${GENNUM}/g")
                    fi
                    NEWDB=$(F_REMOTEFISHBUCKET check ${REMSRV} "${BUCKPATH}" "$IXNAME" "$BUCKETNAME")
                    NEWNUM=$?
                    [ "$DEBUG" -eq 1 ] && F_LOG "$FUNCNAME checking ended with errcode: $NEWNUM"
                    COUNTER=$((COUNTER + 1))
                done
                LASTERR=$?
                [ $COUNTER -gt 1000 ] \
                    && F_LOG "$FUNCNAME: FATAL: giving up to find a new bucket number!!! Last generated result was: $BUCKETNAME" \
                    && F_REMOTESYNCDB unlock "${REMSRV}" "${BUCKPATH}" \
                    && return 9
            fi
            if [ $LASTERR -eq 0 ]&&[ "$BT" != "HOT" ];then
                F_LOG "$FUNCNAME: we will use bucket name: $BUCKETNAME"
                # 6) F_REMOTEFISHBUCKET add server bucketpath index generatedname
                F_REMOTEFISHBUCKET add "${REMSRV}" "${BUCKPATH}" "$IXNAME" "$BUCKETNAME"
                LASTERR=$?
            elif [ $READD -eq 1 ]&&[ "$BT" == "HOT" ];then
                F_LOG "$FUNCNAME: re-adding missing hot bucket $BUCKETNAME to remote db"
                F_REMOTEFISHBUCKET add "${REMSRV}" "${BUCKPATH}" "$IXNAME" "$BUCKETNAME"
                LASTERR=$?
            fi
            if [ $LASTERR -ne 0 ];then
                F_LOG "$FUNCNAME: ERROR while adding bucket $BUCKETNAME to REMOTE fishbucket"
            fi
            # 7) F_REMOTESYNCDB unlock server bucketpath
            F_REMOTESYNCDB unlock "${REMSRV}" "${BUCKPATH}"
            LASTERR=$?
        else
            F_LOG "$FUNCNAME: FATAL: cannot lock remote DB"
        fi

        [ -z "$BUCKETNAME" ] && F_LOG "$FUNCNAME: FATAL: new BUCKETNAME is empty!" && return 5
        [ $LASTERR -eq 0 ] && echo "$BUCKETNAME"
    fi
}

# check for running splunkd by pid/lock file on the remote server
# param 1 (required): remote server
F_CHKSPLSTATE(){
    F_LOG "$FUNCNAME started with $@"
    CSVR="$1"
    #ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "test -f $REMLCKSPL" >> $LOG 2>&1
    ssh -T -c $SCPCIPHER -o Compression=no -x ${CSVR} "$REMSPLDIR/bin/splunk status" >> $LOG 2>&1
    STATE=$?
    [ "$DEBUG" -eq 1 ] && F_LOG "$FUNCNAME ended with $STATE"
    return $STATE
}

# will pause until F_CHKSPLSTATE returns success
# param 1 (required): remote server
# param 2 (required): waiting period between checks
F_WAITFORSPLUNK(){
    F_LOG "$FUNCNAME started with $1, $2"
    STATE=9
    ISTATE=0
    TSRV=$1
    WAITT=$2
    [ -z "$TSRV" ] && F_LOG "$FUNCNAME: ERROR: no remote server specified" && return 8
    [ -z "$WAITT" ] && F_LOG "$FUNCNAME: ERROR: no wait time specified" && return 9
    
    while [ "$STATE" -ne 0 ]||[ "$ISTATE" -ne 2 ];do
        F_CHKSPLSTATE "$TSRV"
        STATE=$?
        if [ $STATE -ne 0 ];then
            F_LOG "$FUNCNAME: delaying next check for $WAITT...." && sleep "$WAITT"
            # ensure waitinitdelay will run
            ISTATE=3
        else
            case $ISTATE in
                0|1) break;;
                3)
                F_LOG "$FUNCNAME: splunk status reports ok, assuming splunk is running. Waiting $WAITINITDELAY to give splunk enough time to settle up.."
                sleep $WAITINITDELAY
                ISTATE=1
                F_LOG "$FUNCNAME: re-checking splunk status after init delay to be sure splunkd started properly"
                ;;
            esac
        fi
    done
    F_LOG "$FUNCNAME: All good, assuming splunk is really running."
    F_LOG "$FUNCNAME ended"
    
    return 0
}

# sync syntax
F_RSYNC(){
    [ -z "$1" ]&& F_LOG "$FUNCNAME: missing SRCDIR arg ! aborted!" && exit
    SRCDIR="$1"
    [ -z "$2" ]&& F_LOG "$FUNCNAME: missing TARGET arg ! aborted!" && exit
    TARGET="$2"
    [ -z "$3" ]&& F_LOG "$FUNCNAME: missing DBTYPE arg ! aborted!" && exit
    DBTYPE="$3"
    
    # first trim the path and then get the index name
    TRIMTYPE=$(echo $SRCDIR | sed "s#/$DBTYPE\$##g")
    RSYNCINDEX=${TRIMTYPE##*/}
    
    echo "************************************************************************************************">> $LOG
    echo "$RSYNCINDEX" |egrep -q "$DEFDISABLEDIX"
    if [ $? -eq 0 ];then
        F_LOG "$FUNCNAME: Skipping <$SRCDIR> sync as it is an internal index!" 
    else
        F_LOG "$FUNCNAME: Starting <$SRCDIR> sync"
        unset SKIPDIR
        F_LOCK "$SRCDIR"
        if [ "$SKIPDIR" -eq 0 ];then
            F_GENTIME
            RSTARTTIME="$GENTIME"
            if [ "$CALCSIZES" -eq 1 ];then
                IXSIZEKB=$(du -0xsk $SRCDIR| tr "\t" ";" |cut -d";" -f1)
                if [ -z "$IXSIZEKB" ];then
                    F_LOG "$FUNCNAME: WARNING: Cannot determine size (local), $IXSIZEKB"
                    IXSIZEKB=error-getting-size
                else
                    F_CALC "scale=0;$IXSIZEKB/1024"
                    IXSIZEMB="$CALCRESULT"
                    unset CALCRESULT
                    F_CALC "scale=2;$IXSIZEMB/1024"
                    IXSIZEGB="$CALCRESULT"
                fi
            else
                IXSIZEKB=CALCSIZES-not-wanted
            fi
          
            # FIXME: special handling for wrong configured indices:
            unset SPECIALEXCLUDES
            echo "$RSYNCINDEX" |egrep -q "'$IXNODBSYNC'"
            if [ $? -eq 0 ];then
                PROBLEMINDEX=1
                F_LOG "$FUNCNAME: Adjustment needed for: $RSYNCINDEX"
                RSYNCINDEX="$RSYNCINDEX/$DBTYPE"
                F_LOG "$FUNCNAME: index name adjusted to: $RSYNCINDEX"
                SRCDIR="$SRCDIR/"
                F_LOG "$FUNCNAME: src dir name adjusted to: $SRCDIR"
                SPECIALEXCLUDES="--exclude 'db/' --exclude 'colddb/' --exclude 'thaweddb/' --exclude 'summary/'"
            else
                PROBLEMINDEX=0
            fi
        
            F_LOG "$FUNCNAME: Index: ${RSYNCINDEX}"
            F_LOG "$FUNCNAME: Destination server: ${TARGET}" 
            F_LOG "$FUNCNAME: Destination dir: $TARGETBASEDIR/${RSYNCINDEX} (FOLDER sync! Means the source folder will be created in $TARGETBASEDIR/${RSYNCINDEX}/)" 
            F_LOG "$FUNCNAME: IO Priority: ${IOPRIO}"
            F_LOG "$FUNCNAME: Local index size: $IXSIZEKB KB"
            # adjust io prio if needed
            F_DATEIOCHECK
            # let's continuesly monitor the io prio and adjust if needed
            F_STARTHELPER &
            SHPID=$!
            F_LOG "$FUNCNAME: Initiated helper start in background (pid: $SHPID)"
            # start optimized sync with time tracking using bash builtin time!
            TIMEFORMAT="runtime_real=%E;runtime_kernelsec=%S;runtime_usersec=%U;cpuusage_perc=%P"
            unset RUNTIME
            # sigh I saw problems when you try to sync to a non existing dir. At least the main dir has to exists otherwise rsync silently fails!
            #ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} mkdir -p $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null
            
            # check remote index size
            if [ "$CALCSIZES" -eq 1 ];then
                if [ $PROBLEMINDEX -eq 0 ];then
                    REMIXSIZEKB=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                else
                    REMIXSIZEKB=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                fi
                if [ -z "$REMIXSIZEKB" ];then
                    F_LOG "$FUNCNAME: WARNING: Cannot determine size (remote), $REMIXSIZEKB"
                    REMIXSIZEKB=error-getting-size
                else
                    F_CALC "scale=0;$REMIXSIZEKB/1024"
                    REMIXSIZEMB="$CALCRESULT"
                    unset CALCRESULT
                    F_CALC "scale=2;$REMIXSIZEMB/1024"
                    REMIXSIZEGB="$CALCRESULT"
                fi
            else
                REMIXSIZEKB=CALCSIZES-not-wanted
            fi
            
            # ionice:
                # c: io class
                # n: priority within the io class
            # rsync args (not all are in use though):
                # a: archive mode
                # v: verbose output
                # m: do not create empty directories
                # inplace: BETTER: partial-dir instead!
                #          write the updated data directly to the destination file and instead of
                #          creating a new copy of the file and moving it into place when it is complete
                # dirs: Tell the sending side to include any directories that are encountered. sync dirs must end with a trailing slash!
                # partial-dir: keep the partial file (resuming) in a specific dir, conflicts with "inplace"
                # whole-file: whole file is sent as-is (rsync's delta-transfer algorithm is not used).
                #             ensures a notify or splunk restart will not read-in half transferred data!
                # delete: removes files on the target side if they are missing locally (DANGEROUS!!!!)
                # numeric-ids: don't map uid/gid values by user/group name
                # W: copy whole file instead of calculating missing deltas
                # delay-updates: put all updated files into place at end
                # e: execute a cmd (in this case ssh)
            RSYNCARGS="-avm --numeric-ids --dirs --partial-dir=.${TOOL}"
            # ssh:
                # T: turn off pseudo-tty to decrease cpu load on destination.
                # c arcfour: use the weakest but fastest SSH encryption. Might need to be specified as "Ciphers ......" in sshd_config on destination.
                # o Compression=no: Turn off SSH compression.
                # x: turn off X forwarding if it is on by default.
            if [ "$DEBUG" -eq 1 ];then
                # for debugging time calc we will have the very first entry sleeping longer to get valid data
                if [ $DEBUGTIMER -eq 0 ];then
                    RUNTIME=$((echo "$FUNCNAME: DEBUG MODE NO rsync $SRCDIR happens here --> CUSTOM WAIT HERE ($SLEEPTIME) !!! ADJUST IF NEEDED" >> $LOG && time ionice -c2 -n7 sleep ${SLEEPTIME} ) 2>&1 | tr "." ".")
                else
                    # DRY RUN! No changes!
                    echo "$FUNCNAME: DEBUG MODE NO rsync $SRCDIR happens here. Without -d option we would sync: $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}" >> $LOG
                    RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync --dry-run $RSYNCARGS $SPECIALEXCLUDES $RBBUCKETS -e 'ssh -T -c $SCPCIPHER -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}  2>&1 >> $LOG) 2>&1 | tr "." "." )
                fi
                DEBUGTIMER=$((DEBUGTIMER + 1))
            else
                # REAL RUN! CHANGES TARGET!
                F_LOG "$FUNCNAME: Starting rsync from $SRCDIR to ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}:"
                ###RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync -av --numeric-ids --delete $SPECIALEXCLUDES -e 'ssh -T -c $SCPCIPHER -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}  2>&1 >> $LOG) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                ###RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync -av --numeric-ids --delete $SPECIALEXCLUDES --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX} >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                #RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync --inplace -avm --numeric-ids --delete $SPECIALEXCLUDES --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                
                TYPESRCDIR=$SRCDIR/$DBTYPE
                TYPETARGETDIR=${TARGETBASEDIR}/${RSYNCINDEX}/${DBTYPE}
                SYNCERR=0

                LOCALGUID=$(grep guid $SPLDIR/etc/instance.cfg | egrep -o "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}|REMOVE")
                [ -z "$LOCALGUID" ] && F_LOG "ERROR: cannot determine a local GUID!!" && F_EXIT 99
                ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} mkdir -p $TYPETARGETDIR >> $LOG 2>&1
                F_LOG "creating $TYPETARGETDIR ended with $?"
                F_LOG "ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} mkdir -p $TYPETARGETDIR"
                
                # extend the find arguments to scan for hot buckets when enabled
                [ $HOTSYNC -eq 1 ] && FINDARGS='-or -name hot_*'
                
                FISHBUCKET="${FDBPATH}/${RSYNCINDEX}.${DBTYPE}"
                [ ! -f "$FISHBUCKET" ] && touch "$FISHBUCKET"
                
                if [ ! -z "$REMOTEGUID" ]||[ "$BUCKNUM" -eq 1 ];then
                    F_LOG "$FUNCNAME: preparing sync process (bucket renumbering and/or GUID replacement choosen)"
                    #
                    # SYNC LOOP
                    #
                    # https://docs.splunk.com/Documentation/Splunk/latest/Indexer/HowSplunkstoresindexes#Bucket_names
                    BUCKETLIST=$(find $TYPESRCDIR -maxdepth 1 -mindepth 1 -type d -name 'db_*' $FINDARGS | grep -vf <(printf "$(cat $FISHBUCKET)" ) | wc -l 2>&1)
                    if [ $BUCKETLIST -eq 0 ];then
                        F_LOG "$FUNCNAME: FATAL: woah.. well.. the list of buckets is 0! So you want me to sync.. nothing? .. no way, SKIPPED!"
                        FORERR=99
                    else
                        F_LOG "$FUNCNAME: preparing syncing $BUCKETLIST buckets..."
                        for bucket in $(find $TYPESRCDIR -maxdepth 1 -mindepth 1 -type d -name 'db_*' $FINDARGS | grep -vf <(printf "$(cat $FISHBUCKET)" ));do
                            F_WAITFORSPLUNK "${TARGET}" "10s"
                            # parse the original bucket name
                            OBUCKETNAME=${bucket##*/}
    
                            F_LOG "#-------------- start: $OBUCKETNAME --#"
                            F_LOG "$FUNCNAME: .... processing bucket: $bucket"
                            
                            # skip hot bucket processing when not enabled (double proof as usually we should NEVER see a hot bucket at this stage when not enabled)
                            BT=$(F_BUCKETTYPE "$OBUCKETNAME")
                            if [ $? -ne 0 ] || [ -z "$BT" ]; then
                                F_LOG "$FUNCNAME: FATAL: aborted due to an error in F_BUCKETTYPE" && continue
                            fi
                            [ $HOTSYNC -ne 1 ] && [ "$BT" == "HOT" ] && F_LOG "$FUNCNAME: skipping $OBUCKETNAME as you do not want to sync hotbuckets" && continue
        
                            if [ -z "$BUCKNUM" ];then
                                BUCKETNAME="$OBUCKETNAME"
                                GENERR=0
                            else
                                BUCKETNAME=$(F_GENBUCKNUM "${TARGET}" "${TYPETARGETDIR}" "${DBTYPE}" "$RSYNCINDEX" "$OBUCKETNAME")
                                GENERR=$?
                            fi
                            if [ $GENERR -eq 1 ];then
                                F_LOG "$FUNCNAME: skipped $OBUCKETNAME as it has been synced already"
                            elif [ -z "$BUCKETNAME" ];then
                                F_LOG "$FUNCNAME: FATAL: cannot determine bucket name after processing! SKIPPED: $OBUCKETNAME!"
                            elif [ $GENERR -eq 0 ];then
                                TARGETMODDIR="${TYPETARGETDIR}/${BUCKETNAME}"
                                F_LOG "$FUNCNAME: remote bucket will be saved in: $TARGETMODDIR"
                                if [ "$EXCLON" != "true" ];then
                                    F_LOG "$FUNCNAME:\n$RSYNC --inplace -avm --numeric-ids $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR"
                                    RUNTIME=$((time ionice -c2 -n${IOPRIO} $RSYNC $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' ${bucket}/ ${TARGET}:${TARGETMODDIR}/ >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                                else
                                    F_LOG "$FUNCNAME:\n$RSYNC -avm --numeric-ids --exclude-from=$SYNCEXCLUDES $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR"
                                    RUNTIME=$((time ionice -c2 -n${IOPRIO} $RSYNC $RSYNCARGS --exclude-from=$SYNCEXCLUDES --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' ${bucket}/ ${TARGET}:${TARGETMODDIR}/ >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                                fi
                                LASTERR=$?
                                if [ $LASTERR -eq 255 ];then
                                    F_LOG "$FUNCNAME: ERROR: Syncing $bucket ended with errorcode <$LASTERR> !!" 
                                    F_LOG "$FUNCNAME: Please check if the choosen cipher: $SCPCIPHER is supported on $TARGET and review the above rsync messages carefully!"
                                    SYNCERR=$(($LASTERR + $LASTERR))
                                else
                                    [ "$DEBUG" -eq 1 ] && F_LOG "$FUNCNAME: ... syncing $bucket to $TARGETMODDIR ended successfully!"
                                    SYNCERR=0
                                    # 5) F_LOCALFISHBUCKET add buckettype index originalbucket generatedname
                                    F_LOCALFISHBUCKET add "$DBTYPE" "$RSYNCINDEX" "$OBUCKETNAME" "$BUCKETNAME"
                                    LASTERR=$?
                                    NOTIFYREMSPLUNK=1
                                fi
                            else
                                F_LOG "$FUNCNAME: FATAL: error $GENERR occured while generating bucketname"
                            fi
                            F_LOG "#-------------- end: $OBUCKETNAME --#"
                        done
                        FORERR=$?
                    fi
                else
                    GENERR=0
                    SYNCERR=0
                #    for bucket in $(find $TYPESRCDIR -maxdepth 1 -mindepth 1 -type d);do
                #        [ "$DEBUG" -eq 1 ] && F_LOG "... processing bucket: $bucket"
                #        RUNTIME=$((time ionice -c2 -n${IOPRIO} $RSYNC -avm --numeric-ids --exclude-from=$SYNCEXCLUDES $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' ${bucket}/ ${TARGET}:${TARGETBASEDIR} >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                #        LASTERR=$?
                #        if [ $LASTERR -eq 255 ];then
                #            F_LOG "ERROR: Syncing $bucket ended with errorcode <$LASTERR> !!" 
                #            F_LOG "Please check if the choosen cipher: $SCPCIPHER is supported on $TARGET and review the above rsync messages carefully!"
                #            SYNCERR=$(($LASTERR + $LASTERR)
                #        else
                #            [ "$DEBUG" -eq 1 ] && F_LOG "... syncing $SRCDIR ended successfully!"
                #            SYNCERR=0
                #            F_ADDFISHBUCKET "$TARGETMODDIR"
                #        fi
                #    done
                fi
                
                #if [ "$EXCLON" != "true" ];then
                #    F_LOG "$RSYNC --inplace -avm --numeric-ids $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR"
                #    RUNTIME=$((time ionice -c2 -n${IOPRIO} $RSYNC --inplace -avm --numeric-ids $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                #else
                #    F_LOG "$RSYNC -avm --numeric-ids --exclude-from=$SYNCEXCLUDES $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR"
                #    RUNTIME=$((time ionice -c2 -n${IOPRIO} $RSYNC -avm --numeric-ids --exclude-from=$SYNCEXCLUDES $RSYNCARGS --rsh='ssh -T -c '$SCPCIPHER' -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR >> $LOG 2>&1) 2>&1 | tr "." "." ; exit ${PIPESTATUS[0]})
                #fi
                #F_POSTSYNC
            fi
            if [ "$FORERR" -ne 0 ];then
                F_LOG "$FUNCNAME: error occured during sync."
            else
                if [ $GENERR -eq 0 ];then
                    if [ $SYNCERR -eq 255 ];then
                        F_LOG "ERROR: Syncing $SRCDIR ended with errorcode <$LASTERR> !!" 
                        F_LOG "Please check if the choosen cipher: $SCPCIPHER is supported on $TARGET and review the above rsync messages carefully!" 
                        F_LOG "To check for $SCPCIPHER execute this on $TARGET:\n#> ssh -Q cipher localhost"
                        F_LOG "If $SCPCIPHER cipher is not listed copy all ciphers listed and add those together with the $SCPCIPHER cipher to your sshd_config"
                        F_LOG "If you see no errors above try executing this manually:\n#> rsync -av --numeric-ids --delete $SPECIALEXCLUDES -e 'ssh -T $SCPCIPHER -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}"
                    else
                        F_LOG "OK: Syncing $SRCDIR ended successfully!" 
                    fi
                    F_LOG "Syncing <$SRCDIR> to ${TARGET}:$TARGETBASEDIR finished"
                    
                    # check remote index size again
                    if [ "$CALCSIZES" -eq 1 ];then
                        if [ $PROBLEMINDEX -eq 0 ];then
                            AREMIXSIZEKB=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                        else
                            AREMIXSIZEKB=$(ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                        fi
                        if [ -z "$AREMIXSIZEKB" ];then
                            F_LOG "WARNING: Cannot determine size (remote, prob-ix), $AREMIXSIZEKB"
                            AREMIXSIZEKB=error-getting-size
                        else
                            F_CALC "scale=0;$AREMIXSIZEKB/1024"
                            AREMIXSIZEMB="$CALCRESULT"
                            unset CALCRESULT
                            F_CALC "scale=2;$AREMIXSIZEMB/1024"
                            AREMIXSIZEGB="$CALCRESULT"
                        fi
                    else
                        AREMIXSIZEKB=CALCSIZES-not-wanted
                    fi
                fi
            fi
            [ ! -z $SHPID ] && kill $SHPID >> $LOG 2>&1 && F_LOG "Stopped starthelper" && unset HELPERRUNNING
            # write an easy parsable log entry with all relevant details
            F_GENTIME
            RENDTIME="$GENTIME"
            echo -e "PARSELINE;WORKER=$TOOLX;DEBUG=$DEBUG;IX=${RSYNCINDEX};DBTYPE=${DBTYPE};IXPATH=${SRCDIR};IXSIZEKB=${IXSIZEKB};IXSIZEMB=${IXSIZEMB};IXSIZEGB=${IXSIZEGB};REMIXSIZEKB=${REMIXSIZEKB};REMIXSIZEMB=${REMIXSIZEMB};REMIXSIZEGB=${REMIXSIZEGB};AREMIXSIZEKB=${AREMIXSIZEKB};AREMIXSIZEMB=${AREMIXSIZEMB};AREMIXSIZEGB=${AREMIXSIZEGB};TARGET=${TARGET}:${TARGETBASEDIR}/${RSYNCINDEX};BEFOREIOPRIO=${BEFOREIOPRIO};AFTERIOPRIO=${IOPRIO};${RUNTIME/*runtime_real/runtime_real};RSTARTTIME=$RSTARTTIME;RENDTIME=$RENDTIME\n" >> ${LOG}.parse
            rm -vf $LOCKFILE
            F_LOG "Deleted lock file <$LOCKFILE>."
        else
            F_LOG "Skipping <$SRCDIR> sync because it is in use by another rsync process."
            F_OLOG "Skipping <$SRCDIR> sync because it is in use by another rsync process."
        fi
    fi
    echo "************************************************************************************************">> $LOG
    return $NOTIFYREMSPLUNK
}

# set rsync job specific log dynamically
F_SETLOG(){
    unset ROTATEIT LOG
    LOG=$3
    ROTATEIT=$4
    
    if [ "$LOG" == "$OLOG" ]||[ ! -z "$ROTATEIT" ];then
        # skip rotate when the main log detected
        F_OLOG "Rotate skipped for $LOG because it is either main log or an ixmaparray run"
    else
        RSLOG="$RSLOG $LOG"
        [ $DEBUG -eq 1 ]&& echo "Rotating log from within setlog"
        F_ROTATELOG "$LOG"
    fi
    LOG="${TOOL}_${1}_${2}.log"
    F_OLOG "Currently writing rsync process to: $LOG"
    F_OLOG "You can STOP all processes at everytime by executing:\n\t\t\t\t\t\t pkill -g \$(cat ${TOOL}.pid)"
}

# simple calc which do not round like bash do
# example arg: "scale=2;35489356/60/60"
# --> would calculate and round to two digits (scale=2)
F_CALC() {
    CALCRESULT=$(echo "$@" | bc -l )
}

# calculate run time of each synced index
F_GENMAILLOG(){
    # define and clean up any existing previous mail logs
    TLOG="$1"
    ALLLOG="${TOOL}_MAIL_${TLOG}"
    LONGRUNLOG="${TOOL}_MAIL_LONGRUN_${TLOG}"
    [ -f $ALLLOG ] && rm -f $ALLLOG
    [ -f $LONGRUNLOG ] && rm -f $LONGRUNLOG
    
    # prepare temp mail log
    grep "PARSELINE" ${TLOG}.parse |cut -d ";" -f 2-100 | tr ";" " " > summaryinfo_${TLOG}
    
    # write some prefix hint so its clear what is this log about
    if [ "$MAILONLYLONG" -eq 1 ];then
        echo -e "********************************************************************************" >> $LONGRUNLOG
        echo -e "HINT: You see here FILTERED results!\nOnly sync jobs running longer then = $LONGRUN hours are shown\n" >> $LONGRUNLOG
        echo -e "Check\n$ALLLOG\nfor the full details." >> $LONGRUNLOG
        echo -e "********************************************************************************" >> $LONGRUNLOG
    fi
        
    # parse temp mail log and re-format
    while read line ;do
        # omg what a hack
        for i in $(echo "$line");do
            eval ${i/=*/}="${i/*=/}"
        done
        F_CALC "scale=2;$runtime_real/60/60"
        #MOUT="Index: $IX (type: $DBTYPE) ran for $CALCRESULT hours.\nStatistics: Hours = $CALCRESULT, Started = $RSTARTTIME, Ended = $RENDTIME, CPU usage = $cpuusage_perc, IO prio = $IOPRIO, Destination = $TARGET, time cmd output = $runtime_real, $runtime_kernelsec, $runtime_usersec"
       
        if [ "$CALCSIZES" -eq 1 ];then
            # if difference bigger then value X display in log:
            if [ "$IXSIZEKB" == "error-getting-size" ];then
                F_LOG "Cannot calc as IXSIZEKB is error-getting-size"
            else
                if [ "$REMIXSIZEKB" == "error-getting-size" ];then
                    F_LOG "Remote dir does not exists so we assume 0 KB size"
                    REMIXSIZEKB=0
                    REMIXSIZEMB=0
                    REMIXSIZEGB=0
                fi
                DIFFKB=$((REMIXSIZEKB - $IXSIZEKB))
                
                # it doesnt matter if the diff is positive or negative we want the diff:
                DIFFKBC=${DIFFKB/-/}
                
                if [ "$DIFFKBC" -gt "$MAXSYNCDIFFKB" ];then
                    F_OLOG "Size differs more then: $MAXSYNCDIFFKB KB for $IX ($IXPATH)\n\t\t\t\t\t- Kibibytes: local $IXSIZEKB | remote: $REMIXSIZEKB\n\t\t\t\t\t- Mebibytes: local $IXSIZEMB | remote: $REMIXSIZEMB\n\t\t\t\t\t- Gibibytes: local $IXSIZEGB | remote: $REMIXSIZEGB"
                fi
            fi
            # print some debug to stdout
            [ $DEBUG -eq 1 ] && echo -e "$IX ($IXPATH):\nKibibytes: local $IXSIZEKB | remote (before): $REMIXSIZEKB | remote (after): $AREMIXSIZEKB | DIFF: $DIFFKBC\nMebibytes: local $IXSIZEMB | remote: $REMIXSIZEMB\nGibibytes: local $IXSIZEGB | remote: $REMIXSIZEGB\n"
        fi
        
        # prepare output line
        MOUT="Started: $RSTARTTIME - Ended: $RENDTIME ($runtime_real seconds)\nIndex: $IX ($IXPATH) synced to ${TARGET}\nBefore (Remote|Local): $REMIXSIZEMB MiB | $IXSIZEMB MiB | Difference: $DIFFKBC KiB\nAfter (Remote|Local): $AREMIXSIZEMB MiB | $IXSIZEMB MiB"
        
        if [ "$MAILONLYLONG" -eq 1 ];then
            RLONGRUN=$(echo $LONGRUN | tr -d "." | sed 's/^0*//g')
            RCALCRESULT=$(echo $CALCRESULT | tr -d "." | sed 's/^0*//g')
            #[ $DEBUG -eq 1 ] &&
            F_LOG "DEBUG: RCALCRESULT was $RCALCRESULT, RLONGRUN was $RLONGRUN (LONGRUN was $LONGRUN, CALCRESULT was $CALCRESULT"
            # fallback if calc went wrong
            [ -z $RCALCRESULT ]&& RCALCRESULT=0
            if [ $RCALCRESULT -ge $RLONGRUN ];then
                echo -e "\n$MOUT" >> $LONGRUNLOG
                MAILLOG="$MAILLOG $LONGRUNLOG"
            else
                echo -e "\n$MOUT" >> $ALLLOG
            fi
        else
            echo -e "\n$MOUT" >> $ALLLOG
            MAILLOG="$MAILLOG $ALLLOG"
        fi
    done < summaryinfo_${TLOG}
    if [ $DEBUG -eq 0 ];then
        [ $DEBUG -eq 1 ]&& echo "Rotating log within genmaillog"
        F_ROTATELOG "summaryinfo_${TLOG}"
        rm ${TLOG}.parse
    fi
}

# send an email if defined
F_SENDMAIL(){
    DOMAIL=$1
    RSLOG="$2"
    
    # disable email when debug mode is on
    #[ $DEBUG -eq 1 ] && DOMAIL=0
    
    if [ "$DOMAIL" -eq 1 ];then
        F_OLOG "Preparing Email notification (MAILJOBBLOCK was $MAILJOBBLOCK, MAILSYNCEND was $MAILSYNCEND)"
        if [ ! -z "$MAILLOG" ];then
            # presort and filter out dups
            MUNIQUE=$(echo $MAILLOG | tr ' ' '\n' |sort -u | tr '\n' ' ')
            # calc sizes
            for mlog in $MUNIQUE ;do
                [ $DEBUG -eq 1 ]&& F_OLOG "Calculating $mlog"
                MLOGSTAT=$(stat -c %s $mlog)
                [ $DEBUG -eq 1 ]&& F_OLOG "Size in bytes: $MLOGSTAT"
                STATSB=$((STATSB + $MLOGSTAT))
                [ $DEBUG -eq 1 ]&& F_OLOG "Sum of all logs in bytes: $STATSB"
            done
            LOGSIZEKB=$((STATSB / 1024 ))
            [ $DEBUG -eq 1 ]&& F_OLOG "Overall log size is: $LOGSIZEKB Kilobytes"
            if [ "$LOGSIZEKB" -gt 100 ];then
                F_OLOG "Skipping attaching logfile because it is bigger then 100 KB"
                MAILMSG="The file size of \n$MUNIQUE\n ($LOGSIZEKB KB) exceeds the specified limit (100 KB) so we do not attach it here. Please open the log directly on $HOSTNAME."
            else
                F_OLOG "Attaching logfile because it is smaller then 100 KB."
                JOBSTARTED=$(egrep -m 1 -o "Started.*-[[:space:]]" $MUNIQUE |sed 's/-//g')
                JOBENDED=$(tail -n4 $MUNIQUE | egrep -o 'Ended.*[[:space:]]\(' | sed 's/(//g')
                MAILMSG="#######################################################################\n\nJob: $JOB\n$JOBSTARTED $JOBENDED\n\n#######################################################################\n\n$(cat $MUNIQUE)"
            fi
        else
            MAILMSG="There seems to be no rsync job matching your criteria (MAILLOG is empty which happens when you want long run jobs only but there are none)."
            F_OLOG "$MAILMSG"
        fi
        # mail throttle! we do not want thousands mails per second so you can adjust the throttle value to ensure not getting overwhelmed with mails
        if [ -s "$LASTMAILFILE" ];then
            CHKTR=$(cat $LASTMAILFILE)
            NOW=$(date +%s)
            MDIFF=$((NOW - $CHKTR))
            if [ "$MDIFF" -lt $MAILTHROTTLESEC ];then
                F_OLOG "Throttling active: $MDIFF is less then $MAILTHROTTLESEC"
                THROTTLE=1
            else
                F_OLOG "Throttling disabled: $MDIFF is more then $MAILTHROTTLESEC"
                THROTTLE=0
            fi
        else
            F_OLOG "Throttling disabled because $LASTMAILFILE either does not exists or is empty."
            THROTTLE=0
        fi
        # dependending on throttle and last mail we will send or not 
        if [ "$THROTTLE" -eq 0 ];then
            echo -e "${TOOL} v${VERSION}\n\nRsync job(s) from $HOSTNAME finished at $(date)\n\nCurrent system load:\n\n$(top -b -n1 |head -n 5)\n\n${MAILMSG}" | mail -s "${TOOL}: $JOB from $HOSTNAME finished"  "$MAILRECPT"
            F_OLOG "Email was sent to specified recipients with return code: <$?>"
            date +%s > $LASTMAILFILE
        else
            F_OLOG "No mail sent! Throttling active ($MAILTHROTTLESEC seconds) and met. Last sent mail: $(date -d@$(cat $LASTMAILFILE) +%F__%T)."
        fi
    else
        F_OLOG "Skipping mail notification as disabled (at this step) by user."
    fi
    # clean up so the log gets not overfilled
    #F_ROTATELOG "$RSLOG"
}

# sigh.. if we would have bash4 we could use BASHPID to detect the subshells PIDs but..
# as the other possibility to use sh -c '$PPID' is not working together with the rsync cmd I do it this hard way
# (cannot get the subshell pid of the rsync only for any new created one)
F_GETRPID(){
    RPROC="rsync.*Compression=no"
    [ $DEBUG -eq 1 ] && RPROC="sleep ${SLEEPTIME}"
    
    for arsync in $(ps -u splunk -o pid,fname,cmd|grep -v grep | egrep "$RPROC" |cut -d " " -f1);do
        RSYNCPIDS="$RSYNCPIDS $arsync"
    done
}


# this is some special M-A-G-I-C to set ionice on already running rsync processes
F_STARTHELPER(){
    F_LOG "$FUNCNAME: Helper run status: <$HELPERRUNNING> (empty means we will start the helper now)"
    
    if [ -z "$HELPERRUNNING" ];then
        while true;do
            # TODO: self checking helper from another helper (something for later)
            # idea: we increase the var on each run by +1 so we could monitor if this increases
            # in a given time range and then unset the HELPERRUNNING var to enforce
            # that the helper starts again
            HELPERRUNNING=$((HELPERRUNNING +1))
            if [ -f $IOHELPERFILE ];then
                F_LOG "$FUNCNAME: Preparing helper run ..."
                sleep 60
                F_DATEIOCHECK
                F_LOG "$FUNCNAME: Helper start count: $HELPERRUNNING"
                if [ -f $IOHELPERFILE ];then
                    [ $DEBUG -eq 1 ] && F_LOG "$FUNCNAME: DEBUG: IO prio before sourcing the io prio file: $BEFOREIOPRIO"
                    # catch the written current (maybe changed) io prio from file
                    . $IOHELPERFILE
                    [ $DEBUG -eq 1 ] && F_LOG "$FUNCNAME: DEBUG: IO prio after sourcing the io prio file: $IOPRIO"
                    if [ ! "$BEFOREIOPRIO" -eq "$IOPRIO" ];then
                        F_LOG "$FUNCNAME: We need to adjust running rsync!! Previous IO prio was: $BEFOREIOPRIO and now: $IOPRIO"
                        F_GETRPID
                        ionice -c2 -n $IOPRIO -p $RSYNCPIDS
                        F_LOG "$FUNCNAME: Re-nice PID $RSYNCPIDS to $IOPRIO returned statuscode: $?"
                    else
                        F_LOG "$FUNCNAME: No adjustment of IO prio needed (was: $BEFOREIOPRIO, now: $IOPRIO)"
                    fi
                else
                    F_LOG "$FUNCNAME: IO prio file $IOHELPERFILE is missing! Stopping helper!"
                    break
                fi
            else
                F_LOG "$FUNCNAME: IO prio file $IOHELPERFILE is missing! Stopping helper!"
                break
            fi
        done
        unset HELPERRUNNING
    else
        F_LOG "$FUNCNAME: Skipping starting a new helper because there is one running already"
    fi
}

# sync baby sync
F_SYNCJOBS(){
    # get splunk environment first for translating splunk vars
    F_GETSPLENV
    NOTIFYREMSPLUNK=0
    NOTIFYNEEDED=$1
    
    # if single ix mapping is used
    if [ ! -z "$IXMAPARRAY" ];then
        # sync ixmap option:
       for dirmap in $IXMAPARRAY;do
            unset MAPIX MAPDBTYPE MAPTARGET MAPSERVER
            MAPIX=$(echo $dirmap | cut -d "," -f 1)
            MAPDBTYPE=$(echo $dirmap | cut -d "," -f 2)
            MAPTARGET=$(echo $dirmap | cut -d "," -f 3)
            MAPSERVER=${MAPTARGET%:*}
            TARGETBASEDIR=${MAPTARGET##*:}
    
            if [ -z "$MAPIX" ]||[ -z "$MAPDBTYPE" ]||[ -z "$MAPTARGET" ]||[ -z "$MAPSERVER" ]||[ -z "$TARGETBASEDIR" ];then
                [ $DEBUG -eq 1 ]&& echo "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET, MAPSERVER or TARGETBASEDIR is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER, $TARGETBASEDIR)!"
                F_OLOG "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET MAPSERVER, TARGETBASEDIR is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER, $TARGETBASEDIR)!"
                break
            else
                # check for valid db type
                if [ "$MAPDBTYPE" == "db" -o "$MAPDBTYPE" == "colddb" -o "$MAPDBTYPE" == "summary" ];then
                    [ $DEBUG -eq 1 ]&& echo "Valid db type detected (ixmap)"
                else
                    [ $DEBUG -eq 1 ]&& echo "ERROR: invalid db type detected (ixmap)! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                    F_OLOG "ERROR: ABORTED processing $IXDIR because invalid db type detected! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                    break
                fi
                [ $DEBUG -eq 1 ]&& echo "Parsing given arguments processed fine for $MAPIX, $MAPDBTYPE, $MAPTARGET, $MAPSERVER, $TARGETBASEDIR"
                F_OLOG "Parsing given arguments processed fine for $MAPIX, $MAPDBTYPE, $MAPTARGET, $MAPSERVER, $TARGETBASEDIR"
            fi
            F_OLOG "Starting sync job for $MAPIX ($MAPDBTYPE)"
        
            # sync definitions:
            # defintion for hot/warm buckets
            if [ "$MAPDBTYPE" == "db" ];then
                F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                
                # get all defined paths (volume def) and homepaths
                # as we do not want to use volumes we need to filter out them but to be able to do so
                # we first need to identify them
                for hotwarm in $($SPLUNKX btool indexes list  \
                                | sed  '/^\[/,/\(^homePath =\|^path =\)/{//!d}' \
                                | sed -n '/^\[/,/^\(homePath =\|path =\)/p' \
                                | perl -i -p -e 's/\[//g;s/]\n/,/' \
                                | egrep -v ",path = "\
                                | egrep "^$MAPIX,"\
                                | cut -d " " -f3 \
                                | sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                #for hotwarm in $($SPLUNKX btool indexes list | egrep "^homePath =" | grep "/$MAPIX/" | cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" );do
                    [ ! -d "$hotwarm" ] && F_LOG "ERROR: $hotwarm is specified but is not a local directory!!" && exit
                    [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $hotwarm $MAPSERVER $MAPDBTYPE"
                    F_RSYNC "$hotwarm" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                    NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                done
            else
                # sync definition for cold buckets
                if [ "$MAPDBTYPE" == "colddb" ];then
                    F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                    for cold in $($SPLUNKX btool indexes list  \
                                | sed  '/^\[/,/\(^coldPath =\|^path =\)/{//!d}' \
                                | sed -n '/^\[/,/^\(coldPath =\|path =\)/p' \
                                | perl -i -p -e 's/\[//g;s/]\n/,/' \
                                | egrep -v ",path = "\
                                | egrep "^$MAPIX,"\
                                | cut -d " " -f3 \
                                | sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                    #for cold in $($SPLUNKX btool indexes list | egrep "^coldPath =" | grep "/$MAPIX/" |cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                        [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $cold $MAPSERVER $MAPDBTYPE"
                        F_RSYNC "$cold" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                        NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                    done
                else
                    # sync definition for summary buckets
                    # this one is a little bit more tricky as this do NOT need to be set explicitly and so can be missing in the regular index definition!
                    if [ "$MAPDBTYPE" == "summary" ];then
                        F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                        # first we parse all homepaths! and check if they contain a summary dir!
                        # when not explicit set the summary path is /homePath/summary ...
                        for undefsumm in $($SPLUNKX btool indexes list  \
                                            | sed  '/^\[/,/\(^homePath =\|^path =\)/{//!d}' \
                                            | sed -n '/^\[/,/^\(homePath =\|path =\)/p' \
                                            | perl -i -p -e 's/\[//g;s/]\n/,/' \
                                            | egrep -v ",path = "\
                                            | egrep "^$MAPIX,"\
                                            | cut -d " " -f3 \
                                            | sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                        #for undefsumm in $($SPLUNKX btool indexes list | egrep "^homePath =" | grep "/$MAPIX/" | cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" );do
                            # we replace the path (this can NOT handle custom paths - it would be possible to delete the last /xxx but then a missing custom path would fail!)
                            ixsumpath="${undefsumm%*/db}/summary"
                            [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $ixsumpath (<-- was created from: $undefsumm) $MAPSERVER $MAPDBTYPE"
                            if [ ! -d "$ixsumpath" ];then
                                F_LOG "WARN: cannot find $ixsumpath needed for syncing $ix...!"
                                [ $DEBUG -eq 1 ]&& echo "WARN: cannot find $ixsumpath needed for syncing $ix...!"
                            else
                                [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $ixsumpath $MAPSERVER $MAPDBTYPE"
                                F_RSYNC "$ixsumpath" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                                NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                            fi
                        done
                        # then we check for explicit defined summary paths and sync them
                        for defsumm in $($SPLUNKX btool indexes list  \
                                        | sed  '/^\[/,/\(^summaryHomePath =\|^path =\)/{//!d}' \
                                        | sed -n '/^\[/,/^\(summaryHomePath =\|path =\)/p' \
                                        | perl -i -p -e 's/\[//g;s/]\n/,/' \
                                        | egrep -v ",path = "\
                                        | egrep "^$MAPIX,"\
                                        | cut -d " " -f3 \
                                        | sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                        #for defsumm in $($SPLUNKX btool indexes list | egrep "^summaryHomePath =" | grep "/$MAPIX/" |cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g");do
                            [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $ixsumpath (<-- was created from: $defsumm) $MAPSERVER $MAPDBTYPE"
                            F_RSYNC "$defsumm" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                            NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                        done
                    else
                        F_OLOG "ERROR: MAPDBTYPE is not valid (<$MAPDBTYPE>)!"
                        [ "$DEBUG" -eq 1 ]&& echo -e "ERROR: MAPDBTYPE is not valid (<$MAPDBTYPE>)!"
                    fi
                fi
            fi
        done
    fi
        
    # if the dir mapping is used
    if [ ! -z "$IXDIRMAPARRAY" ];then
        # parse ixdirmap option:
        for dirmap in $IXDIRMAPARRAY;do
            unset MAPIXDIR MAPDBTYPE MAPTARGET
            MAPIXDIR=$(echo $dirmap | cut -d "," -f 1)
            MAPIX=${MAPIXDIR##*/}
            # trim out the idx name from the path otherwise rsync would .../idxname/idxname/<data>
            #MAPIXDIR="${FULLMAPIXDIR%/*}/"
            MAPDBTYPE=$(echo $dirmap | cut -d "," -f 2)
            MAPTARGET=$(echo ${dirmap} | cut -d "," -f 3)
            MAPSERVER=${MAPTARGET%:*}
            TARGETBASEDIR=$(echo "${MAPTARGET##*:}")
            F_OLOG "MAPTARGET: $MAPTARGET, $MAPIXDIR , $MAPDBTYPE"
            
            if [ -z "$MAPIXDIR" ]||[ -z "$MAPDBTYPE" ]||[ -z "$MAPTARGET" ]||[ -z "$MAPSERVER" ];then
                [ $DEBUG -eq 1 ]&& echo "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET or MAPSERVER is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER)!"
                F_OLOG "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET MAPSERVER is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER)!"
                break
            else
                # check for valid db type
                if [ "$MAPDBTYPE" == "db" -o "$MAPDBTYPE" == "colddb" -o "$MAPDBTYPE" == "summary" ];then
                    [ $DEBUG -eq 1 ]&& echo "Valid db type detected (ixdirmap)"
                else
                    [ $DEBUG -eq 1 ]&& echo "ERROR: invalid db type detected! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                    F_OLOG "ERROR: ABORTED processing $IXDIR because invalid db type detected! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                    break
                fi
                [ $DEBUG -eq 1 ]&& echo "Given arguments processed fine for $MAPIXDIR,$MAPDBTYPE"
                F_OLOG "Given arguments processed fine for ixdirmap: $MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER"
            fi
            F_OLOG "Starting sync job for $MAPIXDIR,$MAPDBTYPE"
        
            # sync definitions:
            # defintion for hot/warm buckets
            if [ "$MAPDBTYPE" == "db" ];then
                F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                #for hotwarm in $($SPLUNKX btool indexes list | egrep "^homePath =" | cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" | egrep "\[$MAPIXDIR\]" );do
                [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $MAPIXDIR $MAPSERVER $MAPDBTYPE"
                F_RSYNC "$MAPIXDIR" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                F_LOG "NOTIFYREMSPLUNK=$NOTIFYREMSPLUNK"
                #done
                #F_GENMAILLOG "$LOG"
            else
                # sync definition for cold buckets
                if [ "$MAPDBTYPE" == "colddb" ];then
                    F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                    #for cold in $($SPLUNKX btool indexes list | egrep "^coldPath =" |cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" | egrep "\[$MAPIXDIR\]");do
                    [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $MAPIXDIR $MAPSERVER $MAPDBTYPE"
                    F_RSYNC "$MAPIXDIR" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                    NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                    #done
                    #F_GENMAILLOG "$LOG"
                else
                    # sync definition for summary buckets
                    # this one is a little bit more tricky as this do NOT need to be set explicitly and so can be missing in the regular index definition!
                    if [ "$MAPDBTYPE" == "summary" ];then
                        F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG "norotate"
                        # first we parse all homepaths! and check if they contain a summary dir!
                        # when not explicit set the summary path is /homePath/summary ...
                        for undefsumm in $($SPLUNKX btool indexes list | egrep "^homePath =" | cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" | egrep "\[$MAPIXDIR\]" );do
                            # we replace the path (this can NOT handle custom paths - it would be possible to delete the last /xxx but then a missing custom path would fail!)
                            ixsumpath="${undefsumm%*/db}/summary"
                            [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $ixsumpath ($undefsumm) $MAPSERVER $MAPDBTYPE"
                            if [ ! -d "$ixsumpath" ];then
                                F_LOG "WARN: cannot find $ixsumpath needed for syncing $ix...!"
                                [ "$DEBUG" -eq 1 ]&& echo -e "WARN: cannot find $ixsumpath needed for syncing $ix...!"
                            else
                                F_RSYNC "$ixsumpath" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                                NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                            fi
                        done
                        # then we check for explicit defined summary paths and sync them
                        for defsumm in $($SPLUNKX btool indexes list | egrep "^summaryHomePath =" |cut -d " " -f3 |sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" | egrep "\[$MAPIXDIR\]");do
                            [ "$DEBUG" -eq 1 ]&& echo -e "Starting rsync with: $defsumm $MAPSERVER $MAPDBTYPE"
                            F_RSYNC "$defsumm" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                            NOTIFYREMSPLUNK=$((NOTIFYREMSPLUNK + $?))
                        done
                    else
                        # thaweddb DISABLED. This is normally nothing we want to sync!
                        # for thaw in $($SPLUNKX btool indexes list | egrep "^thawedPath =" | cut -d " " -f3 | sed "s#\\\$SPLUNK_DB/#$SPLUNK_DB#g" | egrep "\[$MAPIXDIR\]" );do
                        #   F_RSYNC "$thaw" $JOB2TARGET thaweddb 2>&1 >> $LOG
                        # done
                        F_OLOG "ERROR: MAPDBTYPE is not valid (<$MAPDBTYPE>)!"
                    fi
                fi
            fi
            LASTERR=$?
            #if [ "$IWANTREMOTENOTIFY" == "1" ]&&[ "$LASTERR" -eq 0 ];then
            #    if [ $NOTIFYNEEDED -eq 1 ];then
            #        F_LOG "EXECUTING REMOTE NOTIFY AS NEW BUCKETS HAVE BEEN SYNCED (and wait min time is over)!"
            #        F_EXECREMNOTIFY "$MAPSERVER" "${MAPIXDIR}/${MAPDBTYPE}" "$MAPIX"
            #    else
            #        F_LOG "No need to notify the remote server!"
            #    fi
            #else
            #    F_LOG "IWANTREMOTENOTIFY is not set so we do NOT notify the remote server!"
            #fi
        done
    fi

    #for rlog in $LOG; do
    [ $DEBUG -eq 1 ]&& echo "Rotating log after a full run"
    F_OLOG "calling logrotate processing for $LOG after a full run"
    F_ROTATELOG "$LOG"
    F_ROTATELOG "$OLOG"
    #done
    
    F_GENMAILLOG "$LOG"

    # send mail when this block is done (depending on your defined settings of course)
    #F_SENDMAIL $MAILJOBBLOCK "$LOG"
    
    #F_ROTATELOG "$LOG"
    if [ "$MAILSYNC" == 1 ];then
        F_SENDMAIL "$MAILSYNCEND" "$RSLOG"
    fi
    
    # delete io monitor file which auto ends the helper started by F_STARTHELPER (after 60sec worst case)
    rm $IOHELPERFILE
    
    return $NOTIFYREMSPLUNK
}

# informs remote system of new bucket(s) arrival
F_EXECREMNOTIFY(){
    F_LOG "starting $FUNCNAME with $@"
    TARGET="$1"
    IXPATH="$2"
    IXNAME="$3"
    
    if [ -z "$TARGET" ]||[ -z "$IXPATH" ]||[ -z "$IXNAME" ];then
        F_LOG "$FUNCNAME: ERROR: one of: target, ixpath or ixname are unset!"
        LASTERR=4
    else
        F_CHKSPLSTATE "${TARGET}"
        if [ $? -eq 0 ];then
            F_AUTH ${TARGET}
            EXECREMNOTIFY="rm ${IXPATH}/.bucketManifest ; $REMSPLUNKBIN _internal call /data/indexes/${IXNAME}/rebuild-metadata-and-manifests"
            ssh -T -c $SCPCIPHER -o Compression=no -x ${TARGET} "$EXECREMNOTIFY" >> $LOG 2>&1
            LASTERR=$?
            F_LOG "$FUNCNAME: Notifying ${TARGET} ended with $LASTERR"
        else
            F_LOG "$FUNCNAME: Skipping remote notify as remote splunk seems to be DOWN!"
            LASTERR=5
        fi
    fi
    
    F_LOG "$FUNCNAME ended with $LASTERR"
    return $LASTERR
}

F_AUTH(){
    F_LOG "starting $FUNCNAME with $@"
    unset REMSVR
    
    REMSVR="$1"
    
    if [ -z "$REMSVR" ];then
        F_LOG "doing local authentication"
        ${SHELPER}auth -auth "$SPLCREDS" >> $LOG 2>&1
    else
        F_LOG "doing remote authentication on ${REMSVR}"
        ssh -T -c $SCPCIPHER -o Compression=no -x ${REMSVR} "${SHELPER}auth -auth '${SPLCREDS}'"  >> $LOG 2>&1
    fi
    LASTERR=$?
    
    F_LOG "$FUNCNAME ended with $LASTERR"
    return $LASTERR
}

# by default we want intelligent sync handling
FCS=0

# check for args
case "$1" in
        -h|--help) 
        F_HELP
        exit
        ;;
        --help-speed       )  F_HELPSPEED ; exit 0 ;;
        --help-all         )  F_HELPALL ; exit 0 ;;
        --help-sync        )  F_HELPSYNC ; exit 0;;
        --help-patch-rsync )  F_HELPPATCHRSYNC; exit 0;;
        --help-install     )  F_HELPINSTALL ; exit 0 ;;
        -netspeed)
        shift 1
        echo -e "\nUsing net speed test (without Disk IO)"
        F_GETOPT $@
        F_NETSPEED "$@"
        exit
        ;;
        -filespeed)
        echo -e "\nUsing file write speed test (with Disk IO on the remote side)"
        shift 1
        F_GETOPT "$@"
        F_FILESPEED $@
        exit
        ;;
        -y)
        F_GETOPT "$@"
        echo "ENDLESS mode: $ENDLESSRUN (0: oneshot, 1: forever)"
        F_CHKSYNCTAX
        ;;
        *)
        echo -e "\nUnknown argument"
        F_HELP
        exit
        ;;
esac

# check if all required tools are in place
F_CHKBASE

# detect the process group and write it for easier killing
#echo $$ > ${TOOL}.pid
ps -o pgid= $$ | grep -o '[0-9]*' > ${TOOL}.pid

# start counter (do not touch)
COUNTER=0

F_LOG "Starting $TOOL in rsync mode ..."
[ $DEBUG -eq 1 ] && F_LOG "!!!! DEBUG MODE ENABLED !!!!"
[ $HEAVYDEBUG -eq 1 ] && F_LOG "!!!! H-E-A-V-Y DEBUG MODE ENABLED - You're a stupid human !!!!" && set -x

# the following will be the fallback in case we use full speed prio rates
[ -z "$IOPRIO" ]&& F_LOG "using default IO prio $DEFIOPRIO" && IOPRIO=$DEFIOPRIO
IOPRIOUNTOUCHED=$IOPRIO

# never touch this
DEBUGTIMER=0
unset HELPERRUNNING

# this actually STARTs all the magic (first of all we check if we run forever or not)
if [ $ENDLESSRUN -eq 1 ];then
    F_LOG "Brave dude! This tool will run forever! Hope you enjoy it ;-)"
    NOTIFYQ=9
    NOTIFYREMSPLUNK=$IWANTREMOTENOTIFY
    if [ "$IWANTREMOTENOTIFY" == "1" ];then
        # intelligent handling of remote notifying depending on a given time span and even
        # with a notify queue so when the wait period is over it will happen in any case
        while true;do
            [ $NOTIFYQ -eq 0 ] && LASTRUNTIME=$(date +%s)
            # notify remote splunk system that a FULL sync has finished and new buckets have been synced
            # this will only be done when there were really new data synced!
            if [ "$NOTIFYREMSPLUNK" -ge 1 ]||[ $NOTIFYQ -eq 1 ];then
                NOTIFYTIME=$(date +%s)
                LASTNOTIFY=$((NOTIFYTIME - LASTRUNTIME))
                if [ $LASTNOTIFY -ge $WAITNOTIFY ];then
                    NOTIFYQ=0
                    NOTIFY=1
                    if [ "$LASTERR" -eq 0 ];then
                        F_LOG "EXECUTING REMOTE NOTIFY AS NEW BUCKETS HAVE BEEN SYNCED (and wait min time is over)!"
                        F_EXECREMNOTIFY "$MAPSERVER" "${MAPIXDIR}/${MAPDBTYPE}" "$MAPIX"
                    else
                        F_LOG "Need to notify as new buckets have been synced but there was an error during sync ($LASTERR) so skipping notify"
                    fi
                else
                    [ $NOTIFYQ -eq 0 ] && LASTRUNTIME=$NOTIFYTIME
                    LASTNOTIFYM=$((LASTNOTIFY / 60))
                    WAITNOTIFYM=$((WAITNOTIFY / 60))
                    F_LOG "Would have executed remote notify but WAITNOTIFY is not over yet ($LASTNOTIFYM of $WAITNOTIFYM minutes passed) ..."
                    NOTIFYQ=1
                    NOTIFY=0
                fi       
            else
                F_LOG "Skipping remote notify as no new buckets have been synced.."
                NOTIFYQ=0
                NOTIFY=0
            fi
            F_SYNCJOBS $NOTIFY
            LASTERR=$?
            #NOTIFYREMSPLUNK=$?        
        done
    else
        # just sync, no notify
        while true;do
            F_SYNCJOBS 1
            _LOG "Skipping remote notify as disabled by user"
        done
    fi
else
    F_LOG "One shot mode. Well ok give it a try first that's fine ;-)"
    F_SYNCJOBS
fi

