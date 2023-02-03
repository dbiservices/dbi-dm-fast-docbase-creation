#!/bin/bash
# cec@dbi-services.com, August 2022;
# installs the Documentum binaries and creates a docbase;
# the docbase can later be used as a seed and cloned and renamed (see script instantiate_docbase.sh);
# to be executed as ${dctm_owner};
# Usage:
#   ./create_docbase.sh [stem]
# where the optional $stem determines the docbase to be instanciate and whose details are in the global_parameters file;
# e.g.:
#   ./create_docbase.sh bookstore
#   ./create_docbase.sh SEED
# its default value is DCTM0;

stem="$1"

# load global parameters;
# assume the global_parameters file exists in same directory as the current script, which can be called from anywhere;
scripts_dir=$(pwd $(cd $(dirname $0)))
if [ ! -f ${scripts_dir}/global_parameters ]; then
   echo "${scripts_dir}/global_parameters not found, aborting ..."
   exit 1
fi
. ${scripts_dir}/global_parameters "$stem"
if [[ $rc -eq 1 ]]; then
   echo "Aborting ..."
   exit $rc
fi

# download the software;
echo "software downloading ..."
sudo mkdir -p ${dctm_software}
sudo chown ${dctm_owner}:${dctm_owner} ${dctm_software}
cd ${dctm_software}
# the JDK v11;
[[ ! -f ${jdk_package} ]] && wget ${jdk_download_url}/${jdk_package}

if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   # the Oracle Instant Client v21.7 from https://www.oracle.com/ch-de/database/technologies/instant-client/linux-x86-64-downloads.html
   # the CS v22_2 mentions Instant Client 19x but let's use the v21.7 as it is the latest and works too;
   # basic package;
   [[ ! -f ${oracle_ic_basic} ]] && wget ${oracle_download_url}/${oracle_ic_basic}
   # the SQL*Plus Package;
   [[ ! -f ${oracle_ic_sqlplus} ]] && wget ${oracle_download_url}/${oracle_ic_sqlplus}
   # about the exp/imp tools, we could use the ones for the Instant Client but some preliminary tasks may be necessary so they can work against databases with different versions;
   # therefore, to simplify, we will use the exp/imp tools that come with the db and invoke them remotely;
