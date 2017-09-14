#!/bin/ksh
#######################################################################
#   This script was written to give us a quick framework to 
#   base our daily health check upon. It does the following:
#   1)Finds and connects to all DBs on the system
#   2)Selects from SYSCAT.TABLES while connected, to ensure the DBs are ok
#   3)Finds the db2diag.log file, checks for 'Error' or 'Severe' entries from today
#   4)Checks the specified backup directory and verifies today's backup is good
#   5)Gives df output on the backup, archive log and db2diag directories
#
#   Does require that you manually set the BACKUPPATH variable to point to 
#   the location where backups are stored - or to TSM
#
#   This script is intended to be run as the instance owner with the 
#   db2profile already sourced
#
#   For now, this script assumes that Archive logging is enabled and the logs
#   are being stored on the local disk
#
#   Written by Sean R Ford (IBM)
#   Created on 5/15/2014
#######################################################################

#**************************************
#NEED TO CHANGE THE TSM BEHAVIOR TO BE LINUX grep -A -B specfic
#**************************************

db2start;
printf "Remote IP address:\n\n";
curl --silent http://myip.dnsomatic.com;
printf "\n\n";

##  !! NOTE: If TSM is used, the following environment variables must be set to get the script to run via crontab:
##DSMI_CONFIG=/usr/tivoli/tsm/client/api/bin64/dsm.opt
##DSMI_DIR=/usr/tivoli/tsm/client/api/bin64
##DSMI_LOG=/home/db2inst1/sqllib/db2dump
##export DSMI_CONFIG DSMI_DIR DSMI_LOG
##
##We have found in client environments, this normally comes from the instance owner's .profile. db2profile doesn't have these entires on its own, but .profile
##will likely source db2profile anyway
##
##Typical crontab entry:
### Daily Health Check 
##50 22 * * * . /devutil1/devinst1/.profile; /devutil1/devinst1/DB2dailyHC/DailyHC.sh > /devutil1/devinst1/DB2dailyHC/DB2dailyHC.out

##If backups are stored in Tivoli, use TIVOLI here
##Note that we will not check the backup on TSM, just query the list to verify we have one
##This was a design decision as we would have to download the entire backup from TSM to properly verify it

##BACKUPPATH=TIVOLI;
BACKUPPATH=/home/db2expc/DB2-Backups/;

##To ensure the output we're looking at is relevant (We wouldn't know, save for the listed backup dates which may not show up)
printf "Today's date $(date)\n\n";

printf "Getting DB list, connecting and selecting count(*) from syscat.tables\n\n";

COUNT=1;

###########
#The below checks only for local DBs in the catalog. In the event that this script is to be run on AIX, the line "grep -B5 Indirect" will need to be changed to:
#grep -p Indirect
###########

for i in `db2 list db directory | grep -B5 Indirect | grep "Database name" | cut -d ' ' -f28`;do
	db2 connect to $i;
	db2 "select count(*) from syscat.tables";

	if [[ $BACKUPPATH != "TIVOLI" ]]; then
		##Get the archive log path while we're still connected to the db, add to array in case we find more than one DB
		ARARCHLOG[$COUNT]=`db2 get db cfg for $i | grep "(LOGARCHMETH1)" | cut -d ':' -f2`;

		((COUNT=COUNT+1))
	fi
	db2 terminate;
done

printf "Looking in DIAGPATH for diaglogs, searching for 'Error' or 'Severe' entries from today only\n\n";

DIAGPATH=`db2 get dbm cfg | grep "(DIAGPATH)" | cut -d ' ' -f22`;
cd $DIAGPATH;

printf "Found file(s):\n\n";
find db2diag*log;
printf "Entries containing 'Error' in the last 24 hours\n\n";
##find db2diag*log -exec cat {} \; | grep `date +%Y-%m-%d` | grep -i error;  ##Was only looking for the current day the script ran
db2diag -gi "level=error" -H 1d -readfile;		##Will automatically find the latest db2diag.log and search for Error up to 24 hours ago -readfile is required from cron, or the command will try and read from stdin
printf "Entries containing 'Severe' in the last 24 hours\n\n";
##find db2diag*log -exec cat {} \; | grep `date +%Y-%m-%d` | grep -i severe;
db2diag -gi "level=severe" -H 1d -readfile;

