#!/bin/bash
##################################################################################################################################
#
# Sync local indices to remote destination (will REMOVE existing files @ DESTINATION!)
# Author: Thomas Fischer <mail@se-di.de>
#
VERSION="5.0"
###################################################################################################################################
#
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

# SPLUNK installation dir! Adjust to match your installation!
SPLDIR=/opt/splunk


##### MAIL settings start ############
# mail recipients need to be specified on CLI. Check --help!
# The next both options handle the amount of emails to send.
# Choose the one best matching your needs or disable completely.

# email after each sync block = 1 otherwise set this to 0.
# Can be overwritten at CLI (check --help)
MAILJOBBLOCK=0

# email after a full sync run (1 = enable, 0 = disable)
# Can be overwritten at CLI (check --help)
MAILSYNCEND=1

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
       
##### MAIL settings end ############

##### GENERAL stuff ################

# default IO priority (take also a look at FULLSPEEDPRIO to find out how to optimize sync speed)
DEFIOPRIO=5

# Debug mode (should be better set on the cmdline - check --help)
DEBUG=0

# heavy debug mode (should be set on the cmdline -> check --help)
# This mode will enable set -x so if you do not want to see your terminal explode ... then better never use this! ;)
HEAVYDEBUG=0

# set to 1 to run forever (endless rsync) or to 0 to run it once only
# overriding possible at cmdline (check --help)
ENDLESSRUN=0

# when debugging you can specify a time value for the very first pseudo sync process.
# we wait that amount of time which can be helpful for debugging several functions like ionice change
# time eval etc. It is highly recommended to specify something really unusual like 324s and not 60s
# because we filter the process list for exact this setting
# Format: sleep syntax (e.g. 17s = 17 seconds, 14m = 14 minutes , ...)
SLEEPTIME=9s

##### GENERAL stuff END ################


###########################################################################################################
# Flexible priority based on weekend and / or time of day
# Hint: The prio will be changed for NEW and already RUNNING rsync jobs!
# You can specify this fullspeedprio value directly from the commandline (check --help)
DEFFULLSPEEDPRIO=3

# Full speed time means that we run with a higher priority within a given time range.
# You can define as many time ranges you want delimited by space!
# FULLSPEEDTIME0 (sunday) ... up to ... FULLSPEEDTIME6 (saturday).
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
# some defaults for the speed tester within

# default ssh ciphers (can be overwritten by cmdline, check --help)
# these ciphers will be used in speed test.
# Format: cipher,cipher,...
DEFSPEEDCIPHER="arcfour256,arcfour128,blowfish-cbc,arcfour,hostdefault"

# default round count (can be overwritten by cmdline, check --help)
DEFSPEEDROUNDS=5

# default test size (in Megabytes) / amount of data to be used (can be overwritten by cmdline, check --help)
DEFTESTSIZE=128

# default block size to use for dd data input. This setting can be overwritten at cmdline, check --help.
# For details about this setting checkout "--help", too.
DEFBSSIZE="1M"

###########
# Calculating sizes
 
# Do you want to calculate the index sizes for comparison? Set to 1 if yes otherwise 0. This setting can be
# overwritten at cmdline, check --help!
# FORMAT: 1 or 0
CALCSIZES=1

# the maximum allowed diff for local vs. remote dir size in Kibibytes.
# e.g. 5242880 means 5 GB
# If CALCSIZES is set to 1 we will write a log entry for all indices where the local size differs more then
# the given amount. Set this to 0 to write a calc size log entry for each index.
MAXSYNCDIFFKB=5242880

#
# Do NOT walk behind this line
########################################################################################################
########################################################################################################
########################################################################################################
#
#

# bin
TOOL=$(echo ${0/\.sh}|tr -d "."|tr -d "/")

# mail throttle indicator file
LASTMAILFILE="${TOOL}.lastmail"

# the splunk binary
SPLUNKX=$SPLDIR/bin/splunk
[ ! -x "$SPLUNKX" ] && echo -e "ERROR: cannot find splunk binary >$SPLUNKX<. Please adjust SPLDIR variable inside $TOOL and try again" && exit 2

