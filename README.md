# splunk_rsyncix

A rsync script for migrating or syncing from a given source.

Very powerful and including a speedtester as well :)

The following should give you an idea HOW powerful it is.

Please always use the --help parameter of the tool itself to get the newest information as this README might be not updated that frequently.


### --help

~~~
   splunk-rsyncix USAGE / HELP
   ------------------------------
   
        -h|--help
        This output
        
        --help-install
        Installation notes for the sync tool setup
        
        --help-sync
        The help / usage info for the sync process
        
        --help-speed
        The help / usage info for the builtin speed tester
        
        --help-all
        All of the above
~~~


### --help-install

~~~
    splunk-rsyncix INSTALL NOTES
    ---------------------------------

    1) sync-splunk-ix expects the following tools installed:
    
       /usr/bin/bc /usr/bin/rsync /usr/bin/mail /usr/bin/ssh /usr/bin/scp /usr/local/bin/shelper /usr/bin/wget
    
       If those are installed in different locations adjust the REQUIREDTOOLS variable.


    2) The special helper tool "shelper" must be installed separately on the SOURCE server
       and on all REMOTE/TARGET servers as well (I recommend using ansible or similar):
    
       https://github.com/secure-diversITy/splunk
       (checkout the README there for the install/update steps)
    
    
    3) Some commands within sync-splunk-ix requires to have a valid CLI / API authToken and so it is
       recommended to add a specific user and role for that on the SOURCE and on ALL REMOTE
       servers as well.
       
       Required capabilities on the REMOTE servers:
    
            - indexes_edit (when IWANTREMOTENOTIFY=1 to inform REMOTE server about new bucket arrival)

            For a basic setup (with just the needed capabilities above):
        
            $> splunk add role syncrole -capability indexes_edit
            $> splunk add user syncuser -password 'YOURSECRET' -role syncrole

            Either adjust the SPLCREDS variable with: "syncrole:YOURSECRET" or start the sync with:
            
            $> SPLCREDS="syncrole:YOURSECRET" sync-splunk-ix ...
            
        Required capabilities on the LOCAL servers:
            
            - N/A no credentials or user required

    4) SSH access:

       Every source server needs password-less access (i.e. ssh-key) to every target server.
       For this you need to put each server's pub key on every target server (~/.ssh/authorized_keys).    

~~~

### --help-speed

~~~
   splunk-rsyncix USAGE / HELP for the builtin speed tester
   --------------------------------------------------------------

   This speed test can only be an indicator and heavily depends on the current load on both machines
   i.e. when you are doing tests 10 min later the results might differ.
   
   I recommend to choose at least 50 rounds (the more the better) and testing once with
   filesize ("-b") of 128M, 1024M, 5120M and 10240M or any other values you are using as your bucket size.
   
   Of course this should be repeated for every different storage on the remote site (e.g. once for your FLASH
   storage, once for your HDD etc).
   
   The following both options can be used EXCLUSIVELY only and they HAVE TO be the first argument!
        
        -netspeed -s <target-server> [-r ROUNDS -b BLOCKSIZE -m AMOUNT -c SSH-CIPHER]
            Test your connection by transferring data without any disk I/O
            The amount of data will be transferred without any disk IO.
            It uses the logic: local /dev/zero --> remote /dev/null
        
            -r ROUNDS
            Give a value of rounds. Each cipher - or the one you specified -
            will be check this amount of rounds (Current set default is 5).
            
            -b BLOCKSIZE
            We use "dd" for reading in data and therefore you can specify a blocksize in dd syntax here.
            Current set default: 1M
            Example: "-b 150M" combined with "-m 1" will send 1 file with the size of (about) 150 MB
            
            -m SIZE/AMOUNT (ALWAYS: without unit! SIZE is ALWAYS in MB)
            Current set default file size: 512 * 1M
            (how many data should be transferred)
            Example: "-b 1M" combined with "-m 1024" will send 1 file with the size of (about) 1024 MB and a block size of 1 MB
            
            -c SSH-CIPHER
            You can specify more then one cipher delimited by comma and within quotes (e.g. -c "blowfish-cbc,arcfour128")
            Default (if not set): aes192-cbc,arcfour256,arcfour,arcfour128,hostdefault
            To check available ciphers on the target execute this on the (!):\n#> ssh -Q cipher localhost
            Best performance ciphers are usually (in that order):
                1) aes192-cbc
                2) arcfour256   (usually requires sshd_config adjustment)
                3) arcfour      (usually requires sshd_config adjustment)
                4) arcfour128   (usually requires sshd_config adjustment)
    
        -filespeed -s <target-server> -p STORAGE-PATH [-r ROUNDS -b BLOCKSIZE -m AMOUNT -c SSH-CIPHER ]
        
            -p STORAGE-PATH
            The remote storage path where the test file should get written.
            The amount of data will be transferred and written to disk on the target.
            This WILL produce no local IO but on the remote site and is a more realistic check of the end result.
            It uses the logic: local /dev/null --> remote /path/.speedtestfile
            
            -r  --> SEE 'netspeed' above
            -m  --> SEE 'netspeed' above
            -c  --> SEE 'netspeed' above
            -b  --> SEE 'netspeed' above