elif [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   if [[ "${postgresql_compile}" == "yes" ]]; then 
      [[ ! -f "${postgresql_package}" ]] && wget ${postgresql_download_url}/$(echo ${postgresql_package} | sed -E "s/postgresql-(.*).tar.gz/\1/")/${postgresql_package}
   elif [[ ! -f "${postgresql_custom_package}" ]]; then
      echo "pre-compiled postgresql tar ball not found, aborting ..."
      exit 1
   fi
   [[ ! -f ${postgresql_jdbc_package} ]] && wget ${jdbc_postgresql_download_url}/${postgresql_jdbc_package}
   # postgres software and database will be embedded with the content server, so no need to export/import anything;
fi

# and the content server from OpenText: download documentum_server_*_linux64_oracle.tar;
# must be done interactively because a login is required;
[[ ! -f ${cs_package} ]] && echo "Please, download the content server tar file into ${dctm_software}"

echo "Downloaded software in ${dctm_software}:"
ls -lrt ${dctm_software}

#if [[ 1 -eq 0 ]]; then
#fi
## testing;
#. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# prepare the installation directory;
echo "creating installation directories..."
sudo mkdir -p ${dctm_root}
sudo chown ${dctm_owner}:${dctm_owner} ${dctm_root}

# place for the docbase binaries and filestores;
mkdir -p ${ACTIVE_ROOT}

# start a custom profile file for the environment of ${ACTIVE_DOCBASE};
cd ${ACTIVE_ROOT}
cat - <<eop > ${ACTIVE_DOCBASE}.env
# set the ${ACTIVE_DOCBASE}'s environment;

export ACTIVE_DOCBASE=${ACTIVE_DOCBASE}
export ACTIVE_ROOT=${ACTIVE_ROOT}

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
eop

# -------------------------------------------------------------------------
# place for the JDK;
echo "installing the latest JDK amazon-corretto-11-x64 ..."
mkdir ${ACTIVE_ROOT}/java
cd ${ACTIVE_ROOT}/java
tar vxf ${dctm_software}/${jdk_package} 2>&1 > /dev/null

# if secure connections to the CS server are not authenticated (i.e. anonymous), remove "anon" from jdk.tls.disabledAlgorithms to re-enable it;
sed -E -i 's/anon,//' ${ACTIVE_ROOT}/java/amazon-corretto-11.*-linux-x64/conf/security/java.security
# explicitly using the non-blocking /dev/urandom is preferable on linux;
sed -E -i 's|(securerandom.source=file:/dev/)random|\1urandom|' ${ACTIVE_ROOT}/java/amazon-corretto-11.*-linux-x64/conf/security/java.security

# append the java stuff in the bash profile file;
cat - <<eop >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# java;
export JAVA_HOME=\${ACTIVE_ROOT}/java/$(ls -1 ${ACTIVE_ROOT}/java/)
export PATH=\${JAVA_HOME}/bin:\$PATH
eop
. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# test the java part;
java -version
# example of output, YMMV depending on the latest downloaded version:
# openjdk version "11.0.16" 2022-07-19 LTS
# OpenJDK Runtime Environment Corretto-11.0.16.8.1 (build 11.0.16+8-LTS)
# OpenJDK 64-Bit Server VM Corretto-11.0.16.8.1 (build 11.0.16+8-LTS, mixed mode)

# -------------------------------------------------------------------------
# prepare the postgres binaries if needed;
# we will use a custom installation instead of a system wide one;
# to this effect, we need to download and compile postgresql so it gets installed in ${ACTIVE_ROOT}/postgresql;
if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   echo "installing the RDBMS ${postgresql_custom_package} ..."
   cd ${ACTIVE_ROOT}
   if [[ ${postgresql_compile} == "yes" ]]; then
      sudo apt install gcc -y; sudo apt install libreadline-dev -y; sudo apt install zlib1g-dev -y; sudo apt install make -y
      tar xvf ${dctm_software}/${postgresql_package} 
      mkdir postgresql
      mk_dir=$(echo ${postgresql_package} | sed -E "s/(postgresql-.*).tar.gz/\1/")
      cd ${mk_dir}
      ./configure --prefix=${ACTIVE_ROOT}/postgresql
      make install
      cd ..; rm -rf ${mk_dir}
      cd postgresql
      mkdir data logs
      tmp_file=$(mktemp); echo ${dctm_password} > ${tmp_file}; bin/initdb --pgdata=${ACTIVE_ROOT}/postgresql/data --username=${dctm_owner} --auth=md5 --pwfile=${tmp_file}; rm ${tmp_file}
      sed -i -E -e "s/^(local[ \t]+all.+)md5$/\1 trust/" -e "s/^(host[ \t]+all.+)(md5)|(ident)$/\1 trust/" ./data/pg_hba.conf
   else
      #tar xvf ${dctm_software}/postgresql-$(echo ${postgresql_custom_package} | sed -E 's/.+-([0-9.]+)\..*$/\1/')_bin.tgz
      tar xvf ${dctm_software}/${postgresql_custom_package}
      cd postgresql
   fi
   sudo apt install odbc-postgresql -y; sudo apt install unixodbc -y
   odbcinst -q -d
   cat - <<eop >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

export POSTGRESQL_HOME=\${ACTIVE_ROOT}/postgresql
export PATH=\${POSTGRESQL_HOME}/bin:\$PATH
export LD_LIBRARY_PATH=\${POSTGRESQL_HOME}/lib:\$LD_LIBRARY_PATH
export LC_ALL=C
eop
   . ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
   # add FileUsage=1 in both ANSI and Unicode postgresql [sections];
   tmp_file=$(mktemp); gawk '{if (match($0, /^\[([^]]+)\]$/, f)) {if (bIn && !bFound) print "FileUsage=1"; bIn = (1 == index(f[1], "PostgreSQL ")); bFound = 0; print} else if ($0) {print; if (bIn && 1 == index($0, "FileUsage")) bFound = 1}else {if (bIn && !bFound) print "FileUsage=1"; bIn = (1 == index(f[1], "PostgreSQL ")); bFound = 0; printf "\n"}} END {if (bIn && !bFound) print "FileUsage=1"}' /etc/odbcinst.ini > ${tmp_file}; sudo mv ${tmp_file} /etc/odbcinst.ini
   odbcinst -q -d -n 'PostgreSQL Unicode'
   # replace the possibly existing [${db_connect_string}] connect string with the current definition;
   tmp=$(mktemp); gawk -v connection_string=${db_connect_string} 'BEGIN {cs_re = "^\\[" connection_string "\\]$"} {if (match($0, cs_re)) while ((getline > 0) && $0 && !match($0, /^[ \t]+$/)); else print}' ~/.odbc.ini > ${tmp}; cat ${tmp}; sudo mv ${tmp} ~/.odbc.ini
   cat - <<eop >> ~/.odbc.ini

[${db_connect_string}]
Description = PostgreSQL connection to ${ACTIVE_DOCBASE}
Driver = PostgreSQL Unicode
Database = ${ACTIVE_DOCBASE}
Servername = ${db_server_host_alias}
UserName = ${dctm_owner}
Port = ${ACTIVE_DB_SERVER_PORT}
Protocol = $(echo ${postgresql_custom_package} | sed -E 's/.+-([0-9]+).*$/\1/')
ReadOnly = No
RowVersioning = No
ShowSystemTables = No
ShowOidColumn = No
FakeOidIndex = No
UpdateableCursors = Yes
eop
   # replace the possibly existing [postgres] connect string with the current definition;
   tmp=$(mktemp); gawk -v connection_string=postgres 'BEGIN {cs_re = "^\\[" connection_string "\\]$"} {if (match($0, cs_re)) while ((getline > 0) && $0 && !match($0, /^[ \t]+$/)); else print}' /etc/odbc.ini > ${tmp}; cat ${tmp}; sudo mv ${tmp} /etc/odbc.ini
   tmp=$(mktemp)
   cat - <<eop >> ${tmp}

[postgres]
Description = PostgreSQL connection to postgres
Driver = PostgreSQL Unicode
Database = postgres
Servername = ${db_server_host_alias}
UserName = ${dctm_owner}
# hard-coded in the server configuration tool;
Port = 5432
eop
   # the following step is required to create the postgresl db at installation time !!!!!
   # private ~/.odbc.ini is used as expected until the installer attempts to effectively create the db, where it switches to the system-wide /etc/odbc.ini;
   # once created, the docbase uses ~/.odbc.ini to connect to the db;
   # replace the possibly existing connect string with the current definition;
   cat ${tmp} | sudo tee -a /etc/odbc.ini
   rm ${tmp}

   odbcinst -q -s -n ${ACTIVE_DOCBASE}

   # use particular tablespaces;
   # db_${ACTIVE_DOCBASE}_dat.dat must exist, otherwise the installer fails;
   mkdir ./data/db_${ACTIVE_DOCBASE}_dat.dat
   mkdir ./data/db_${ACTIVE_DOCBASE}_log.dat

   # tuning PostgreSQL database
   sed -i -E "s/^#(constraint_exclusion)/\1/" ${POSTGRESQL_HOME}/data/postgresql.conf
   cat - <<eoo >> ${POSTGRESQL_HOME}/data/postgresql.conf
temp_buffers = 32MB
work_mem = 32MB
# unrecognized configuration parameter "checkpoint_segments";
#checkpoint_segments = 32
checkpoint_timeout = 10min
checkpoint_completion_target = 0.5
random_page_cost = 2.0
default_statistics_target = 500
maintenance_work_mem = 128MB
shared_buffers = 128MB       # <1/4 times of physical memory>
effective_cache_size = 128MB #<3/4 times of physical memory>
wal_buffers = 16MB
synchronous_commit = off
eoo
   pg_ctl --pgdata=${ACTIVE_ROOT}/postgresql/data --log=${ACTIVE_ROOT}/postgresql/logs/logfile --options="-k /tmp" start
   # check direct connection to postgres process;
   cat - <<eop | psql --host=/tmp postgres
\du
select CURRENT_USER;
SELECT version();
SELECT current_date;
SELECT datname FROM pg_database;
alter user ${dctm_owner} password '${dctm_owner}';
\du
\q
eop
   # test ODBC connection;
   echo quit | isql -v postgres ${dctm_owner}
fi

# -------------------------------------------------------------------------
# Oracle instant client;
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   echo "installing the Oracle Instant Client ${oracle_ic_basic} ..."
   cd ${ACTIVE_ROOT}
   mkdir oracle
   cd oracle
   unzip ${dctm_software}/${oracle_ic_basic}
   unzip ${dctm_software}/${oracle_ic_sqlplus}

   # append the Oracle client stuff in the bash profile file;
   cat - <<eop >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# Oracle instant client;
export ORACLE_HOME=\$(echo \${ACTIVE_ROOT}/oracle/instantclient*)
export TNS_ADMIN=\${ORACLE_HOME}/network/admin
export PATH=\${ORACLE_HOME}:\$PATH
export NLS_LANG=american_america.utf8
export LD_LIBRARY_PATH=\${ORACLE_HOME}:\${LD_LIBRARY_PATH}
eop
   . ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

   # update the SQL*Net configuration files;
#>>>>>>>>>>>
   #cat - <<eoo > ${ACTIVE_ROOT}/oracle/instantclient_*/network/admin/sqlnet.ora
   cat - <<eoo > ${ORACLE_HOME}/network/admin/sqlnet.ora
   NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT)
eoo

   #cat - <<eoo > ${ACTIVE_ROOT}/oracle/instantclient_*/network/admin/tnsnames.ora
   cat - <<eoo > ${ORACLE_HOME}/network/admin/tnsnames.ora
${db_connect_string} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${db_server_host_alias})(PORT = ${db_listener_port}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${db_service_name})
    )
  )
eoo
   # test connection;
   cat - <<eoq | sqlplus ${db_sys_account}/${db_sys_password}@${db_connect_string} as sysdba