# logfile
LOG=./${TOOL}.log
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
        echo "ERROR MISSING LOG NAME FOR ROTATE!"
        return 2
    else
        F_GENTIME "%s"
        [ ! -d ${TOOL}_archive ] && mkdir ${TOOL}_archive
        gzip -c $1 > ${TOOL}_archive/${1}_${GENTIME}.log.gz && rm ${1}
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

    [ -z $FULLSPEEDPRIO ] && FULLSPEEDPRIO=$DEFFULLSPEEDPRIO && F_LOG "Using default full speed prio ($DEFFULLSPEEDPRIO)"
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
        echo "We should never reach this --> We cannot detect the week day! ABORTED"
        exit 3
        ;;
    esac

    F_LOG "Weekday: $CURDAY --> effective time range for full speed: $FULLSPEEDTIME"

    for t in $(echo "$FULLSPEEDTIME") ;do
        F_LOG "Checking given time range: $t" 
        FSTART=$(echo ${t} | cut -d "-" -f1 |tr -d ":")
        FEND=$(echo ${t} | cut -d "-" -f2 |tr -d ":")
        F_LOG "\t--> effective start time for full speed: $FSTART" 
        F_LOG "\t--> effective end time for full speed: $FEND" 
        if [ $CURTIME -ge $FSTART ] && [ $CURTIME -le $FEND ];then
            USEFULLSPEED=$((USEFULLSPEED + 1))
            F_LOG "Yeeeha! Full speed time ;-). Let the cable glow...!!" 
            F_LOG "Skipping any other time ranges we may have because 1 ok is enough!" 
            break
        else
            USEFULLSPEED=0
            F_LOG "We're not in full speed time range ($FSTART - $FEND)"  
        fi
    done

    # adjust - or not - the prio based on the time check
    if [ $USEFULLSPEED -gt 0 ];then
        [ $DEBUG -eq 1 ] && F_LOG "DEBUG: time prio $TIMEPRIO, usefullspeed $USEFULLSPEED"
        # adjust the prio to run with full speed
        IOPRIO=$TIMEPRIO
    else
        [ $DEBUG -eq 1 ] && F_LOG "DEBUG: time prio $IOPRIOUNTOUCHED, usefullspeed $USEFULLSPEED"
        # adjust the prio to run with given speed (either by -i or the default one)
        IOPRIO=$IOPRIOUNTOUCHED
    fi
    F_LOG "Prio was set to: $IOPRIO"
    # write the current prio to a file so our ionice helper knows about
    echo "IOPRIO=$IOPRIO" > $IOHELPERFILE
}

# speed test
F_SPEED(){
    [ -z "$SPEEDTARGET" ]&& echo -e 'missing HOST arg ! aborted!' && exit
    [ -z "$SPEEDCIPHER" ]&& echo -e "Using default ssh cipher: $DEFSPEEDCIPHER" && SPEEDCIPHER=$DEFSPEEDCIPHER
    [ -z "$SPEEDROUNDS" ]&& echo -e "Using default test rounds: $DEFSPEEDROUNDS" && SPEEDROUNDS=$DEFSPEEDROUNDS
    [ -z "$TESTSIZE" ]&& echo -e "Using default test size: $DEFTESTSIZE" && TESTSIZE=$DEFTESTSIZE
    [ -z "$BSSIZE" ]&& echo -e "Using default block size: $DEFBSSIZE" && TESTSIZE=$DEFBSSIZE
    SAVELOCATION="$1"
    
    CIPHERS=$(echo $SPEEDCIPHER|tr "," " ")
    unset ALLDDS DDRES
  
    for cipher in $CIPHERS ; do
        ALLDDS=0
        if [ "$cipher" == "hostdefault" ];then
            echo -e "\nUsing default cipher ($SPEEDROUNDS rounds):"
            for try in $(seq $SPEEDROUNDS); do
                DDRES=$((dd if=/dev/zero bs=$BSSIZE count=$TESTSIZE | ssh -o "Compression no" $SPEEDTARGET "cat - > $SAVELOCATION") 2>&1 | grep "MB/s" |cut -d "," -f 3 | cut -d " " -f 2)
                echo "Current speed of this run: $DDRES MB/s"
                F_CALC "scale=2;$ALLDDS+$DDRES"
                ALLDDS="$CALCRESULT"
            done
        else
            echo -e "\nUsing $cipher ($SPEEDROUNDS rounds):"
            for try in $(seq $SPEEDROUNDS); do
                DDRES=$((dd if=/dev/zero bs=$BSSIZE count=$TESTSIZE | ssh -c $cipher -o "Compression no" $SPEEDTARGET "cat - > $SAVELOCATION") 2>&1 | grep "MB/s" |cut -d "," -f 3 | cut -d " " -f 2)
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

    ... brought to you by secure diversITy <mail@se-di.de>
    
    
   $TOOL v${VERSION} USAGE / HELP
   ------------------------------
   
        -h|--help
        This output
        
        --help-sync
        The help / usage info for the sync process
        
        --help-speed
        The help / usage info for the builtin speed tester
        
        --help-all
        All of the above

EOHELP
}