printf "Checking for backups\n\n";

##Look for TSM backups from today

if [[ $BACKUPPATH = "TIVOLI" ]]; then
##Looked into running the db2adutl command once and storing the output into a variable, but
##doing so destroyed the formatting and made it difficult to read
	
	printf "Querying TSM for backups, this may take a while\n\n";

	printf "Backups from today:\n\n";
	db2adutl query full | grep `date +%Y%m%d`;

	##Look for TSM backups from yesterday
	printf "Backups from yesterday:\n\n";
	db2adutl query full | grep `TZ=aaa24 date +%Y%m%d`;
else
	###Look for local backups
	cd $BACKUPPATH;
	if [ "$(find ./WEB2*/*"$(date +%m%d)"*.001*)" ]; then
                printf "Backup(s) from today:\n\n";
                find ./WEB2*/*`date +%m%d`*.001*;
                printf "Attempting to validate 001 file with db2ckbkp - will skip anything compressed outside of DB2 (.Z, .gz, etc.)\n\n";
                find ./WEB2*/*`date +%m%d`*.001 -exec db2ckbkp {} \;
        ###Look for yesterday's backup
        elif [ "$( find ./WEB2*/*"$(TZ=aaa24 date +%Y%m%d)"*.001)" ]; then
                printf "Backup(s) from yesterday:\n\n";
                find ./WEB2*/*`TZ=aaa24 date +%Y%m%d`*;
                printf "Attempting to validate 001 file with db2ckbkp - will skip anything compressed outside of DB2 (.Z, .gz, etc.)\n\n";
                find ./WEB2*/*`TZ=aaa24 date +%Y%m%d`*.001 -exec db2ckbkp {} \;
        else
                printf "No backups were found for today or yesterday in the backup directory: $BACKUPPATH\n\n"
        fi

        #printf "Listing files in Archive log path to ensure old logs are being removed\n\n";

        #printf "DF on the Archive log path(s) to see space used\n\n";
        #printf "These will be in the same order as the DBs we connected to above\n\n";
        #for i in ${ARARCHLOG[*]}; do
        #       find $i -type f -name S*LOG* -exec ls -al {} \;
        #       df -h $i;
        #done
fi

###############################
#The below (and just above) entries will need to be changed to df -g for AIX
###############################

if [[ $BACKUPPATH != "TIVOLI" ]]; then
	printf "Checking $BACKUPPATH for space\n\n";
	df -h $BACKUPPATH;
fi
	printf "\n\nChecking $DIAGPATH for space\n\n";
	df -h $DIAGPATH;

##############################
#Copy backups off this drive
##############################

printf "Gzipping the backups..\n\n";
gzip -f /home/db2expc/DB2-Backups/WEB2GST/*.001;
gzip -f /home/db2expc/DB2-Backups/WEB2PICS/*.001;
gzip -f /home/db2expc/DB2-Backups/WEB2RANT/*.001;
printf "\n\nCopying backup directory off-drive\n\n";
cp -r /home/db2expc/DB2-Backups /storagealt/;
printf "Cleaning up backups on home older than 5 days";
find /home/db2expc/DB2-Backups/*/*.001.gz -mtime +5;
printf "\n\n";
find /home/db2expc/DB2-Backups/*/*.001.gz -mtime +5 -exec rm {} \;
printf "Done!\n\n";

##############################
#Finally, email this report
##############################
#mail -r "sford_kc@hotmail.com (sean@web2)" -s "Healthcheck $(date '+%A, %B %d')" seanferd@gmail.com < /home/db2expc/scripts/output/healthcheck.out

##comnpliant with RFC 5322 - needed reply address
mail -a "From: db2expc <seanferd@gmail.com>" -s "Healthcheck $(date '+%A, %B %d')" sford_kc@hotmail.com < /home/db2expc/scripts/output/healthcheck.out