set echo on
alter session set nls_date_format = 'dd-mm-yyyy hh24:mi:ss';
select sysdate from dual;
quit
eoq
   # output, your mileage may vary:
   #SQL*Plus: Release 21.0.0.0.0 - Production on Wed Aug 3 19:12:30 2022
   #Version 21.7.0.0.0
   #
   #Copyright (c) 1982, 2022, Oracle.  All rights reserved.
   #
   #Last Successful login time: Tue Aug 02 2022 19:27:09 +02:00
   #
   #Connected to:
   #Oracle Database 12c Enterprise Edition Release 12.1.0.1.0 - 64bit Production
   #With the Partitioning, OLAP, Advanced Analytics and Real Application Testing options
   #
   #SQL>
   #Session altered.
   #
   #SQL>
   #SYSDATE
   #-------------------
   #28-08-2022 09:16:54
   #
   #SQL> Disconnected from Oracle Database 12c Enterprise Edition Release 12.1.0.1.0 - 64bit Production
   #With the Partitioning, OLAP, Advanced Analytics and Real Application Testing options
   
   # creation of the Oracle account for the docbase;
   # we are using here our own test Oracle db; change as needed in your environment;
   echo "creating the ${ACTIVE_DATABASE_OWNER} account and tablespaces in ${db_service_name} ..."
   cat - <<eoq | sqlplus ${db_sys_account}/${db_sys_password}@${db_connect_string} as sysdba
set echo on
create tablespace ${ACTIVE_DOCBASE}_data datafile '${db_datafile_root}/${ACTIVE_DOCBASE}_data.dbf' size 1000K autoextend on online;
create tablespace ${ACTIVE_DOCBASE}_index datafile '${db_datafile_root}/${ACTIVE_DOCBASE}_index.dbf' size 1000K autoextend on online;
create user ${ACTIVE_DATABASE_OWNER} identified by ${ACTIVE_DATABASE_PASSWORD} default tablespace ${ACTIVE_DOCBASE}_data TEMPORARY TABLESPACE temp;
set pagesize 10000
set linesize 200
col TABLESPACE_NAME format a30
select TABLESPACE_NAME, ALLOCATION_TYPE from dba_tablespaces order by 1;
grant CONNECT, RESOURCE, create table, CREATE PROCEDURE, CREATE SEQUENCE, create any view, create view, select_catalog_role to ${ACTIVE_DOCBASE};
alter user ${ACTIVE_DATABASE_OWNER} quota unlimited on ${ACTIVE_DOCBASE}_data;
alter user ${ACTIVE_DATABASE_OWNER} quota unlimited on ${ACTIVE_DOCBASE}_index;

col GRANTEE format a30
select * from dba_sys_privs where grantee in ('${ACTIVE_DATABASE_OWNER}');

col GRANTED_ROLE format a30
select * from dba_role_privs where grantee = '${ACTIVE_DATABASE_OWNER}';

-- test the connection to the new schema and check the visibility of the tbs;
connect ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
set pagesize 10000
set linesize 200
col TABLESPACE_NAME format a30
select TABLESPACE_NAME, ALLOCATION_TYPE, STATUS from user_tablespaces;
quit
eoq
fi

# -------------------------------------------------------------------------
# Documentum binaries;

# update the profile file;
cat - <<eop >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

export DOCUMENTUM=\${ACTIVE_ROOT}/documentum
eop
. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

echo "installing the CS binaries ${cs_package} ..."
# unzip the Documentum binaries;
# cf. example in KB6312380 or in ${DOCUMENTUM}/product/*/install/silent/templates/linux_install.properties;
cd ${ACTIVE_ROOT}
mkdir documentum
mkdir install
cd install
tar xvf ${dctm_software}/${cs_package} 2>&1 > /dev/null
cat - <<eot > installer.properties
INSTALLER_UI=silent
KEEP_TEMP_FILE=true
common.installOwner.password=dmadmin
SERVER.SECURE.ROOT_PASSWORD=root

# documentum binaries;
SERVER.DOCUMENTUM=${ACTIVE_ROOT}/documentum
APPSERVER.SERVER_HTTP_PORT=${ACTIVE_SERVER_HTTP_PORT}
APPSERVER.SECURE.PASSWORD=tomcat

# java;
PATH_TO_JAVA=$(ls -d ${ACTIVE_ROOT}/java/amazon-corretto-11*-linux-x64)
eot

# install the documentum binaries;
# make it executable as OTX forgets sometimes...;
chmod +x ./serverSetup.bin
./serverSetup.bin -f installer.properties

# remove the install directory as it is not required any more; its content can be found in the tar file if needed;
cd ..
rm -rf install

# check db access from dmdbtest;
export LD_LIBRARY_PATH=$(ls -1d ${DOCUMENTUM}/product/*/bin):$LD_LIBRARY_PATH
# not necessary any more in CS 22.4 apparently; or was it a RH thing ?
## required in CS 22.2 or else "liblber-2.4.so.2: cannot open shared object file" error;
#ln -s $(ls -1d ${DOCUMENTUM}/product/*/unsupported/ldap_connect/libs/linux/liblber.so) $(ls -1d ${DOCUMENTUM}/product/*/unsupported/ldap_connect/libs/linux/liblber-2.4.so.2)
#export LD_LIBRARY_PATH=$(ls -1d ${DOCUMENTUM}/product/*/unsupported/ldap_connect/libs/linux):$LD_LIBRARY_PATH
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   ${DOCUMENTUM}/product/*/bin/dmdbtest -Dxx -S${db_connect_string} -U${ACTIVE_DOCBASE} -P${ACTIVE_DOCBASE}
else
   ${DOCUMENTUM}/product/*/bin/dmdbtest -Dpostgres -Spostgres -U${dctm_owner} -Pxxx
fi
# output:
#Database successfully opened.
#Test table successfully created.
#Test view successfully created.
#Test index successfully created.
#Insert into table successfully done.
#Index successfully dropped.
#View successfully dropped.
#Database case sensitivity test successfully past.
#Table successfully dropped.

sed -i '/#!\/bin\/sh/a \\numask 0022' ${DOCUMENTUM}/dba/dm_RunExternalCommand.sh

# run the root taks script to turn on the suid bit on a few executables;
cd ${DOCUMENTUM}/dba
sudo ./dm_root_task_cs16.4

# add the DM_JMS_HOME env. variable;
cat - <<eop >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
export DM_JMS_HOME=$(echo ${DOCUMENTUM}/tomcat*)
export PATH=\$(echo \${DM_JMS_HOME}/bin):\${PATH}

