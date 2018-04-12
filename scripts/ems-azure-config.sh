#/tmp/ems/scripts/ems-azure-config.sh:
#!/bin/bash -e

#Make sure we have enough parameters (10). If not, warn and exit.

ARGS=$@

usage () {
   echo ""
   echo "Usage $0 <EMS Port #> <EMS Server IP 1> <EMS Server IP 2> <EMS Data Azure Storage Account1 Name> <Azure Storage Account 1 Key> <EMS Data Azure Storage Account 2 Name> <Storage Account 2 Key> <Existing Storage Account for EMS Installer> <Existing Storage Account Key> <Existing Share where EMS installer is located>"
   echo ""
}
share=${10}

if [ "$#" -lt 10 ]
then
  usage
  exit 1
else

# Figure out if we are a TIBCO access, client or server VM. If it is a server, is it one or two.

  echo " Starting TIBCO-EMS Configuration Script"

  hosttype=`hostname |grep Access`
  if [ "$hosttype" != "" ] ;then
    exit 0
  else
   myip=`ifconfig |grep inet |grep -v 127.0.0.1 |grep -v inet6|awk '{print $2}'`
  if [ "$myip" != "$2" -a "$myip" != "$3" ] ; then
   client=true
   echo " Configuring a TIBCO EMS Client VM"
  else
    if [ "$myip" = "$2" ] ;then
      server=1
      echo " Configuring TIBCOServer1"
    else
      server=2
      echo " Configuring TIBCOServer2"
    fi
  fi   

# Update the system, and install Java development, unzip, and CIFS-Utils

  echo " Install Java Development tools and update the OS"
 
  yum install  -y java-devel cifs-utils unzip

  yum update -y

# configure the firewall to allow access for the EMS port

  echo " Configuring the firewall to allow EMS port access"

  firewall-cmd --zone=public --add-port=$1/tcp --permanent
  firewall-cmd --reload

  echo " Mounting existing Azure file share and downloading EMS"

# create the tib-afs-utils.sh script

  mkdir --parents /tmp/ems/scripts

  cat >> /tmp/ems/scripts/tib-afs-util.sh <<EOF

#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# Script Name: tib-afs-utils.sh
# Author: Hans Krijger (github:hglkrijger)
# Version: 0.3
# Last Modified By: Richard Flather, April, 2018 
# Description:
#  This script provides basic functionality for creating and mounting an Azure
#  File Service share for use with TIBCO EMS.
# Note:
# This script has been tested on Red Hat 7.4 and still must be root

help()
{
    echo "Usage: \$(basename \$0) -a storage_account -k access_key [-h] [-c] [-p] [-s share_name] [-b base_directory]"
    echo "Options:"
    echo "  -a    storage account which hosts the shares (required)"
    echo "  -k    access key for the storage account (required)"
    echo "  -h    this help message"
    echo "  -c    create and mount afs share"
    echo "  -p    persist the mount (default: non persistent)"
    echo "  -s    name of the share (default: esdata00)"
    echo "  -b    base directory for mount points (default: /sharedfs)"

}

error()
{
    echo "\$1" >&2
    exit 3
}

log()
{
    echo "\$1"
}

# issue_signed_request 
#   <verb> - GET/PUT/POST
#   <url> - the resource uri to actually post
#   <canonical resource> - the canonicalized resource uri
# see https://msdn.microsoft.com/en-us/library/azure/dd179428.aspx for details
issue_signed_request() {
    request_method="\$1"
    request_url="\$2"
    canonicalized_resource="/\${STORAGE_ACCOUNT}/\$3"
    
    request_date=\$(TZ=GMT date "+%a, %d %h %Y %H:%M:%S %Z")
    storage_service_version="2015-04-05"
    authorization="SharedKey"
    file_store_url="file.core.windows.net"
    full_url="https://\${STORAGE_ACCOUNT}.\${file_store_url}/\${request_url}"
    
    x_ms_date_h="x-ms-date:\$request_date"
    x_ms_version_h="x-ms-version:\$storage_service_version"
    canonicalized_headers="\${x_ms_date_h}\n\${x_ms_version_h}\n"
    content_length_header="Content-Length:0"
    
    string_to_sign="\${request_method}\n\n\n\n\n\n\n\n\n\n\n\n\${canonicalized_headers}\${canonicalized_resource}"
    decoded_hex_key="\$(echo -n \${ACCESS_KEY} | base64 -d -w0 | xxd -p -c256)"
    signature=\$(printf "\$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:\$decoded_hex_key" -binary |  base64 -w0)
    authorization_header="Authorization: \$authorization \${STORAGE_ACCOUNT}:\$signature"
    
    curl -sw "/status/%{http_code}/\n" \
        -X \$request_method \
        -H "\$x_ms_date_h" \
        -H "\$x_ms_version_h" \
        -H "\$authorization_header" \
        -H "\$content_length_header" \
        \$full_url  
}