F_HELPSPEED(){
    cat <<EOHELPSPEED

    ... brought to you by secure diversITy <mail@se-di.de>
    
    
   $TOOL v${VERSION} USAGE / HELP for the builtin speed tester
   --------------------------------------------------------------

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
            Example: 150M with "-m 1" will send 1 file with the size of (about) 150 MB
            
            -m SIZE/AMOUNT (without unit)
            Current set default file size: $DEFTESTSIZE * $DEFBSSIZE
            (how much amount of data should be transferred)
            
            -c SSH-CIPHER
            You can specify more then one cipher delimited by comma and within quotes (e.g. -c "blowfish-cbc,arcfour128")
            Default (if not set): $DEFSPEEDCIPHER
            To check available ciphers on the target execute this on the $TARGET(!):\n#> ssh -Q cipher localhost | paste -d , -s\n
    
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
 
    ... brought to you by secure diversITy <mail@se-di.de>
    
    
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
                                
                                The ixdirmap defines:
                                
                                    1) the local(!) directory you want to sync
                                    2) the db type which can be either one of: db, colddb or summary
                                    3) the remote SERVER where the local dir should be synced to (FQDN or IP)
                                    4) the remote DIR where the local dir should be synced to (without index name|so the root dir)
                                    
                                This whole thing is ultra flexible and you can specify more then 1 mapping, of course!
                                If you want to define more then 1 mapping just use space as delimeter and regardless
                                of one or multiple mappings always use QUOTES!
                                
        --ixmap="<indexname,dbtype,remote-server:/remote/rootpath>"
                                
                                The ixmap defines:
                                    
                                    1) The local index name you want to sync
                                    2) the db type which can be either one of: db, colddb or summary                                    
                                    3) the remote SERVER where the local dir should be synced to (FQDN or IP)
                                    4) the remote DIR where the local index should be synced to (without index name|so the root dir)
                                    
                                This whole thing is ultra flexible and you can specify more then 1 mapping, of course!
                                If you want to define more then 1 mapping just use space as delimeter and regardless
                                of one or multiple mappings always use QUOTES!
    
        NONE of the above will actually start any workers in PARALLEL!
        For this you need a little preparation first:
        
        1) create a symlink for each worker like this:
            $> ln -s $0 myworkerX (replace X with the number)
        
        2) execute myworkerX with --ixmap or --ixdirmap option:
            $> ./myworker1 -y --ixmap="ix01,db,srv1:/mnt/fastdisk ix01,colddb,srv2:/mnt/slowdisk"
            or
            $> ./myworker1 -y --ixdirmap="/var/dir1,colddb,srv1:/mnt/dir1 /var/dir2,db,srv1:/mnt/dir2"
        
        3) repeat steps 1-2 for as many workers as you want to start

    
    Sync: OPTIONAL arguments
    --------------------------------------------------------------
    
    The following OPTIONAL parameters are available to override global defaults:

        You can specify - if you like - the priorities for either the default or the fullspeed
        or both (we always use the 'best-effort' scheduling class)
        -i [0-7]                ionice prio for normal workhours (default is: $DEFIOPRIO)
                                --> 0 means highest prio and 7 lowest
        -f [0-7]                ionice full speed prio using more ressources on the server (default: $DEFFULLSPEEDPRIO)
                                --> 0 means highest prio and 7 lowest
        
        -E [0|1]                1 will let run $TOOL forever - 0 means one shot only. Overrides default setting.
                                If choosing 1 the rsync jobs will run in a never ending loop
                                (useful to minimize the delta between old and new environment)
                                Currently it is set to: $ENDLESSRUN (0 oneshot, 1 endless loop)
                                                                
        --calcsizes=[0|1]       If set to 1 local size and remote size of each index will be calculated and written to
                                summaryinfo_xxx logfile. Overrides default (currently set to $CALCSIZES).
        
        Sync: Some mail related options:
        -------------------------------------------
 
        --maileachjob=[0|1]     Send an email after each JOB (1) or not (0) - Overrides default.
                                Can be combined with all other mail* options.
                    
        --mailsyncend=[0|1]     Send an email after all JOBs are done (1) or not (0) - Overrides default.
                                Can be combined with all other mail* options.
                                If you use the -E option (endless run mode) after each full sync an email will be send.
                
        --mailto="<mailaddr>"   The receiver(s) of mails. You can specify more then 1 when delimiting by comma.
                                e.g.: --mailto="here@there.com,none@gmail.com"
                                You HAVE to use quotes here.
               
        --maillongrun=[0|1]     Attach logfiles where a rsync took longer then >$LONGRUN< - Overrides default.
                                Can be combined with all other mail* options.
    
        Debug options:
        -------------------------------------------
        
        -D                      Using the D option enables the debug mode. In this mode NO real rsync job will be made!
                                It will do a dry-run instead and the very first index will sleep for >$SLEEPTIME<
                                Besides that some extra debug messages gets written into the logfile and you will get the
                                summary info printed on stdout.
                                
        --heavydebug            Auto enables "-D". The absolute overload on debug messages. Actually will do 'set -x' so
                                you will see really EVERYTHING. Use with care!!!
                                Best practice is to redirect everything to a local file instead of stdout
                                e.g: $TOOL -y --heavydebug > ${TOOL}.debug
                                