. \${DOCUMENTUM}/product/*/bin/dm_set_server_env.sh

# clean up the environment variables by removing duplicated entries;
function mk_unique() {
   export eval \$1=\$(echo \${!1} | gawk '{nb_paths = split(\$0, paths, ":"); for (i = 1; i <= nb_paths; i++) if (!(paths[i] in tab)) {tab[paths[i]] = 0; ntab[j++] = paths[i]}} END{for (i = 0; i < j; i++) PATH = PATH ":" ntab[i]; print substr(PATH, 2)}')
}

mk_unique PATH
mk_unique LD_LIBRARY_PATH
mk_unique CLASSPATH

export PS1="\[\033[0;32m\]\u@\h:\[\033[36m\][\w][\${ACTIVE_DOCBASE}]\[\033[0m\] $ "
eop
. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
# From doc:
#<<
#Perform the following task, if required, for the Oracle Instant client support: If
#you do not find any bin folder at the database home path where Oracle Instant
#client is installed, you must manually create a bin folder and then copy the
#sqlplus file inside that folder before starting the repository configuration with
#the Oracle Instant client driver.
#>>
# ${ORACLE_HOME}/bin/sqlplus is likely hard-coded here;
# failure to do so will yield the following stupid error:
# ERROR [main] com.documentum.install.server.installanywhere.actions.DiWAServerQueryTablespaceName - The installer is failed to query tablespace name:Failed to execute script.
#>>>>>>>>>>>>>>>>
#mkdir $(ls -d ${ACTIVE_ROOT}/oracle/instantclient_*)/bin
#cd $(ls -d ${ACTIVE_ROOT}/oracle/instantclient_*)/bin
mkdir ${ORACLE_HOME}/bin
cd ${ORACLE_HOME}/bin
ln -s ../sqlplus .
fi

# -------------------------------------------------------------------------
# installation of the docbroker;
cd ${DOCUMENTUM}
cat - <<eot > ../${ACTIVE_DOCBROKER_NAME}.properties
KEEP_TEMP_FILE=true
PATH_TO_JAVA=$(ls -d ${ACTIVE_ROOT}/java/amazon-corretto-11*-linux-x64)

INSTALLER_UI=silent
common.aek.algorithm=AES_128_CBC

# docbroker;
SERVER.CONFIGURATOR.BROKER=TRUE
SERVER.DOCBROKER_ACTION=CREATE
SERVER.DOCBROKER_PORT=${ACTIVE_DOCBROKER_PORT}
SERVER.DOCBROKER_NAME=${ACTIVE_DOCBROKER_NAME}
SERVER.PROJECTED_DOCBROKER_HOST=$(hostname)
SERVER.PROJECTED_DOCBROKER_PORT=${ACTIVE_DOCBROKER_PORT}
SERVER.DOCBROKER_CONNECT_MODE=native
SERVER.USE_CERTIFICATES=false
eot
${DOCUMENTUM}/product/*/install/dm_launch_server_config_program.sh -f ${DOCUMENTUM}/../${ACTIVE_DOCBROKER_NAME}.properties
rm ../${ACTIVE_DOCBROKER_NAME}.properties

# move the directories felix-cache and activemq-data, and the file remote_topology.conf are out of the way when tomcat starts;
sed -i -E "/^echo.+\"Starting Tomcat\"/a cd ${DM_JMS_HOME}/temp" ${DM_JMS_HOME}/bin/startMethodServer.sh

# check;
# ps -ef | grep ${ACTIVE_DOCBROKER_NAME}
# Output:
# ll dba/*${ACTIVE_DOCBROKER_NAME}*
# -rw-rw-r--. 1 dmadmin dmadmin   53 Aug  3 22:04 dba/docbroker.ini
# -rwxrw-rw-. 1 dmadmin dmadmin 2820 Aug  3 22:04 dba/dm_launch_docbroker
# -rwxrw-rw-. 1 dmadmin dmadmin 1364 Aug  3 22:04 dba/dm_stop_docbroker

# leave the docbroker and method server running for they're be used later by the configuration program to create the repository;

# -------------------------------------------------------------------------
# creation of docbase ${ACTIVE_DOCBASE};
# cf. example of configuration in KB6312380 or in ${DOCUMENTUM}/product/*/install/silent/templates/linux_config.properties;
# short version;
echo "creating the ${ACTIVE_DOCBASE} repository ..."

#>>>>>>>>>>
# create a fake ${ACTIVE_DOCBASE} database_owner account to prevent the following error:
# [DM_STARTUP_W_DOCBASE_OWNER_NOT_FOUND] *** warning *** : The database user, XXX as specified by your server.ini is not a valid user as determined using the system password check api.   This will likely severly impair the operation of your docbase.
sudo useradd --password $(perl -e 'print crypt($ARGV[0], "password")' ${ACTIVE_DOCBASE}) --no-create-home --no-user-group --shell /usr/sbin/nologin ${ACTIVE_DOCBASE}

# reserve the port for the ${ACTIVE_DOCBASE}'s service;
echo "======= updating /etc/services ======="
if ! egrep -q "^${ACTIVE_SERVICE_NAME}[ \t]+" /etc/services; then
   cat - <<eos | sudo tee -a /etc/services
${ACTIVE_SERVICE_NAME}           ${ACTIVE_SERVICE_PORT}/tcp               ${ACTIVE_DOCBASE} docbase
${ACTIVE_SERVICE_NAME}_s         $(($ACTIVE_SERVICE_PORT + 1))/tcp        ${ACTIVE_DOCBASE} docbase secure
eos
fi

cd ${ACTIVE_ROOT}
cat - <<eot > ${ACTIVE_DOCBASE}.properties
INSTALLER_UI=silent
KEEP_TEMP_FILE=true
PATH_TO_JAVA=$(ls -d ${ACTIVE_ROOT}/java/amazon-corretto-11*-linux-x64)

############################### docbase stuff #######################################
SERVER.CONFIGURATOR.REPOSITORY=true
SERVER.DOCBASE_ACTION=CREATE
SERVER.DOCBASE_NAME=${ACTIVE_DOCBASE}
SERVER.DOCBASE_ID=${ACTIVE_DOCBASE_ID}
SERVER.DOCBASE_DESCRIPTION=This is the docbase ${ACTIVE_DOCBASE}
SERVER.PROJECTED_DOCBROKER_PORT=${ACTIVE_DOCBROKER_PORT}
SERVER.PROJECTED_DOCBROKER_HOST=$(hostname)
SERVER.TEST_DOCBROKER=true
SERVER.FQDN=$(hostname -f)
SERVER.DOCBASE_SERVICE_NAME=${ACTIVE_SERVICE_NAME}

# aek/lockbox file;
common.use.existing.aek.lockbox = common.create.new
common.aek.key.name=CSaek
common.aek.algorithm=AES_256_CBC
SERVER.ENABLE_LOCKBOX=false

SERVER.DOCUMENTUM_SHARE=${ACTIVE_ROOT}/documentum/share
SERVER.DOCUMENTUM_DATA=${ACTIVE_ROOT}/documentum/data
SERVER.DOCUMENTUM_DATA_FOR_SAN_NAS=false

SERVER.CONNECT_MODE=dual
SERVER.CAS_LICENSE=LDSOPEJPWDQ

############################### database stuff #######################################
SERVER.USE_EXISTING_DATABASE_ACCOUNT=$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "true"; else echo "false"; fi)
$(if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then echo "SERVER.DATABASE_NAME=${ACTIVE_DOCBASE}"; fi)
SERVER.INDEXSPACE_NAME=$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "${ACTIVE_DOCBASE}_INDEX"; else echo "db_${ACTIVE_DOCBASE}_log"; fi)
# postgres is hard-coded in the server configuration script;
SERVER.DATABASE_CONNECTION=$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "${db_connect_string}"; else echo "postgres"; fi)
SERVER.DOCBASE_OWNER_NAME=${ACTIVE_DOCBASE}
SERVER.SECURE.DOCBASE_OWNER_PASSWORD=${ACTIVE_DOCBASE}
SERVER.DATABASE_ADMIN_NAME=$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "${ACTIVE_DOCBASE}"; else echo "${dctm_owner}"; fi)
SERVER.SECURE.DATABASE_ADMIN_PASSWORD=$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "${ACTIVE_DOCBASE}"; else echo "${dctm_password}"; fi)
$(if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then echo "SERVER.POSTGRES_USE_DEFAULT_SPACE=false"; fi)