validate() {
    if [ ! "\$1" ];
    then
        error "response was null"
    fi
    
    if [[ \$(echo \${1} | grep -o "/status/2") || \$(echo \${1} | grep -o "/status/409") ]];
    then
        # response is valid or share already exists, ignore
        return
    else
        # other or unknown status
        if [ \$(echo \${1} | grep -o "/status/") ];
        then
            error "response was not valid: \${1}"
        else
            error "no response code found: \${1}"
        fi
    fi
}

list_shares() {
    response="\$(issue_signed_request GET ?comp=list "\ncomp:list")"
    echo \${response}
}

create_share() {
    share_name="\$1"
    log "creating share \$share_name"    
    
    # test whether share exists already
    response=\$(list_shares)
    validate "\$response"
    exists=$(echo ${response} | grep -c "<Share><Name>\${share_name}</Name>")
    
    if [ \${exists} -eq 0 ];
    then
        # create share
        response=\$(issue_signed_request "PUT" "\${share_name}?restype=share" "\${share_name}\nrestype:share")
        validate "\$response"
    fi
}

mount_share() {
    share_name="\$1"
    mount_location="\$2"
    persist="\$3"
    creds_file="/etc/cifs.\${share_name}"
    mount_options="vers=3.0,nostrictsync,cache=strict,serverino,dir_mode=0777,file_mode=0777,credentials=\${creds_file}"
    mount_share="//\${STORAGE_ACCOUNT}.file.core.windows.net/\${SHARE_NAME}"
    
    log "creating credentials at \${creds_file}"
    echo "username=\${STORAGE_ACCOUNT}" >> \${creds_file}
    echo "password=\${ACCESS_KEY}" >> \${creds_file}
    chmod 600 \${creds_file}
    
    log "mounting share \$share_name at \$mount_location"
    
    if [ \$(cat /etc/mtab | grep -o "\${mount_location}") ];
    then
        error "location \${mount_location} is already mounted"
    fi
    
    [ -d "\${mount_location}" ] || mkdir -p "\${mount_location}"
    mount -t cifs \${mount_share} \${mount_location} -o \${mount_options}
    
    if [ ! \$(cat /etc/mtab | grep -o "\${mount_location}") ];
    then
        error "mount failed"
    fi
    
    if [ \${persist} ];
    then
        # create a backup of fstab
        cp /etc/fstab /etc/fstab_backup
        
        # update /etc/fstab
        echo \${mount_share} \${mount_location} cifs \${mount_options} >> /etc/fstab
        
        # test that mount works
        umount \${mount_location}
        mount \${mount_location}
        
        if [ ! \$(cat /etc/mtab | grep -o "\${mount_location}") ];
        then
            # revert changes
            cp /etc/fstab_backup /etc/fstab
            error "/etc/fstab was not configured correctly, changes reverted"
        fi
    fi
}

#######################################

if [ "\${UID}" -ne 0 ];
then
    error "You must be root to run this script."
fi

STORAGE_ACCOUNT=""
ACCESS_KEY=""
SHARE_NAME="esdata00"
BASE_DIRECTORY="/sharedfs"

while getopts :b:a:k:s:pch optname; do
  log "Option \$optname set"
  case \${optname} in
    b) BASE_DIRECTORY=\${OPTARG};;
    a) STORAGE_ACCOUNT=\${OPTARG};;
    k) ACCESS_KEY=\${OPTARG};;
    s) SHARE_NAME=\${OPTARG};;            
    p) PERSIST=1;;
    c) CREATE_MOUNT=1;;
    h) help; exit 1;;
    ?) help; error "Option -\${OPTARG} not supported.";;
    :) help; error "Option -\${OPTARG} requires an argument.";;
  esac
done