HELPSYNC
}

F_HELPALL(){
    F_HELPSPEED
    F_HELPSYNC
}
        
F_GETOPT(){
[ $DEBUG -eq 1 ]&& echo "Reached F_GETOPT"
while getopts p:s:m:i:yf:E:Dr:c:b:j:-: OPT; do
        [ $DEBUG -eq 1 ]&& echo "Checking $OPT"
        case "$OPT" in
        s)
        SPEEDTARGET="$OPTARG"
        ;;
        p)
        STORE="$OPTARG"
        ;;
        m)
        TESTSIZE="$OPTARG"
        ;;
        i)
        IOPRIO="$OPTARG"
        ;;
        f)
        FULLSPEEDPRIO="$OPTARG"
        F_LOG "Fullspeed prio set on the commandline ($FULLSPEEDPRIO) - overwrites default"
        ;;
        E)
        ENDLESSRUN="$OPTARG"
        F_LOG "Set run mode to: $ENDLESSRUN"
        ;;
        D)
        DEBUG=1
        ;;
        r) # rounds for speedtests
        SPEEDROUNDS="$OPTARG"
        ;;
        c) # ssh cipher for speedtests
        SPEEDCIPHER="$OPTARG"
        ;;
        b) # dd block size for speedtests
        BSSIZE="$OPTARG"
        ;;
        j) # jobs to start/disable
        JOBS="$OPTARG"
        ;;
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
           help-speed       )  F_HELPSPEED ; exit 0 ;;
           help-all         )  F_HELPALL ; exit 0 ;;
           help-sync        )  F_HELPSYNC ; exit 0;;
           '' )        break ;; # "--" terminates argument processing
           # NOT enabled here:  * )         echo "Illegal option --$OPTARG" >&2; exit 2 ;;
         esac
         ;;
        *)
        #skip the rest
        ;;
    esac
done
}

# check sync mode syntax
F_CHKSYNCTAX(){    
    # check general arg deps
    if [ -z "$IXMAPARRAY" ]&&[ -z "$IXDIRMAPARRAY" ];then
        F_OLOG "You have to specify one of --ixmap or --ixdirmap! ABORTED."
        echo "You have to specify one of --ixmap or --ixdirmap! Check $TOOL --help. ABORTED."
        exit
    fi
    # check mail arg deps
    if [ "$MAILONLYLONG" -eq 1 ]||[ "$MAILJOBBLOCK" -eq 1 ]||[ "$MAILSYNCEND" -eq 1 ];then
        # check if mail rcpts are set
        if [ -z "$MAILRECPT" ];then
            F_OLOG "You have specified 1 or more mail options but not given any mail address. ABORTED."
            echo "You have specified 1 or more mail options but not given any mail address. Check $TOOL --help. ABORTED."
            exit
        fi
    fi
}

# will check if lock file exists, recheck if that lock is still valid and give back the result
F_LOCK(){
    LOCKDIR="$1"
    LOCKFILE="$LOCKDIR/.rsyncactive"
    if [ -f "$LOCKFILE" ];then
        # check if lockfile still valid - this is a fallback to ensure that we re-sync crashed jobs again
        # if we wouldn't validate a stale lock file would result in a never re-synced dir!
        ps -u splunk -o pid,args|grep -v grep | egrep -q "rsync.*$LOCKDIR"
        if [ $? -eq 0 ]||[ "$DEBUG" -eq 1 ];then
            # still valid / rsync in progress
            F_LOG "$LOCKDIR is currently rsynced by another process so we will skip that one (<$LOCKFILE> exists)."
            SKIPDIR=1
        else
            # lockfile not valid anymore!
            F_LOG "$LOCKDIR has a lock file set (<$LOCKFILE>) but no matching rsync process exists!! Will force resync!"
            SKIPDIR=0
        fi
    else
        F_LOG "Creating lock file <$LOCKFILE>"
        touch "$LOCKFILE"
        SKIPDIR=0
    fi
}