############################### global_registry stuff #######################################
SERVER.GLOBAL_REGISTRY_SPECIFY_OPTION=USE_THIS_REPOSITORY
SERVER.DFC_BOF_GLOBAL_REGISTRY_VALIDATE_OPTION_IS_SELECTED=true
SERVER.GLOBAL_REGISTRY_REPOSITORY=${ACTIVE_DOCBASE}
SERVER.PROJECTED_DOCBROKER_PORT_OTHER=${ACTIVE_DOCBROKER_PORT}
SERVER.PROJECTED_DOCBROKER_HOST_OTHER=$(hostname)
SERVER.BOF_REGISTRY_USER_LOGIN_NAME=dm_bof_registry
SERVER.SECURE.BOF_REGISTRY_USER_PASSWORD=dm_bof_registry
eot
# no need to start the docbroker and the method server for they are already running from previous step;

# create the docbase;
# follow the logs in ${DOCUMENTUM}/product/*/install/logs/install.log and ${DOCUMENTUM}/dba/log/${ACTIVE_DOCBASE}.log.*;
cd ${DOCUMENTUM}
product/*/install/dm_launch_server_config_program.sh -f ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.properties

rm ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.properties

# rows returned by DQL must be objects, not db rows:
sed -i '/^enforce_four_digit_year.*/a return_top_results_row_based = F' ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini

# symlink to logs;
ln -s ${DOCUMENTUM}/dba/log/$(printf "%08x" ${ACTIVE_DOCBASE_ID}) ${DOCUMENTUM}/dba/log/${ACTIVE_DOCBASE}

# get rid of stupid error "documentum/dba/dm_shutdown_repo05: 65: shopt: not found";
sed -i -E 's|^(#!/bin/)sh|\1bash|' ${DOCUMENTUM}/dba/dm_shutdown_${ACTIVE_DOCBASE}

# shutdown everything documentum and check;
echo "shutting down documentum processes ..."
dm_shutdown_${ACTIVE_DOCBASE} 
dm_stop_${ACTIVE_DOCBROKER_NAME}
stopMethodServer.sh
if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   pg_ctl --pgdata=${ACTIVE_ROOT}/postgresql/data --log=${ACTIVE_ROOT}/postgresql/logs/logfile stop
   # explictly set the dedicated port; valid at the next start;
   sed -i -E "s/^#(port[ \t]*=[ \t]*).+$/\1${ACTIVE_DB_SERVER_PORT}/" ${POSTGRESQL_HOME}/data/postgresql.conf
   # choose the dedicated connect string;
   sed -i -E "s/^(database_conn *= *).+$/\1${ACTIVE_DOCBASE}/" ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini
fi
ps -ef | grep ${ACTIVE_DOCBASE}
ps -ef | grep java

echo "======= creating the switch repository swr script in ~/.profile ======="
if ! grep -a "function swr {" ~/.profile; then
cat - <<eos >> ~/.profile

export dctm_root=${dctm_root}

# alias lsr for LS Repository;
# list the existing, instanciated repositories;
alias lsr='cd ${dctm_root}; ls -ld * | egrep '^d' | sed -E "s/.+ ([^ ]+)$/\1/"'

# SWitch Repository;
# tool to switch between instanciated repositories on the same machine and \${dctm_root};
# stands for Switch to Working Repository;
# it relies on \${dctm_root} defined above, e.g. /u01/dctm;
# it attempts to source \${dctm_root}/\$1/\$1.env if it exists;
# E.g.:
#   /u01/dctm/repo01/repo01.env
#   /u01/dctm/repo01/repo02.env
#   /u01/dctm/myrepo/repo03.env
#   ...
# current working directory is moved to the selected repository's \${DOCUMENTUM};
# Usage:
#    swr [repository_name]
# when invoked without parameters, the currently sourced repository's environment is displayed, without first refreshing it;
#
function swr {
   local repo="\$1"
   if [[ -z "\$repo" ]]; then
      shr
   elif [[ ! -f \${dctm_root}/\${repo}/\${repo}.env ]]; then
      echo "repo \$repo's env file not found, ignoring ..." > /dev/stderr
      return 1
   else
      # reset the variables that are appended to;
      echo "Switching to repository \$repo ..."
      unset CLASSPATH
      unset LD_LIBRARY_PATH
      export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
      . \${dctm_root}/\${repo}/\${repo}.env
      env | grep \${repo} | sort
      shr
      cd \${dctm_root}/\${repo}
   fi
}
eos
fi

#>>>>>>>>>>>>>
echo "======= starting all the existing repositories sura script in ~/.profile ======="
cat - <<eos >> ~/.profile

# function sura, for Start Up Repository All;
# start all the existing, instantiated repositories;
# Usage:
#    sura
#
function sura {
   echo "Starting all the instantiated docbases under \${dctm_root}..."
   cd \$dctm_root
   local f
   for f in \$(ls); do
      echo "found \$f:"
cat - <<eob | bash -l
      swr \$f
      sur \$f
eob
   done
}
eos

echo "======= shutting down all the currently active repository sdra script in ~/.profile ======="
cat - <<eos >> ~/.profile

# function sdra, for Shut Down Repository All;
# shut down all existing, instantiated repositories;
# Usage:
#    sdra
#
function sdra {
   echo "Removing all instantiated docbases under \${dctm_root}..."
   cd \$dctm_root
   local f
   for f in \$(ls); do
      echo "found \$f:"
cat - <<eob | bash -l
      swr \$f
      sdr \$f
eob
   done
}
eos

echo "======= show all the existing repository shra script in ~/.profile ======="
cat - <<eos >> ~/.profile

# function shra, for Show Repository All;
# show all the existing, instantiated repositories;
# Usage:
#    shra
#
function shra {
   echo "Showing all existing docbases under \${dctm_root}..."
   cd \$dctm_root
   local f
   for f in \$(ls); do
      echo "found \$f:"
cat - <<eob | bash -l
      swr \$f
      shr \$f
eob
   done
}
eos

echo "======= display the status of all the existing repository stra script in ~/.profile ======="
cat - <<eos >> ~/.profile

# function stra, for STatus Repository All;
# show the status of all existing, instantiated repositories;
# Usage:
#    stra
#
function stra {
   echo "Showing the status of all existing docbases under \${dctm_root}..."
   cd \$dctm_root
   local f
   for f in \$(ls); do
      echo "found \$f:"
cat - <<eob | bash -l
      swr \$f
      str \$f
eob
   done
}
eos

echo "======= removing all the currently active repository rmra script in ~/.profile ======="
cat - <<eos >> ~/.profile

# function rmra, for RM Repository All;
# remove all existing, instantiated repositories;
# Usage:
#    rmra
#
function rmra {
   echo "Removing all instantiated docbases under \${dctm_root}..."
   cd \$dctm_root
   local f
   for f in \$(ls); do
      echo "found \$f:"
cat - <<eob | bash -l
      swr \$f
      rmr \$f
eob
   done
}
eos