if [ ! \${STORAGE_ACCOUNT} ];
then
    help
    error "Storage account is required."
fi

if [ ! \${ACCESS_KEY} ];
then
    help
    error "Access key is required."
fi

### create and mount a share in the specified storage account
if [ \${CREATE_MOUNT} ];
then
    create_share "\$SHARE_NAME"
    mount_share "\$SHARE_NAME" "\${BASE_DIRECTORY}/\${SHARE_NAME}" \$PERSIST
fi
####################################################################################
EOF

  chmod 777 /tmp/ems/scripts/tib-afs-util.sh

# Install TIBCO EMS
# need to put the TIBCO install file in /tmp/ems/installer
# mount the storage account with the TIBCO EMS installer

# call tib-afs-utils.sh to mount the Azure file share 

    /tmp/ems/scripts/tib-afs-util.sh -a "$8" -k "$9" -c -s "$share" -b /mnt >tib-afs3.out 2>&1

# check status by seeing it the file share is mounted
   mount3=`df |grep "$share"`
   if [ "$mount3" = "" ] ; then
     echo "Mounting the $share share has failed! Exiting"
     exit
   fi

  mkdir --parents /tmp/ems/installer
  cp /mnt/$share/*.zip /tmp/ems/installer; cd /tmp/ems/installer ;unzip TIB*.zip

# Install EMS
  currdir=`pwd`
  cd /tmp/ems/installer
  ./TIBCOUniversalInstaller-lnx-x86-64.bin -silent
  cd $currdir

  echo " Unmounting share and configring EMS"

# Change owner to tibco 
  chown -R tibco:tibco /opt/tibco
  chmod -R 750 /opt/tibco

# Umount the TIBCO installer share
  umount /mnt/$share

# Setup TIBCO EMS Environment vars
  export TIBCO_HOME=/opt/tibco
  export TIBEMSD_SERVERID=$server
  export TIBCOEMS_VERSION=$(ls $TIBCO_HOME/ems)
  export TIBEMSD_LOGFILE=$TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin/logs/tibemsd$TIBEMSD_SERVERID.log
  export TIBCOEMS_ServerPort=$1
  export tibemsdata1=$4
  export tibemsdata2=$6

# And persist for all users
  cat >> /etc/profile <<EOF
  export TIBCO_HOME=$TIBCO_HOME
  export TIBEMSD_SERVERID=$TIBEMSD_SERVERID
  export TIBCOEMS_VERSION=$TIBCOEMS_VERSION
  export TIBEMSD_LOGFILE=$TIBEMSD_LOGFILE
  export TIBCOEMS_ServerPort=$1
  export tibemsdata1=$4
  export tibemsdata2=$6
EOF

  echo " EMS version installed is $TIBCOEMS_VERSION"

# if this is a client machine, we are done, and can exit.

  if [ "$client" = 'true' ] ; then
    echo ""
    echo " Configuration of TIBCO Client VM complete"
    exit 0
  else

# call tib-afs-utils.sh to create Azure file share and mount the new file systems
   
  echo " Creating and Mounting new Azure fies shares for TIBCO EMS data"

   /tmp/ems/scripts/tib-afs-util.sh -a $tibemsdata1 -k $5 -c -p -s $tibemsdata1 -b /mnt >tib-afs1.out 2>&1

# check status by seeing if the file share is mounted
   mount1=`df |grep "$tibemsdata1"`
   if [ "$mount1" = "" ] ; then
     echo "Creating file share for the $tibemsdata1 Storage account has failed! Exiting"
     exit 1
   fi

    /tmp/ems/scripts/tib-afs-util.sh -a $tibemsdata2 -k $7 -c -p -s $tibemsdata2 -b /mnt >tib-afs2.out 2>&1

# check status by seeing if the file share is mounted
   mount2=`df |grep "$tibemsdata2"`
   if [ "$mount2" = "" ] ; then
     echo "Creating file share for the $tibemsdata2 Storage account has failed! Exiting"
     exit 1
   fi

# Create logs directory
    mkdir --parents $TIBCO_HOME/ems/"$TIBCOEMS_VERSION"/bin/logs
  
# Check to see if the configuration files have already been updated. Skip if done.

    if [ ! -f "/mnt/$tibemsdata1/tibco/cfgmgmgt/ems/data/stores.conf" ] ; then
# Create shared directory structure (ok if already present)
    mkdir --parents /mnt/$tibemsdata1/tibco/cfgmgmt/ems/data/datastore
    mkdir --parents /mnt/$tibemsdata2/tibco/cfgmgmt/ems/data/datastore

    chown -R tibco:tibco /mnt/$tibemsdata1
    chown -R tibco:tibco /mnt/$tibemsdata2

# Copy installed EMS config files to the first CIFS mount to share with other EMS server
    cp /home/user/tibco/tibco/cfgmgmt/ems/data/*.conf /mnt/$tibemsdata1/tibco/cfgmgmt/ems/data

    cd /mnt/$tibemsdata1/tibco/cfgmgmt/ems/data

# Save original and create new EMS stores.conf
    echo " Configuring TIBCO EMS Stores"
    if [ ! -f stores.orig ]; then
      cp stores.conf stores.orig;
    fi
    rm stores.conf
 
    cat >> stores.conf <<EOF 
  ########################################################################
             
  # stores.conf
   
  ########################################################################
    
  [\$sys.meta]
    type=file
    file=/mnt/$tibemsdata1/tibco/cfgmgmt/ems/data/datastore/meta.db
    mode=async
    file_crc=true
   
  [\$sys.nonfailsafe]
    type=file
    file=/mnt/$tibemsdata1/tibco/cfgmgmt/ems/data/datastore/async-msgs.db
    mode=async
    file_crc=true
  
 [\$sys.failsafe]
    type=file
    file=/mnt/$tibemsdata1/tibco/cfgmgmt/ems/data/datastore/sync-msgs.db
    mode=sync
    file_minimum=2GB
    file_crc=true
  
  [async2]
    type=file
    file=/mnt/$tibemsdata2/tibco/cfgmgmt/ems/data/datastore/async2-msgs.db
    mode=async
    file_crc=true
  
  [sync2]
    type=file
    file=/mnt/$tibemsdata2/tibco/cfgmgmt/ems/data/datastore/sync2-msgs.db
    mode=sync
    file_minimum=2GB
    file_crc=true
    
  ########################################################################
EOF

# Backup original and create TIBCO EMS factories.conf file pointing to EMS Server 1&2 endpoints
    echo " Configuring TIBCO EMS factories"

    if [ ! -f factories.orig ]; then
      cp factories.conf factories.orig;
    fi
    rm factories.conf

    cat >> factories.conf <<EOF
  ######################################################################
  
  # factories.conf
 
  ######################################################################
  
  [ConnectionFactory]
    type                  = generic
    url                   = tcp://$1
  
  [FTConnectionFactory]
    type                  = generic
    url                   = tcp://$2:$1,tcp://$3:$1
    reconnect_attempt_count = 100
    reconnect_attempt_delay = 5000
  
  [SSLFTConnectionFactory]
    type                  = generic
    url                   = ssl://$2:7243,ssl://$3:7243
    ssl_verify_host       = disabled
    reconnect_attempt_count = 100
    reconnect_attempt_delay = 5000
  
  ######################################################################
EOF

  fi

# Prep tibemsd.log file. $TIBCO_HOME is owned by root:root, but EMS service will run as tibco
# and therefore not have permissions to write to the log file without the following
    touch $TIBEMSD_LOGFILE
    chown tibco:tibco $TIBEMSD_LOGFILE

# Configure TIBCO EMS main configuration file
    echo " Configuring the TIBCO EMS main configuration file"
    cd /home/user/tibco/tibco/cfgmgmt/ems/data

# Save backup copy of originally installed conf file
   cp tibemsd.conf tibemsd.conf.orig

   sed -i \
   ` # replace 'logfile = .../logfile' with 'logfile = /opt/tibco/ems/8.x/bin/logs/tibemsdx.log' ` \
                  -e "s|\(logfile\s*=\s*\)\"/home/user/tibco/tibco/cfgmgmt/ems/data/datastore/logfile\"|\1$TIBEMSD_LOGFILE|" \
                  ` # replace '/home/user/tibco' with '/mnt/$tibemsdata1' ` \
                  -e "s|/home/user/tibco|/mnt/$tibemsdata1|g" \
                  -e "s|512MB|2048MB|g" \
                  -e "s|7222|$TIBCOEMS_ServerPort|g" tibemsd.conf

# Add to tibemsd.conf file
   cat >> tibemsd.conf <<EOF

   # Added for Azure Configuration
   server_heartbeat_client = 10
   server_timeout_client_connection = 120
   client_heartbeat_server = 10
   client_timeout_server_connection = 120
   always_exit_on_disk_error = enable
   destination_backlog_swapout = 10000
   log_trace=DEFAULT
   logfile_max_size=100KB
EOF

   if [ "$TIBEMSD_SERVERID" = 1 ] ;then 
     echo "   ft_active = tcp://$3:$TIBCOEMS_ServerPort" >> tibemsd.conf
   else
     echo "   ft_active = tcp://$2:$TIBCOEMS_ServerPort" >> tibemsd.conf
   fi
# Copy to server home
   cp tibemsd.conf $TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin/tibemsd.conf

#convert the TIBEMSd.conf file to a .json file
   $TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin/tibemsconf2json -conf $TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin/tibemsd.conf -json $TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin/tibemsd.json 
 
   echo " Configuration of the EMS Server is complete"

# Create the tibems service script
 
   cat >> /etc/init.d/tibemsd <<EOF
#!/bin/bash
#******************************************************************
#* File:        tibemsd
#* Description: TIBCO Enterprise Messaging Service
#* Usage:       /etc/init.d/tibemsd {start|stop|status|restart}
#*              service tibemsd {start|stop|status|restart}
#* Author:      Richard Flather, TIBCO Messaging Group
#* Date:        April, 2018
#*
#* (C) Copyright TIBCO Software Inc. 2015-18. All rights reserved
#******************************************************************

### BEGIN INIT INFO
# Provides:          tibemsd
# Required-Start:    \$local_fs \$network \$syslog \$rpcbind
# Required-Stop:     \$local_fs \$network \$syslog \$rpcbind
# Default-Start:     3 4 5
# Default-Stop:      0 1 2 6
# Description: 	TIBCO Enterprise Messaging Service
### END INIT INFO

DAEMON=tibemsd
DAEMON_PATH="$TIBCO_HOME/ems/$TIBCOEMS_VERSION/bin"
DAEMON_CONF="\$DAEMON_PATH/tibemsd.json"
DAEMON_OPTS="-config \$DAEMON_CONF -forceStart"
DAEMON_USER=tibco

# Start the service if not already running
start()
{
# Check if already running
PID=\$(pgrep -u \$DAEMON_USER -x \$DAEMON)
if [ \$? -eq "0" ]; then
    printf "\$DAEMON (pid \$PID) already running.\n"
else
# Not running. Spawn the service
    PID=\$(su \$DAEMON_USER -c "\$DAEMON_PATH/\$DAEMON \$DAEMON_OPTS >> /dev/null 2>&1 &")

# Make sure it started
   PID=\$(pgrep -u \$DAEMON_USER -x \$DAEMON)
   if [ \$? -eq "0" ]; then
      printf "Ok \$DAEMON (pid \$PID) started.\n"
   else
      printf "Fail\n"
   fi
fi
}

# Check if service is running
status()
{
PID=\$(pgrep -u \$DAEMON_USER -x \$DAEMON)
if [ \$? -eq "0" ]; then
   printf "\$DAEMON (pid \$PID) is running.\n"
else
   printf "\$DAEMON is not running.\n"
fi
}

# Stop the service if its running
stop()
{
# See if the service is running
PID=\$(pgrep -u \$DAEMON_USER -x \$DAEMON)
if [ \$? -eq "0" ]; then
   kill -2 \$PID
   printf "Ok \$DAEMON (pid \$PID) stopped.\n"
else
   printf "\$DAEMON was not already running.\n"
fi
}

usage()
{
printf "Usage: service \$DAEMON {start|stop|status|restart}\n"
RETVAL=1
}

case "\$1" in
start)
  start;
  RETVAL=\$?
;;
stop)
  stop;
  RETVAL=\$?
;;
status)
  status;
  RETVAL=\$?
;;
restart)
  stop;
  sleep 3
  start;
  RETVAL=\$?
;;
*)
  usage;
  RETVAL=\$?
;;
esac

exit \$RETVAL
EOF
 
  echo " Starting the TIBCO EMS Server" 
# Install and start the service
   chmod 755 /etc/init.d/tibemsd
   chkconfig --add tibemsd
   service tibemsd start

  fi
 fi
fi