# sync syntax
F_RSYNC(){
    [ -z "$1" ]&& F_LOG 'missing SRCDIR arg ! aborted!' && exit
    SRCDIR="$1"
    [ -z "$2" ]&& F_LOG 'missing TARGET arg ! aborted!' && exit
    TARGET="$2"
    [ -z "$3" ]&& F_LOG 'missing DBTYPE arg ! aborted!' && exit
    DBTYPE="$3"
    
    # first trim the path and then get the index name
    TRIMTYPE=$(echo $SRCDIR | sed "s#/$DBTYPE##g")
    RSYNCINDEX=${TRIMTYPE##*/}
    
    echo "************************************************************************************************">> $LOG
    echo "$RSYNCINDEX" |egrep -q 'internal|audit|introspection|defaultdb|blockSignature|^_.*'
    if [ $? -eq 0 ];then
        F_LOG "Skipping <$SRCDIR> sync as it is an internal index!" 
    else
        F_LOG "Starting <$SRCDIR> sync"
        unset SKIPDIR
        F_LOCK "$SRCDIR"
        if [ "$SKIPDIR" -eq 0 ];then
            F_GENTIME
            RSTARTTIME="$GENTIME"
            if [ "$CALCSIZES" -eq 1 ];then
                IXSIZEKB=$(du -0xsk $SRCDIR| tr "\t" ";" |cut -d";" -f1)
                if [ -z "$IXSIZEKB" ];then
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
          
            # special handling for wrong configured indices:
            unset SPECIALEXCLUDES
            echo "$RSYNCINDEX" |egrep -q 'chat$|epos$|fraud$'
            if [ $? -eq 0 ];then
                PROBLEMINDEX=1
                F_LOG "Adjustment needed for: $RSYNCINDEX"
                RSYNCINDEX="$RSYNCINDEX/$DBTYPE"
                F_LOG "index name adjusted to: $RSYNCINDEX"
                SRCDIR="$SRCDIR/"
                F_LOG "src dir name adjusted to: $SRCDIR"
                SPECIALEXCLUDES="--exclude 'db/' --exclude 'colddb/' --exclude 'thaweddb/' --exclude 'summary/'"
            else
                PROBLEMINDEX=0
            fi
        
            F_LOG "Index: ${RSYNCINDEX}"
            F_LOG "Destination server: ${TARGET}" 
            F_LOG "Destination dir: $TARGETBASEDIR/${RSYNCINDEX} (FOLDER sync! Means the source folder will be created in $TARGETBASEDIR/${RSYNCINDEX}/)" 
            F_LOG "IO Priority: ${IOPRIO}"
            F_LOG "Local index size: $IXSIZEKB KB"
            # adjust io prio if needed
            F_DATEIOCHECK
            # let's continuesly monitor the io prio and adjust if needed
            F_STARTHELPER &
            SHPID=$!
            F_LOG "Initiating helper start in background (pid: $SHPID)"
            # start optimized sync with time tracking using bash builtin time!
            TIMEFORMAT="runtime_real=%E;runtime_kernelsec=%S;runtime_usersec=%U;cpuusage_perc=%P"
            unset RUNTIME
            # sigh I saw problems when you try to sync to a non existing dir. At least the main dir has to exists otherwise rsync silently fails!
            #ssh -T -c arcfour128 -o Compression=no -x ${TARGET} mkdir -p $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null
            
            # check remote index size
            if [ "$CALCSIZES" -eq 1 ];then
                if [ $PROBLEMINDEX -eq 0 ];then
                    REMIXSIZEKB=$(ssh -T -c arcfour128 -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                else
                    REMIXSIZEKB=$(ssh -T -c arcfour128 -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                fi
                if [ -z "$REMIXSIZEKB" ];then
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
               # rsync:
               # a: archive mode
               # v: verbose output
               # delete: removes files on the target side if they are missing locally
               # numeric-ids: don't map uid/gid values by user/group name
               # OFF --> W: copy whole file instead of calculating missing deltas
               # OFF --> delay-updates: put all updated files into place at end
               # e: execute a cmd (in this case ssh)
                 # ssh:
                 # T: turn off pseudo-tty to decrease cpu load on destination.
                 # c arcfour: use the weakest but fastest SSH encryption. Must specify "Ciphers arcfour" in sshd_config on destination.
                 # o Compression=no: Turn off SSH compression.
                 # x: turn off X forwarding if it is on by default.
            if [ "$DEBUG" -eq 1 ];then
                # for debugging time calc we will have the very first entry sleeping longer to get valid data
                if [ $DEBUGTIMER -eq 0 ];then
                    RUNTIME=$((echo "DEBUG MODE NO rsync $SRCDIR happens here --> CUSTOM WAIT HERE ($SLEEPTIME) !!! ADJUST IF NEEDED" >> $LOG && time ionice -c2 -n7 sleep ${SLEEPTIME} ) 2>&1 | tr "." ".")
                else
                    # DRY RUN! No changes!                        
                    RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync -av --dry-run --numeric-ids --delete $SPECIALEXCLUDES -e 'ssh -T -c arcfour128 -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}  2>&1 >> $LOG) 2>&1 | tr "." "." )
                fi
                DEBUGTIMER=$((DEBUGTIMER + 1))
            else
                # REAL RUN! CHANGES TARGET!
                F_LOG "Starting rsync from $SRCDIR to ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}:"
                F_LOG "rsync -av --numeric-ids --delete $SPECIALEXCLUDES -e 'ssh -T -c arcfour128 -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}"
                RUNTIME=$((time ionice -c2 -n${IOPRIO} rsync -av --numeric-ids --delete $SPECIALEXCLUDES -e 'ssh -T -c arcfour128 -o Compression=no -x' $SRCDIR ${TARGET}:$TARGETBASEDIR/${RSYNCINDEX}  2>&1 >> $LOG) 2>&1 | tr "." "." )
            fi
            if [ $? -ne 0 ];then
                F_LOG "ERROR: Syncing $SRCDIR ended with errorcode <$?> !!" 
                F_LOG "Please check arcfour cipher is supported on $TARGET and review the above rsync messages carefully!" 
                F_LOG "To check arcfour execute this on $TARGET:\n#> ssh -Q cipher localhost | paste -d , -s\nIf you cannot find arcfour ciphers copy the whole line and add it together with the arcfour ciphers to your sshd_config"
            else
                F_LOG "OK: Syncing $SRCDIR ended successfully!" 
            fi
            F_LOG "Syncing <$SRCDIR> to ${TARGET}:$TARGETBASEDIR finished"
            
            # check remote index size again
            if [ "$CALCSIZES" -eq 1 ];then
                if [ $PROBLEMINDEX -eq 0 ];then
                    AREMIXSIZEKB=$(ssh -T -c arcfour128 -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX}/${DBTYPE} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                else
                    AREMIXSIZEKB=$(ssh -T -c arcfour128 -o Compression=no -x ${TARGET} du -0skx $TARGETBASEDIR/${RSYNCINDEX} 2>/dev/null | tr "\t" ";" |cut -d";" -f1)
                fi
                if [ -z "$AREMIXSIZEKB" ];then
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
            
            [ ! -z $SHPID ] && kill $SHPID >> $LOG 2>&1 && F_LOG "Stopped starthelper" && unset HELPERRUNNING
            # write an easy parsable log entry with all relevant details
            F_GENTIME
            RENDTIME="$GENTIME"
            echo -e "PARSELINE;IX=${RSYNCINDEX};DBTYPE=${DBTYPE};IXPATH=${SRCDIR};IXSIZEKB=${IXSIZEKB};IXSIZEMB=${IXSIZEMB};IXSIZEGB=${IXSIZEGB};REMIXSIZEKB=${REMIXSIZEKB};REMIXSIZEMB=${REMIXSIZEMB};REMIXSIZEGB=${REMIXSIZEGB};AREMIXSIZEKB=${AREMIXSIZEKB};AREMIXSIZEMB=${AREMIXSIZEMB};AREMIXSIZEGB=${AREMIXSIZEGB};TARGET=${TARGET}:${TARGETBASEDIR}/${RSYNCINDEX};BEFOREIOPRIO=${BEFOREIOPRIO};AFTERIOPRIO=${IOPRIO};${RUNTIME/*runtime_real/runtime_real};RSTARTTIME=$RSTARTTIME;RENDTIME=$RENDTIME\n" >> ${LOG}.parse
            rm -vf $LOCKFILE
            F_LOG "Deleted lock file <$LOCKFILE>."
        else
            F_LOG "Skipping <$SRCDIR> sync because it is in use by another rsync process."
        fi
    fi
    echo "************************************************************************************************">> $LOG
}

# set rsync job specific log dynamically
F_SETLOG(){
    LOG=$3
    if [ "$LOG" == "$OLOG" ];then
        # skip rotate when the main log detected
        F_OLOG "Rotate skipped for main log"
    else
        RSLOG="$RSLOG $LOG"
        F_ROTATELOG "$LOG"
    fi
    LOG="${TOOL}_${1}_${2}.log"
    F_OLOG "Currently writing rsync process to: $LOG"
    F_OLOG "You can STOP all processes at everytime by executing:\n\t\t\t\t\t\tpkill -g \$(cat ${TOOL}.pid)"
}

# simple calc which do not round like bash do
# example arg: "scale=2;35489356/60/60"
# --> would calculate and round to two digits (scale)
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
    [ $DEBUG -eq 0 ] && F_ROTATELOG "summaryinfo_${TLOG}" ; rm ${TLOG}.parse
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
    F_ROTATELOG "$RSLOG"
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


# this is some special M-A-G-I-C to ionice running rsync processes
F_STARTHELPER(){
    F_LOG "Helper run status: <$HELPERRUNNING> (empty means we will start the helper now)"
    
    if [ -z "$HELPERRUNNING" ];then
        while true;do
            # TODO: self checking helper from another helper (something for later)
            # idea: we increase the var on each run by +1 so we could monitor if this increases
            # in a given time range and then unset the HELPERRUNNING var to enforce
            # that the helper starts again
            HELPERRUNNING=$((HELPERRUNNING +1))
            if [ -f $IOHELPERFILE ];then
                F_LOG "Preparing helper run ..."
                sleep 60
                F_DATEIOCHECK
                F_LOG "Helper start count: $HELPERRUNNING"
                if [ -f $IOHELPERFILE ];then
                    [ $DEBUG -eq 1 ] && F_LOG "DEBUG: IO prio before sourcing the io prio file: $BEFOREIOPRIO"
                    # catch the written current (maybe changed) io prio from file
                    . $IOHELPERFILE
                    [ $DEBUG -eq 1 ] && F_LOG "DEBUG: IO prio after sourcing the io prio file: $IOPRIO"
                    if [ ! "$BEFOREIOPRIO" -eq "$IOPRIO" ];then
                        F_LOG "We need to adjust running rsync!! Previous IO prio was: $BEFOREIOPRIO and now: $IOPRIO"
                        F_GETRPID
                        ionice -c2 -n $IOPRIO -p $RSYNCPIDS
                        F_LOG "Re-nice PID $RSYNCPIDS to $IOPRIO returned statuscode: $?"
                    else
                        F_LOG "No adjustment of IO prio needed (was: $BEFOREIOPRIO, now: $IOPRIO)"
                    fi
                else
                    F_LOG "IO prio file $IOHELPERFILE is missing! Stopping helper!"
                    break
                fi
            else
                F_LOG "IO prio file $IOHELPERFILE is missing! Stopping helper!"
                break
            fi
        done
        unset HELPERRUNNING
    else
        F_LOG "Skipping starting a new helper because there is one running already"
    fi
}

# sync baby sync
F_SYNCJOBS(){
    # get splunk environment first for translating splunk vars
    F_GETSPLENV
       
    # sync ixmap option:
    # TODO: single ix mapping!
    #IXMAPARRAY

    # sync ixdirmap option:
    for dirmap in "$IXDIRMAPARRAY";do
        unset MAPIXDIR MAPDBTYPE MAPTARGET
        MAPIXDIR=$(echo $dirmap | cut -d "," -f 1)
        MAPDBTYPE=$(echo $dirmap | cut -d "," -f 2)
        MAPTARGET=$(echo $dirmap | cut -d "," -f 3)
        MAPSERVER=${MAPTARGET%:*}
        if [ -z "$MAPIXDIR" ]||[ -z "$MAPDBTYPE" ]||[ -z "$MAPTARGET" ]||[ -z "$MAPSERVER" ];then
            [ $DEBUG -eq 1 ]&& echo "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET or MAPSERVER is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER)!"
            F_OLOG "ERROR: one of MAPIXDIR, MAPDBTYPE, MAPTARGET MAPSERVER is missing ($MAPIXDIR, $MAPDBTYPE, $MAPTARGET, $MAPSERVER)!"
            break
        else
            # check for valid db type
            if [ "$MAPDBTYPE" == "db" -o "$MAPDBTYPE" == "colddb" -o "$MAPDBTYPE" == "summary" ];then
                [ $DEBUG -eq 1 ]&& echo "Valid db type detected"
            else
                [ $DEBUG -eq 1 ]&& echo "ERROR: invalid db type detected! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                F_OLOG "ERROR: ABORTED processing $IXDIR because invalid db type detected! MAPDBTYPE = $MAPDBTYPE (have to be one of: db,colddb,summary)"
                break
            fi
            [ $DEBUG -eq 1 ]&& echo "Given arguments processed fine for $MAPIXDIR,$MAPDBTYPE"
            F_OLOG "Given arguments processed fine for $MAPIXDIR,$MAPDBTYPE"
        fi
        F_OLOG "Starting sync job for $MAPIXDIR,$MAPDBTYPE"
        
        # sync definitions:
        # defintion for hot/warm buckets
        if [ "$MAPDBTYPE" == "db" ];then
            F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG
            for hotwarm in $($SPLUNKX btool indexes list | egrep "^homePath =" | cut -d " " -f3 |sed 's#\\\$SPLUNK_DB/#$SPLUNK_DB#g' | egrep "$MAPIXDIR" );do
                F_RSYNC "$hotwarm" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
            done
            F_GENMAILLOG "$LOG"
        else
            # sync definition for cold buckets
            if [ "$MAPDBTYPE" == "colddb" ];then
                F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG
                for cold in $($SPLUNKX btool indexes list | egrep "^coldPath =" |cut -d " " -f3 |sed 's#\\\$SPLUNK_DB/#$SPLUNK_DB#g' | egrep "$MAPIXDIR");do
                    F_RSYNC "$cold" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                done
                F_GENMAILLOG "$LOG"
            else
                # sync definition for summary buckets
                # this one is a little bit more tricky as this do NOT need to be set explicitly and so can be missing in the regular index definition!
                if [ "$MAPDBTYPE" == "summary" ];then
                    F_SETLOG "$MAPSERVER" $MAPDBTYPE $LOG
                    # first we parse all homepaths! and check if they contain a summary dir!
                    # when not explicit set the summary path is /homePath/summary ...
                    for undefsumm $($SPLUNKX btool indexes list | egrep "^homePath =" | cut -d " " -f3 |sed 's#\\\$SPLUNK_DB/#$SPLUNK_DB#g' | egrep "$MAPIXDIR" );do
                        # we replace the path (this can NOT handle custom paths - it would be possible to delete the last /xxx but then a missing custom path would fail!)
                        ixsumpath="${undefsumm%*/db}/summary"
                        if [ ! -d "$ixsumpath" ];then
                            F_LOG "WARN: cannot find $ixsumpath needed for syncing $ix...!"
                        else
                            F_RSYNC "$ixsumpath" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                        fi
                    done
                    # then we check for explicit defined summary paths and sync them
                    for defsumm in $($SPLUNKX btool indexes list | egrep "^summaryHomePath =" |cut -d " " -f3 |sed 's#\\\$SPLUNK_DB/#$SPLUNK_DB#g' | egrep "$MAPIXDIR");do
                        F_RSYNC "$defsumm" "$MAPSERVER" $MAPDBTYPE 2>&1 >> $LOG
                    done
                    F_GENMAILLOG "$LOG"
                else
                    # thaweddb DISABLED. This is normally nothing we want to sync!
                    # for thaw in $($SPLUNKX btool indexes list | egrep "^thawedPath =" | cut -d " " -f3 | sed 's#\\\$SPLUNK_DB/#$SPLUNK_DB#g' | egrep "$MAPIXDIR" );do
                    #   F_RSYNC "$thaw" $JOB2TARGET thaweddb 2>&1 >> $LOG
                    # done
                    F_OLOG "ERROR: MAPDBTYPE is not valid (<$MAPDBTYPE>)!"
                fi
            fi
        fi
    done
    
    # send mail when this block is done (depending on your defined settings of course)
    #F_SENDMAIL $MAILJOBBLOCK "$LOG"
    
    F_ROTATELOG "$LOG"
    F_SENDMAIL $MAILSYNCEND "$RSLOG"

    # delete io monitor file which auto ends the helper started by F_STARTHELPER (after 60sec worst case)
    rm $IOHELPERFILE
}

# check for args
case "$1" in
        -h|--help) 
        F_HELP
        exit
        ;;
        --help-speed       )  F_HELPSPEED ; exit 0 ;;
        --help-all         )  F_HELPALL ; exit 0 ;;
        --help-sync        )  F_HELPSYNC ; exit 0;;
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
        F_CHKSYNCTAX
        ;;
        *)
        echo -e "\nUnknown argument"
        F_HELP
        exit
        ;;
esac

echo $$ > ${TOOL}.pid

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
    while true;do
        F_SYNCJOBS
    done
else
    F_LOG "One shot mode. Well ok give it a try first that's fine ;-)"
    F_SYNCJOBS
fi