echo "======= showing the currently active repository shr script in ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
export dctm_root=${dctm_root}

# function shr, for SHow Repository;
# displays the currently selected or given repository's info;
# Usage:
#    shr [repo]
# when invoked without parameters, the currently sourced repository's environment is displayed, without first refreshing them;
# when invoked with a parameter, it displays that repository's environment;
#
function shr {
   local repo="\$1"
   local current_docbase=\${ACTIVE_DOCBASE}
   if [[ -z "\$repo" ]]; then
      if [[ -z "\${ACTIVE_DOCBASE}" ]]; then
         echo "There is no selected repository yet, ignoring ..." > /dev/stderr
         return 1
      else
        # display current environment;
        repo=\${ACTIVE_DOCBASE}
      fi
   elif [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      pushd . > /dev/null
      swr \$repo > /dev/null; rc=\$?
      [[ \$rc -ne 0 ]] && return \$rc
   fi
   echo "Repository \$repo's environment is:"
   data=\$(gawk '{if (match(\$0, /^\[DOCBROKER_(.+)\]\$/, f)) name=f[1]; if (match(\$0, /PORT=(.+)\$/, f)) port=f[1]; if (match(\$0, /VERSION=(.+)\$/, f)) version=f[1]; if (match(\$0, /DATABASE_CONN=(.+)\$/, f)) conn=f[1]} END {print name, port, version, conn} ' \${DOCUMENTUM}/dba/dm_documentum_config.txt)
   cat - <<eot
Active docbase name is                  : \${ACTIVE_DOCBASE}
Active docbase id is                    : \$(egrep "^docbase_id = " \${DOCUMENTUM}/dba/config/\${ACTIVE_DOCBASE}/server.ini | cut -d\  -f3)
Active docbase service name is          : \${ACTIVE_DOCBASE}
Active docbase service port is          : \$(grep "^\${ACTIVE_DOCBASE}[ \t]" /etc/services | sed -E "s|.+[ \t]([0-9]+)/.+\$|\1|")
Active docbase host is                  : ${ACTIVE_HOST}
Active docbase version                  : \$(echo \$data | cut -d\  -f3)
Active docbase root directory is        : \${ACTIVE_ROOT}
Active installer owner is               : ${ACTIVE_INSTALL_OWNER}
Active installer password is            : ${ACTIVE_INSTALL_PASSWORD}
Active docbase docbroker name           : \$(echo \$data | cut -d\  -f1)
Active docbase docbroker port           : \$(echo \$data | cut -d\  -f2)
Active docbase http server base port    : \$(grep "Connector Server=\"" \${DOCUMENTUM}/tomcat*/conf/server.xml | sed -E "s|^.+ port=\"([0-9]+)\".+\$|\1|")
Active docbase http server memory       : \$(egrep "CATALINA_OPTS=" \${DOCUMENTUM}/tomcat*/bin/startMethodServer.sh | cut -d= -f2)
JAVA_HOME                               : \${JAVA_HOME}
JAVA_VERSION                            :
\$(java -version 2>&1)
dctm_root                               : \${dctm_root}
Scripts'dir is                          : ${scripts_dir}
CLASSPATH                               : \${CLASSPATH}
DM_HOME                                 : \${DM_HOME}
DOCUMENTUM                              : \${DOCUMENTUM}
DM_JMS_HOME                             : \${DM_JMS_HOME}
PATH                                    : \${PATH}
LD_LIBRARY_PATH                         : \${LD_LIBRARY_PATH}
Active database owner is                : \$(egrep "^database_owner = " \${DOCUMENTUM}/dba/config/\${ACTIVE_DOCBASE}/server.ini | cut -d\  -f3)
Active database password                : ${ACTIVE_DATABASE_PASSWORD}
Active database connection string       : ${db_connect_string}
$(if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then echo "Active database server port             : ${ACTIVE_DB_SERVER_PORT}"; fi)
DATABASE_TYPE                           : \${DATABASE_TYPE}
$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "ORACLE_HOME                             : \${ORACLE_HOME}"; fi)
$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "NLS_LANG                                : \${NLS_LANG}"; fi)
$(if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then echo "TNS_ADMIN                               : \${TNS_ADMIN}"; fi)
eot
   if [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      swr \${current_docbase} > /dev/null && popd 2> /dev/null 1> /dev/null
   fi
}

# alias whr for WHich Repository to show the currently selected repository;
alias whr=shr
eos