~~~

### --help-sync

~~~
   splunk-rsyncix USAGE / HELP for the sync process
   --------------------------------------------------------------

    -y          This actually enables syncing.
                (checkout the optional args if you want to override default options or starting in special modes).
    
    HINT: volume based index configuration is NOT supported yet!!!
    
    FULL SPEED time ranges are set within sync-splunk-ix and are checked every 60 seconds. This is done by an extra
    helper running independent from the current sync process.
    
    What happens when we enter or left the full speed time range?
      1) All RUNNING rsync processes started by sync-splunk-ix will be adjusted on-the-fly(!) either by full speed or by low speed!
      2) Any new rsync process will be started with the new prio
      
    The following FULL SPEED time ranges are currently set (modify the time variables to your needs within sync-splunk-ix):

            sunday:     00:00-23:59
            monday:     00:00-06:59 20:00-23:59
            tuesday:    00:00-06:59 20:00-23:59
            wednesday:  00:00-06:59 20:00-23:59
            thursday:   00:00-06:59 20:00-23:59
            friday:     00:00-06:59 20:00-23:59
            saturday:   00:00-23:59
    
    
    Sync: REQUIRED arguments
    --------------------------------------------------------------

    -T <target-server> 
    --target=<target-server>

                        The target indexer you want to sync the local data to.
                        Ensure you have exchanged your local ssh pub key to this server.

                        Examples:
                        -T myindexer1.local
                        --target myindexer2.local

    --indexconfig=<path>|<download-uri>|<git-repo>
 
                        full path to the mandatory configuration file which can exists locally
                        or
                        specified as a direct-download URL (must start with http/https)
                        or
                        specified as a git repo (must start with "git@")

                        Format: <index-path>,<index type>,<target-path>,<after>,<before>,<priority>

                        index-path: /<local-splunk-path/<index-name>
                                    the local full path to the index which should be synced

                        index-type: hot|db|colddb|summary
                                    (only 1 allowed, if you need more then 1 add each separately - 1 per line)
                                    hot = hot, db = warm, colddb = cold, summary = summary index

                        target-path: /opt/splunk_data/fastdisk for hot, warm & summary and /opt/splunk_data/slowdisk for cold

                        after: 0|all|<123>days|<full date + time>
                               0|all:
                                    no starting time (i.e sync from the beginning)
                                    ignored when index-type = hot.

                               <123>days:
                                    how many days backwards should be synced (not 100% exact)
                                    or in other words: OLDEST event you want to sync - in days
                                    Format: "123days"

                               <full date + time>:
                                    date & time when the sync should start (not 100% exact).
                                    or in other words: OLDEST event you want to sync - as date+time
                                    Format: "YYYY-MM-DD hh:mm:ss"

                        before: 0|all|now|<123>days|<full date + time>
                                0|all|now:    
                                    no end time (i.e sync until now - especially useful when using the sync in never-ending mode)
                                    ignored when index-type = hot.

                               <123>days:
                                    how many days backwards should be synced (not 100% exact)
                                    or in other words: NEWEST event you want to sync - in days
                                    Format: "123days"

                               <full date + time>:
                                    date & time when the sync should end (not 100% exact).
                                    or in other words: NEWEST event you want to sync - as date+time
                                    Format: "YYYY-MM-DD hh:mm:ss"

                        priority: 1-3 (NOTE: NOT IMPLEMENTED YET!)
                                  1: index will run in a fully dedicated process to sync as fast as possible
                                  2 + 3 will run with lower and lowest sync priority and share the sync process with others.

                                  This setting is just for sync ordering and has nothing to do with priorizing system ressources.
                                  Use 1 with care as it can put noticable load on source(s) and target(s) when specified too often.

                        EXAMPLES:

                        /opt/splunk_data/fastdisk/cc,hot,/opt/splunk_data/fastdisk,all,all,1
                        /opt/splunk_data/fastdisk/cc,db,/opt/splunk_data/fastdisk,30days,now,3
                        /opt/splunk_data/slowdisk/foo,colddb,/opt/splunk_data/slowdisk,90days,now,3
                        /opt/splunk_data/fastdisk/bar,summary,/opt/splunk_data/fastdisk,2021-01-01 00:00:00,now,2
                        /opt/splunk_data/fastdisk/bar,db,/opt/splunk_data/fastdisk,2021-02-01 00:00:00,2021-04-01 14:00:00,2


    NOTE:
    if you want to run syncs in parallel you have to set the priority 1 on each wanted index (test CPU and bandwidth usage before doing
    this in a production environment!) otherwise sync-splunk-ix will handle these automatically based on the load.

    Sync: OPTIONAL arguments
    --------------------------------------------------------------
    
    The following OPTIONAL parameters are available to override global defaults:

        You can specify - if you like - the priorities for either the default or the fullspeed
        or both (we always use the 'best-effort' scheduling class)
        -i [0-7]                    ionice prio for normal workhours (default is: 5)
                                    --> 0 means highest prio and 7 lowest
        -f [0-7]                    ionice full speed prio using more ressources on the server (default: 3)
                                    --> 0 means highest prio and 7 lowest
        
        -E [0|1]                    1 will let run sync-splunk-ix forever - 0 means one shot only. Overrides default setting.
                                    If choosing 1 the rsync jobs will run in a never ending loop
                                    (useful to minimize the delta between old and new environment)
                                    Currently it is set to: 0 (0 oneshot, 1 endless loop)
                                                                
        --calcsizes=[0|1]           If set to 1 local size and remote size of each index will be calculated and written to
                                    summaryinfo_xxx logfile. Overrides default (currently set to 1).
                                
        -G  <REMOTE GUID>           This will replace a local (auto detected) splunk GUID with the given GUID on the remote server.
        --remoteguid=<REMOTE GUID>  you can identify the target server (!) GUID here: /opt/splunk/etc/instance.cfg
                                    The bucket directories will be renamed so they match with the remote running splunk instance.
                                    Keep in mind that this is completely unsupported by splunk - while working well - until further notice ;)
                                    Instead of the GUID you can also use special keywords:
                                        "REMOVE" will not replace the GUID but just remove it from the buckets instead
                                        "AUTODETECT:<target-server>" will detect the target server GUID fully automatic

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
               
        --mailonlylong=[0|1]        Attach logfiles where a rsync took longer then >.50< - Overrides default.
                                    Can be combined with all other mail* options.
    
        Debug options:
        -------------------------------------------
        
        --forcesync                 sync-splunk-ix uses an intelligent handling and detection of multiple running sync
                                    processes and will skip to sync a folder when another sync is currently processing it!
                                    With this setting you can force to sync even when another sync process is still running!
                                    Use this option with care because it could result in unexpected behavior - It is better to stop
                                    all other sync processes instead or take another run when the other sync job has finished.
        
        -D|--dry                    Using the D option enables the debug mode. In this mode NO real rsync job will be made!
                                    It will do a dry-run instead and the very first index will sleep for >0s<
                                    Besides that some extra debug messages gets written into the logfile and you will get the
                                    summary info printed on stdout.
                                
        --heavydebug                Auto enables "-D". The absolute overload on debug messages. Actually will do 'set -x' so
                                    you will see really EVERYTHING. Use with care!!!
                                    Best practice is to redirect everything to a local file instead of stdout
                                    e.g: sync-splunk-ix.sh -y --heavydebug > sync-splunk-ix.debug

~~~