echo "======= creating the start up repository sur script in ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# function sur, for StartUp Repository, to start a repository's all processes;
# it depends on function swr above;
# Usage:
#    sur [repository_name]
# when invoked without parameters, the currently selected repository environment is started up;
# when invoked with a parameter, it becomes the current selected repository and its environment is started up;
#
function sur {
   local repo="\$1"
   local current_docbase=\${ACTIVE_DOCBASE}
   [[ ! "\$repo" ]] && repo=\${ACTIVE_DOCBASE}
   if [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      pushd . > /dev/null
      swr \$repo > /dev/null; rc=\$?
      [[ \$rc -ne 0 ]] && return \$rc
   fi
   echo "starting up repository \$repo ..."
eos
if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   echo '   pg_ctl --pgdata=${ACTIVE_ROOT}/postgresql/data --log=${ACTIVE_ROOT}/postgresql/logs/logfile --options="-k /tmp" start' >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
fi
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
   local fs='\[DOCBROKER_(.+)\]$'; local docbroker_name=\$(egrep "\$fs" \${DOCUMENTUM}/dba/dm_documentum_config.txt | sed -E "s/\${fs}/\1/")
   dm_launch_\${docbroker_name}
   dm_start_\${ACTIVE_DOCBASE}
   \${DM_JMS_HOME}/bin/startMethodServer.sh
   [[ \${current_docbase} != \${repo} ]] && swr \${current_docbase} > /dev/null && popd 2> /dev/null 1> /dev/null
}
eos

echo "======= creating the shut down repository sdr script in ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# function sdr, for ShutDown Repository, to stop a repository's all processes;
# it depends on function swr above;
# Usage:
#    sdr [repository_name]
# when invoked without parameters, the currently selected repository environment is shut down;
# when invoked with a parameter, it becomes the current selected repository and its environment is shut down;
#
function sdr {
   local repo="\$1"
   local current_docbase=\${ACTIVE_DOCBASE}
   [[ ! "\$repo" ]] && repo=\${ACTIVE_DOCBASE}
   if [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      pushd . > /dev/null
      swr \$repo > /dev/null; rc=\$?
      [[ \$rc -ne 0 ]] && return \$rc
   fi
   echo "shutting down repository \$repo ..."
   \${DM_JMS_HOME}/bin/stopMethodServer.sh
   dm_shutdown_\${repo}
   local fs='\[DOCBROKER_(.+)\]\$'; local docbroker_name=\$(egrep "\$fs" \${DOCUMENTUM}/dba/dm_documentum_config.txt | sed -E "s/\${fs}/\1/")
   dm_stop_\${docbroker_name}
eos
if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   echo '   pg_ctl --pgdata=${ACTIVE_ROOT}/postgresql/data --log=${repo}/postgresql/logs/logfile --options="-k /tmp" stop' >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
fi
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
   [[ \${current_docbase} != \${repo} ]] && swr \${current_docbase} > /dev/null && popd 2> /dev/null 1> /dev/null
}
eos

echo "======= creating the repository status rst script in ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# function str, for Repository STatus, to show the status of a repository;
# it depends on functions swr;
# Usage:
#    str [repository_name]
# when invoked without parameters, the currently selected repository environment is queried;
# when invoked with a parameter, it becomes the current selected repository and its environment is queried;
#
function str {
   local repo="\$1"
   local current_docbase=\${ACTIVE_DOCBASE}
   [[ ! "\$repo" ]] && repo=\${ACTIVE_DOCBASE}
   if [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      pushd . > /dev/null
      swr \$repo > /dev/null; rc=\$?
      [[ \$rc -ne 0 ]] && return \$rc
   fi
   echo
   echo "status of repository \$repo ..."
   local fs='\[DOCBROKER_(.+)\]$'; local docbroker_name=\$(egrep "\$fs" \${DOCUMENTUM}/dba/dm_documentum_config.txt | sed -E "s/\${fs}/\1/")
   echo "testing the docbroker \${docbroker_name}"
   local docbroker_port=\$(egrep "PORT=" \${DOCUMENTUM}/dba/dm_documentum_config.txt | cut -d= -f2)
   echo "status of docbroker \${docbroker_name} on port \${docbroker_port}"
   if dmqdocbroker -p \${docbroker_port} -c ping 2>&1 > /dev/null; then echo -e "\\e[0;32mthe broker is running\\e[m"; else echo -e "\\e[0;31mthe broker is not running\\e[m"; fi

   echo
   echo "testing connection to repository \${ACTIVE_DOCBASE}"
   iapi -q \${ACTIVE_DOCBASE} -Udmadmin -Pxx
   if [[ \$? -eq 1 ]]; then
      echo -e "\\e[0;31mthe repository is not running\\e[m"
   else
      echo -e "\\e[0;32mthe repository is running\\e[m"
   fi

   local http_server_port=\$(grep "Connector Server=\"" \${DM_JMS_HOME}/conf/server.xml | sed -E "s|^.+ port=\"([0-9]+)\".+\$|\1|")
   echo
   echo "testing method server listening on port \${http_server_port}"
   curl http://localhost:\${http_server_port}/DmMethods/servlet/DoMethod
   curl http://localhost:\${http_server_port}/DmMail/servlet/DoMail
   rc=\$?
   echo
   if [[ \${rc} -eq 0 ]]; then
      echo -e "\\e[0;32mthe method server is running\\e[m"
   else
      echo -e "\\e[0;31mthe method server is not running\\e[m"
   fi
   echo

   [[ \${current_docbase} != \${repo} ]] && swr \${current_docbase} > /dev/null && popd 2> /dev/null 1> /dev/null
}
eos

echo "======= creating the removing repository rmr script in ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="
cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# function rmr, for Remove Repository, to remove a repository by wiping off its working directory;
# it depends on functions swr and uses sdr defined above;
# Usage:
#    rmr [repository_name]
# when invoked without parameters, the currently selected repository environment is removed;
# when invoked with a parameter, it becomes the current selected repository and is removed;
#
function rmr {
   local repo="\$1"
   local current_docbase=\${ACTIVE_DOCBASE}
   [[ ! "\$repo" ]] && repo=\${ACTIVE_DOCBASE}
   if [[ \${ACTIVE_DOCBASE} != \${repo} ]]; then
      pushd . > /dev/null
      swr \$repo > /dev/null; rc=\$?
      [[ \$rc -ne 0 ]] && return \$rc
   fi
   echo "removing repository \$repo ..."
   sdr
   cd \${dctm_root}; rm -rf \${ACTIVE_ROOT} *.log
   sudo sed -i -E "/^\${ACTIVE_DOCBASE}(_s)? /d" /etc/services
   if [[ \${current_docbase} != \${repo} ]]; then
      swr \${current_docbase} > /dev/null
      popd 2> /dev/null 1> /dev/null
   else
      clr
      #export PS1="\[\033[0;32m\]\u@\h:\[\033[36m\][\w][]\[\033[0m\] $ "
   fi
eos

if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
   sshpass -p ${db_server_host_account} scp ${scripts_dir}/rm_user.sh ${db_server_host_account}@${db_server_host_alias}:/tmp/.
#>>>>>>
#cat - <<eoo | sshpass -p ${db_server_host_password} -- ssh ${db_server_host_account}@${db_server_host_alias} 2>&1
#   ~/scripts/rm_user.sh \$repo
#eoo
echo "/tmp/rm_user.sh \$repo" | sshpass -p ${db_server_host_password} -- ssh ${db_server_host_account}@${db_server_host_alias} 2>&1
echo "rm /tmp/rm_user.sh" | sshpass -p ${db_server_host_password} -- ssh ${db_server_host_account}@${db_server_host_alias} 2>&1
eos
fi

cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
}
eos

echo "======= adding aliases to ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env ======="

cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# useful aliases;
# cd to directories of interest;
alias croot='cd ${binaries_root}/dctm'
alias cdroot='cd \${ACTIVE_ROOT}'
alias cdctm='cd \${DOCUMENTUM}'
alias cdba='cd \${DOCUMENTUM}/dba'
alias clog='cd \${DOCUMENTUM}/dba/log'

# view files/logs of interest;
alias lconf='less \${DOCUMENTUM}/dba/config/\${ACTIVE_DOCBASE}/server.ini'
alias llog='less \${DOCUMENTUM}/dba/log/\${ACTIVE_DOCBASE}.log'
alias lcat='less \$DM_JMS_HOME/logs/catalina.out'
alias lms='less \$DM_JMS_HOME/logs/DmMethods.log'

# tail logs of interest;
alias tlog='tail -f \${DOCUMENTUM}/dba/log/\${ACTIVE_DOCBASE}.log'
alias tcat='tail -f \$DM_JMS_HOME/logs/catalina.out'
alias tms='tail -f \$DM_JMS_HOME/logs/DmMethods.log'

# bounced, for bounce Docbase, stop/start the repository;
alias bounced='dm_shutdown_\${ACTIVE_DOCBASE}; dm_start_\${ACTIVE_DOCBASE}'

# bouncedb, for bounce Broker, stop/start the docbroker by minimizing the lost connectivity to the repository;
alias bounceb='n=\$(mktemp -u); mkfifo \$n; ( tail -f \$n | iiapi ) & dm_stop_${ACTIVE_DOCBROKER_NAME}; dm_launch_${ACTIVE_DOCBROKER_NAME}; echo "reinit,c,\${ACTIVE_DOCBASE},T" > \$n; echo "quit" > \$n; rm \$n'

# bouncems, for bounce method server;
alias bouncems='\${DM_JMS_HOME}/bin/stopMethodServer.sh; sleep 5; \${DM_JMS_HOME}/bin/startMethodServer.sh'

# stop & start components;
alias stopr=dm_shutdown_\${ACTIVE_DOCBASE}
alias startr=dm_start_\${ACTIVE_DOCBASE}
alias stopb=dm_stop_${ACTIVE_DOCBROKER_NAME}
alias startb=dm_launch_${ACTIVE_DOCBROKER_NAME}
alias stopms=\${DM_JMS_HOME}/bin/stopMethodServer.sh
alias startms=\${DM_JMS_HOME}/bin/startMethodServer.sh

# interactive utilities;
alias iapi='rlwrap --no-warnings --filter="pipeline simple_macro:pipeto" --ansi-colour-aware --prompt-colour=GREEN --multi-line='__' iapi'
alias idql='rlwrap --no-warnings --filter="pipeline simple_macro:pipeto" --ansi-colour-aware --prompt-colour=GREEN --multi-line='__' idql'
alias iiapi='iapi \${ACTIVE_DOCBASE} -U${ACTIVE_INSTALL_OWNER} -Pxx'
alias iidql='idql \${ACTIVE_DOCBASE} -U${ACTIVE_INSTALL_OWNER} -Pxx'
eos
if [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
      echo "alias isql='rlwrap --no-warnings --filter="pipeline simple_macro:pipeto" --ansi-colour-aware --prompt-colour=GREEN --multi-line='__' isql'"
      echo "alias iisql='isql \${ACTIVE_DOCBASE}'"
      echo "alias psql='rlwrap --no-warnings --filter="pipeline simple_macro:pipeto" --ansi-colour-aware --prompt-colour=GREEN --multi-line='__' \${POSTGRESQL_HOME}/bin/psql'"
      echo "alias ipsql='psql --port=${ACTIVE_DB_SERVER_PORT} --host=/tmp \${ACTIVE_DOCBASE}'"
eos
elif [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
      echo "alias sqlplus='rlwrap --no-warnings --filter="pipeline simple_macro:pipeto" --ansi-colour-aware --prompt-colour=GREEN --multi-line='__' sqlplus'" 
      echo "alias isqlp='sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}'" 
eos
fi

cat - <<eos >> ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# clean up environment from repository references;
# just leave swr and rmra;
alias clr='unset ACTIVE_ROOT DATABASE_TYPE DM_HOME DM_JMS_HOME DOCUMENTUM DOCUMENTUM_SHARED JAVA_HOME ORACLE_HOME TNS_ADMIN dfcpath cdroot cdctm cdba clog lconf llog lcat lms bounced bounceb iiapi iidql isqld psqld sqlp rmr sdr shr str sur; unset CLASSPATH; unset LD_LIBRARY_PATH; export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin; export PS1="\[\033[0;32m\]\u@\h:\[\033[36m\][\w][]\[\033[0m\] $ "'
eos

# -------------------------------------------------------------------------
# take a snapshot of the whole installation, filesystem and database schema;

if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   # first, export the ${ACTIVE_DOCBASE} schema from the db;
   # we could use the data pump but it requires some additional setup on the db server host;
   # we could also use the exp/imp tools in Instant Client 21.7 but some scripts need to be run in the db beforehand, or the stand-alone client tools (e.g. v12.1.x) if still available; 
   # here, for simplicity and generality, we use the exp/imp tools which are always included with the db on its host;
   # use sshpass to work around ssh prompting; less secure but OK in this context;
   # adapt as needed;
   echo "taking a snapshot of repository's data in db ..."
   cat - <<eoc | sshpass -p ${db_server_host_account} ssh ${db_server_host_account}@${db_server_host_alias}
# depending on the db, change to the its character set to get rid of "EXP-00091: Exporting questional statistics" warnings;
work_dir=\$(mktemp --directory)
cd \${work_dir}
export NLS_LANG=american_america.AL32UTF8
# run the exp tool;
exp ${ACTIVE_DOCBASE}/${ACTIVE_DOCBASE}@${db_remote_connect_string} file=${ACTIVE_DOCBASE}.dmp rows=y statistics=compute indexes=y constraints=y grants=y triggers=y consistent=y
# correct strange and illegal value of PCTTHRESHOLD in index-organized tables;
sed -i -E 's|(PCTTHRESHOLD) 0|\1 50|' ${ACTIVE_DOCBASE}.dmp
# mv the dump file to parent dir, i.e. /tmp;
mv ${ACTIVE_DOCBASE}.dmp ../.
cd ..
rm -rf \${work_dir}
eoc
   cd ${ACTIVE_ROOT}
   sshpass -p ${db_server_host_account} scp ${db_server_host_account}@${db_server_host_alias}:/tmp/${ACTIVE_DOCBASE}.dmp .
   cat - <<eoc | sshpass -p ${db_server_host_password} -- ssh ${db_server_host_account}@${db_server_host_alias}
rm /tmp/${ACTIVE_DOCBASE}.dmp
eoc
fi

# next, the filesystem;
# build an exclude file to skip the logs and caches;
echo "taking a snapshot of repository's executables and files ..."
cd ${ACTIVE_ROOT}
echo exclude_files > ${ACTIVE_ROOT}/exclude_files
find -type f -name '*.out' -o -name '*.log' -o -name '*.log.*' -o  -name '*.trc' -o  -name '*.tmp' -o  -name '*.bak' -o  -name '*.bak.*' -o -name '*_trace.txt' | grep -v ${ACTIVE_ROOT}/documentum/data | sed 's/^\.\///' >> ${ACTIVE_ROOT}/exclude_files
find documentum/dba/log/$(printf "%08x" ${ACTIVE_ID})/sysadmin -name '*.txt*' >> ${ACTIVE_ROOT}/exclude_files
find documentum/temp/installer/installlogs -name '*.output' -o -name '*.err' >> ${ACTIVE_ROOT}/exclude_files
find documentum/dba/log -type f >> ${ACTIVE_ROOT}/exclude_files 
find documentum/cache -name seed -type d >> ${ACTIVE_ROOT}/exclude_files
tar --verbose --create --gzip --file ${ACTIVE_DOCBASE}_${ACTIVE_RDBMS}.tgz --exclude-from=${ACTIVE_ROOT}/exclude_files * 2>&1 > /dev/null
rm ${ACTIVE_DOCBASE}.dmp exclude_files 2>/dev/null
if [[ ! -f ${scripts_dir}/${ACTIVE_DOCBASE}_${ACTIVE_RDBMS}.tgz ]]; then
   sudo mv ${ACTIVE_DOCBASE}_${ACTIVE_RDBMS}.tgz ${scripts_dir}/.
else
   echo "target tarball ${scripts_dir}/${ACTIVE_DOCBASE}_${ACTIVE_RDBMS}.tgz already exists, skipping this step..."
fi

# check the files;
cd ${scripts_dir}
ls -lrt
# Output:
#...
#-rwxr-xr-x 1 root    root          5667 Nov 12 16:27 pre-requisites.sh
#-rwxr-xr-x 1 root    root         17879 Nov 12 19:17 create_docbase.sh
#-rwxr-xr-x 1 root    root         29318 Nov 12 19:19 instantiate_docbase.sh
#-rw-r--r-- 1 root    root          5374 Nov 12 19:19 global_parameters
#-rw-rw-r-- 1 dmadmin dmadmin 1780002339 Nov 12 19:50 seed.tgz

# -------------------------------------------------------------------------
# the docbase can now be cloned as many times as needed;
# define the required settings in global_parameters to describe the new instance;
