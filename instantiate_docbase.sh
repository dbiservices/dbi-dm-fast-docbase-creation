#!/bin/bash
# cec@dbi-services, August 2022;
# creation of a docbase instance out of a seed docbase, to be executed as ${dctm_owner};
# this script clones the seed docbase to the unexisting instance ${ACTIVE_DOCBASE} as its installation owner, ${dctm_owner}, possibly on a machine different from the original seed;
# we instanciate a new full installation, including the binaries from the selected RDBMS and ${DOCUMENTUM};
# Usage:
#  instantiate_docbase.sh seed-repo_stem new-repo_stem
# where new-repo_stem is the docbase to instantiate and seed-repo_stem is the model docbase; both are stems whose their details are in the global_parameters file;
# assume the global_parameters file exists in same directory as the current script, which can be called from anywhere;

# check existence of global_parameters file in script's directory;
export scripts_dir=$(pwd $(cd $(dirname $0)))
if [[ ! -f ${scripts_dir}/global_parameters ]]; then
   echo "${scripts_dir}/global_parameters not found, aborting ..."
   exit 1
fi
. ${scripts_dir}/global_parameters "$@"
if [[ $rc -eq 1 ]]; then
   echo "Aborting ..."
   exit $rc
fi
if [[ -z "${SEED_DOCBASE}" || -z "${ACTIVE_DOCBASE}" ]]; then
   echo "One of seed or active docbase's settings are missing"
   echo "Available docbases defined in global_parameters are:"
   echo $(set | egrep "^[^ \t]+_DOCBASE=" | egrep -v "ACTIVE|SEED" | cut -f1 -d_)
   echo "aborting ..."
   exit 1
fi

# check if we are on $dctm_machine;
# docbase creation is always local; if it must be installed remotely, login on there first;
rc=1
if [[ $(hostname) == $dctm_machine || $(hostname --short) == $dctm_machine ]]; then
   rc=0
else
   # $dctm_machine may be an IP address;
   # let's compare it to all the network interfaces' IP address;
   for h in $(hostname -I); do
      if [[ $h == $dctm_machine ]]; then
         rc=0
         break
      fi
   done
fi
if [[ 1 == $rc ]]; then
   echo "not logged on machine $dctm_machine, aborting ..."
   exit 1
fi

# verify that here is no RDBMS mismatch between the seed and the active repositories;
if [[ ${SEED_RDBMS} != ${ACTIVE_RDBMS} ]]; then
   echo "Cannot instantiate the seed docbase ${SEED_DOCBASE} with ${SEED_RDBMS} RDBMS to the docbase ${ACTIVE_DOCBASE} with ${ACTIVE_RDBMS}, aborting ..."
   exit 2
fi

## step-wise troubleshooting;
#if [[ 1 -eq 0 ]]; then

# make sure no to corrupt a pre-existing installation;
if [[ -f ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini ]]; then
   echo "There is already a ${ACTIVE_DOCBASE} docbase configuration file in ${DOCUMENTUM}; please move it and retry; aborting ..."
   exit 1
fi

# create installation directory for the new instance;
mkdir ${ACTIVE_ROOT}
cd ${ACTIVE_ROOT}

echo "======= expanding the seed repository's installation in ${ACTIVE_ROOT} ======="
# copy the docbase installation directory from the seed's tarball;
tar xvf ${scripts_dir}/${SEED_DOCBASE}_${ACTIVE_RDBMS}.tgz 2>&1 > /dev/null
[[ $? -ne 0 ]] && exit 1

echo "======= updating /etc/services ======="
# reserve the port for the ${ACTIVE_DOCBASE}'s service;
if ! egrep -q "^${ACTIVE_SERVICE_NAME}[ \t]+" /etc/services; then
   cat - <<eos | sudo tee -a /etc/services
${ACTIVE_SERVICE_NAME}           ${ACTIVE_SERVICE_PORT}/tcp               ${ACTIVE_DOCBASE} docbase
${ACTIVE_SERVICE_NAME}_s         $(($ACTIVE_SERVICE_PORT + 1))/tcp        ${ACTIVE_DOCBASE} docbase secure
eos
fi

echo "======= adapting references to the seed repository ======="
# change references to the ${SEED_DOCBASE} installation path to the new one, ${ACTIVE_DOCBASE};
# only text files, skip content files;
find ${ACTIVE_ROOT}/documentum -type f \( -exec grep -q "${SEED_ROOT}/documentum" {} \; -a -exec file {} \; \) | grep text | grep -v ${ACTIVE_ROOT}/documentum/data | gawk -v FS=: '{print "\"" $1 "\""}'
xargs --arg-file <(find ${ACTIVE_ROOT}/documentum -type f \( -exec grep -q "${SEED_ROOT}/documentum" {} \; -a -exec file {} \; \) | grep text | grep -v ${ACTIVE_ROOT}/documentum/data | gawk -v FS=: '{print "\"" $1 "\""}') sed -i "s,${SEED_ROOT}/documentum,${ACTIVE_ROOT}/documentum,g"

# adapt the new instance's setting environment's script;
mv ${ACTIVE_ROOT}/${SEED_DOCBASE}.env ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
sed -i -E -e "s/(set the )${SEED_DOCBASE}('s environment)/\1${ACTIVE_DOCBASE}\2/"       \
	  -e "s|^(export ACTIVE_DOCBASE=).+$|\1${ACTIVE_DOCBASE}|"                      \
	  -e "s|^(export ACTIVE_ROOT=).+$|\1${ACTIVE_ROOT}|"                            \
	  -e "s|^(export DM_JMS_HOME=).*|\1$(ls -d ${ACTIVE_ROOT}/documentum/tomcat*)|" \
	  -e "s|(Active database password +: ).+$|\1${ACTIVE_DATABASE_PASSWORD}|"       \
	  -e "s|(Active database connection string +: ).+$|\1${db_connect_string}|"     \
	  -e "s|(reinit,c,)[^,]+(,T)|\1${ACTIVE_DOCBASE}\2|" \
	  -e "s|(alias sqlp='sqlplus ).+$|\1${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}'|" \
	  ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

# reload the profile;
env
. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
env

# re-run the root task;
sudo ${DOCUMENTUM}/dba/dm_root_task_cs16.4

# adapt the docbroker's name and port;
if [[ ${SEED_DOCBROKER_NAME} != ${ACTIVE_DOCBROKER_NAME} ]]; then
   mv ${DOCUMENTUM}/dba/${SEED_DOCBROKER_NAME}.ini ${DOCUMENTUM}/dba/${ACTIVE_DOCBROKER_NAME}.ini
   mv ${DOCUMENTUM}/dba/dm_launch_${SEED_DOCBROKER_NAME} ${DOCUMENTUM}/dba/dm_launch_${ACTIVE_DOCBROKER_NAME}
   mv ${DOCUMENTUM}/dba/dm_stop_${SEED_DOCBROKER_NAME} ${DOCUMENTUM}/dba/dm_stop_${ACTIVE_DOCBROKER_NAME}
fi
sed -i -E -e "s|/${SEED_DOCBROKER_NAME}|/${ACTIVE_DOCBROKER_NAME}|" -e "s|${SEED_DOCBROKER_PORT}|${ACTIVE_DOCBROKER_PORT}|" -e "s|^(host=)${SEED_HOST}.*$|\1$(hostname -A)|" ${DOCUMENTUM}/dba/dm_launch_${ACTIVE_DOCBROKER_NAME}
sed -i -E -e "s|(-P -N)${SEED_DOCBROKER_PORT} |\1${ACTIVE_DOCBROKER_PORT} |" -e "s|(\"-port )${SEED_DOCBROKER_PORT}\"|\1${ACTIVE_DOCBROKER_PORT}\"|" ${DOCUMENTUM}/dba/dm_stop_${ACTIVE_DOCBROKER_NAME}
sed -i -E -e "s|^(\[DOCBROKER_)[^]]+(\])$|\1${ACTIVE_DOCBROKER_NAME}\2|" -e "s|(NAME=)docbroker.*$|\1${ACTIVE_DOCBROKER_NAME}|" -e "s|^(PORT=).*$|\1${ACTIVE_DOCBROKER_PORT}|" ${DOCUMENTUM}/dba/dm_documentum_config.txt
sed -i -E -e "s|^(dfc.docbroker.host\[0\]=).*$|\1$(hostname -A)|" -e "s|(dfc.docbroker.port\[0\]=).*$|\1${ACTIVE_DOCBROKER_PORT}|" ${DOCUMENTUM}/config/dfc.properties

# update the server.ini with the new docbroker's targets;
tmp_file=$(mktemp)
gawk -v docbroker_host=${dctm_machine} -v docbroker_domain=${dctm_domain} -v docbroker_port=${ACTIVE_DOCBROKER_PORT} '{
   print
   if (match($0, /\[DOCBROKER_PROJECTION_TARGET\]/)) {
      getline
      printf("host = %s.%s\n", docbroker_host, docbroker_domain)
      getline
      printf("port = %s\n", docbroker_port)
   }
}' ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini > ${tmp_file}
mv ${tmp_file} ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini

# rebase the method server's ports;
sed -i -E "s|( port=\")${SEED_SERVER_HTTP_PORT}\" |\1${ACTIVE_SERVER_HTTP_PORT}\" |" ${DM_JMS_HOME}/conf/server.xml
tmp_file=$(mktemp)
gawk -v old_base_ttp_port=${SEED_SERVER_HTTP_PORT} -v base_http_port=${ACTIVE_SERVER_HTTP_PORT} -v FS="=" '{
   if (match($0, /^(.+)(<Server port=")([0-9]+)(".+)$/, m)) {
      # update the shut down port;
      print m[1] m[2] m[3] - old_base_ttp_port + base_http_port m[4]
   }
   else if (match($0, /^(.+brokerURL=".+:)([0-9]+)(".+)$/, m)) {
      # update the ActibeMQBroker port;
      print m[1] m[2] - old_base_ttp_port + base_http_port m[3]
   }
   else print	
}' ${DM_JMS_HOME}/conf/server.xml > ${tmp_file}
mv ${tmp_file} ${DM_JMS_HOME}/conf/server.xml

tmp_file=$(mktemp)
gawk -v old_base_ttp_port=${SEED_SERVER_HTTP_PORT} -v base_http_port=${ACTIVE_SERVER_HTTP_PORT} -v FS="=" '{
   if (match($0, /^(jms.url=tcp.+:)([0-9]+)$/, m)) {
      # update the acs port;
      print m[1] m[2] - old_base_ttp_port + base_http_port
   }
   else print	
}' ${DM_JMS_HOME}/webapps/ACS/WEB-INF/classes/config/acs.properties > ${tmp_file}
mv ${tmp_file} ${DM_JMS_HOME}/webapps/ACS/WEB-INF/classes/config/acs.properties

tmp_file=$(mktemp)
gawk -v base_http_port=${ACTIVE_SERVER_HTTP_PORT} -v FS="=" '{
   if (match($0, /^#/))
      print
   else if ("LISTEN_PORT" == $1) {
      old_base = $2
      print "LISTEN_PORT=" base_http_port
   }
   else
      print $1 "=" $2 - old_base + base_http_port
}' ${DM_JMS_HOME}/server/DctmServer_MethodServer/configuration/dctm.properties > ${tmp_file}
mv ${tmp_file} ${DM_JMS_HOME}/server/DctmServer_MethodServer/configuration/dctm.properties

# edit the memory settings;
sed -i -E -e "s|(export CATALINA_OPTS=\")[^\"]+(\")|\1${ACTIVE_SERVER_HTTP_MEMORY}\2|" ${DM_JMS_HOME}/bin/startMethodServer.sh
sed -i -E -e "s|(export CATALINA_OPTS=\")[^\"]+(\")|\1${ACTIVE_SERVER_HTTP_MEMORY}\2|" ${DM_JMS_HOME}/bin/stopMethodServer.sh

# correct symlink to docbase log directory;
rm ${DOCUMENTUM}/dba/log/${SEED_DOCBASE}
ln -s ${DOCUMENTUM}/dba/log/$(printf "%08x" ${ACTIVE_DOCBASE_ID}) ${DOCUMENTUM}/dba/log/${ACTIVE_DOCBASE}

echo "======= adapting JAVA_LINK symlink ======="
# correct the JAVA_LINK symlink;
cd ${ACTIVE_ROOT}/documentum/java64
rm JAVA_LINK
ln -s ${ACTIVE_ROOT}/java/amazon-corretto-11.*-linux-x64 JAVA_LINK

if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   # update the SQL*Net configuration files;
   cat - <<eoo > ${ACTIVE_ROOT}/oracle/instantclient_21_7/network/admin/tnsnames.ora
${db_connect_string} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = ${db_server_host_alias})(PORT = ${db_listener_port}))
    (CONNECT_DATA =
      (SERVER = DEDICATED)
      (SERVICE_NAME = ${db_service_name})
    )
  )
eoo
   echo "======= creating the instance's schema in db ======="
   # clone the database schema into ${ACTIVE_DOCBASE};
   # adapt the datafile paths accordingly;
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
col PRIVILEGE format a30
select * from dba_sys_privs where grantee in upper('${ACTIVE_DATABASE_OWNER}');

col GRANTED_ROLE format a30
select * from dba_role_privs where grantee = upper('${ACTIVE_DATABASE_OWNER}');

-- check the visibility of the tbs;
connect ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
select TABLESPACE_NAME, STATUS, ALLOCATION_TYPE, SEGMENT_SPACE_MANAGEMENT from user_tablespaces;
quit
eoq
   # example of output;
   #select TABLESPACE_NAME, ALLOCATION_TYPE from dba_tablespaces order by 1;
   #TABLESPACE_NAME          ALLOCATION_TYPE
   #------------------------------ ---------------------------
   #DCTM1_DATA            SYSTEM
   #DCTM1_INDEX           SYSTEM
   #...
   #SEED_DATA             SYSTEM
   #SEED_INDEX            SYSTEM
   #
   #SQL> select privilege from dba_sys_privs where grantee = upper('dctm1');
   #GRANTEE                        PRIVILEGE                      ADMIN_OPT COMMON
   #------------------------------ ------------------------------ --------- ---------
   #DCTM1                          CREATE VIEW                    NO        NO
   #DCTM1                          CREATE ANY VIEW                NO        NO
   #DCTM1                          CREATE SEQUENCE                NO        NO
   #DCTM1                          CREATE PROCEDURE               NO        NO
   #DCTM1                          CREATE TABLE                   NO        NO
   #
   #SQL> select * from dba_role_privs where grantee = upper('dctm1');
   #GRANTEE                        GRANTED_ROLE                   ADMIN_OPT DEFAULT_R COMMON
   #------------------------------ ------------------------------ --------- --------- ---------
   #DCTM1                          CONNECT                        NO        YES       NO
   #DCTM1                          RESOURCE                       NO        YES       NO
   #DCTM1                          SELECT_CATALOG_ROLE            NO        YES       NO
   #
   #SQL> select TABLESPACE_NAME, STATUS, ALLOCATION_TYPE, SEGMENT_SPACE_MANAGEMENT from user_tablespaces;
   #TABLESPACE_NAME                STATUS                      ALLOCATION_TYPE             SEGMENT_SPACE_MANA
   #------------------------------ --------------------------- --------------------------- ------------------
   #DCTM1_DATA                     ONLINE                      SYSTEM                      AUTO
   #DCTM1_INDEX                    ONLINE                      SYSTEM                      AUTO
   
   # export/import the schema from the seed one to the ${ACTIVE_DOCBASE} one;
   # we could use the data pump but it requires some additional setup;
   # let's use the imp/exp utilities v12.1.0.1 on the db host;
   # export the seed's schema;
   # change to the db's character set to get rid of "EXP-00091: Exporting questional statistics" warnings;
   # as dmadmin is sudoer root, it can become the local user oracle and as oracle has copied its rsa public key to $db_server_host_alias, it can login passwordless;
   # your mileage may vary (e.g. no local oracl account, local db, etc...), adapt as needed;
   echo "======= cloning the db schema ======="
   # first, upload the dump file, randomize its name to allow concurrency;
   seed_dmp_file=${SEED_DOCBASE}-${RANDOM}.dmp
   sshpass -p ${db_server_host_password} scp ${ACTIVE_ROOT}/${SEED_DOCBASE}.dmp ${db_server_host_account}@${db_server_host_alias}:/tmp/${seed_dmp_file}

   # next, edit it to the new schema;
   cat - <<eos | sshpass -p ${db_server_host_password} -- ssh ${db_server_host_account}@${db_server_host_alias} 2>&1
work_dir=\$(mktemp --directory)
cd \${work_dir}
mv /tmp/${seed_dmp_file} .
export SEED_DOCBASE=${SEED_DOCBASE}
export ACTIVE_DOCBASE=${ACTIVE_DOCBASE}
export db_connect_string=${db_connect_string}
export NLS_LANG=american_america.AL32UTF8
# relocate the objects to ${ACTIVE_DOCBASE}'s tablespace;
export upper_seed_docbase=${SEED_DOCBASE^^}
echo \${upper_seed_docbase}
export upper_active_docbase=${ACTIVE_DOCBASE^^}
echo \${upper_active_docbase}
env | sort
echo sed -i "s/TABLESPACE \\"\${upper_seed_docbase}_DATA\\"/TABLESPACE \\"\${upper_active_docbase}_DATA\\"/g" ${seed_dmp_file}
sed -i "s/TABLESPACE \\"\${upper_seed_docbase}_DATA\\"/TABLESPACE \\"\${upper_active_docbase}_DATA\\"/g" ${seed_dmp_file}
echo \$?
sed -i "s/TABLESPACE \\"\${upper_seed_docbase}_INDEX\\"/TABLESPACE \\"\${upper_active_docbase}_INDEX\\"/g" ${seed_dmp_file}
echo \$?
sed -i "s/FROM ${SEED_DOCBASE}\\./FROM ${ACTIVE_DOCBASE}\\./g" ${seed_dmp_file}
echo \$?
sed -i "s/,${SEED_DOCBASE}\\./,${ACTIVE_DOCBASE}\\./g" ${seed_dmp_file}
echo \$?

# import the seed's schema into ${ACTIVE_DOCBASE};
# ignore the errors while creating the views; we'll take care of them next;
# correct strange and illegal value of PCTTHRESHOLD in index-organized tables;
sed -i -E 's|(PCTTHRESHOLD) 0|\1 50|' ${ACTIVE_DOCBASE}.dmp
imp ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_remote_connect_string} file=${seed_dmp_file} fromuser=${SEED_DATABASE_OWNER} touser=${ACTIVE_DATABASE_OWNER} rows=y indexes=y constraints=y grants=y ignore=y BUFFER=2000000

# extract the view creation statements from export file and create the views;
echo "set echo on" > create_views.sql
strings ${seed_dmp_file} | sed -r 's/^[ \t\$]*(\(*)(SELECT)(.+)/\1\2\3/I' | gawk '{if (sub(/^CREATE VIEW /, "CREATE or REPLACE VIEW ", \$0)) {print; getline; pos = 2000; if (length(\$0) > pos) {while (substr(\$0, --pos, 1) != ","); print substr(\$0, 1, pos); print substr(\$0, pos + 1)}else print; print "/"}}END{print "quit"}' >> create_views.sql
# count the views to be created;
grep "CREATE or REPLACE VIEW" create_views.sql | wc -l
# 977 in CS 22.2;
# 983 in CS 22.4;
# create the views;
sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_remote_connect_string} @create_views.sql
cd ..
rm -r \${work_dir}
eos
   rm ${ACTIVE_ROOT}/${SEED_DOCBASE}.dmp

   # count the created views;
   cat - <<eoq | sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
set echo on
select count(*) from user_views;
quit
eoq
   # output:
   #  COUNT(*)
   #----------
   #       977

   # recompile all the schema objects, typically invalid views;
   cat - <<eoq | sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
set echo on
execute dbms_utility.compile_schema(upper('${ACTIVE_DATABASE_OWNER}'), TRUE, FALSE);
quit
eoq
   # output:
   #PL/SQL procedure successfully completed.

   # check the objects' status;
   cat - <<eoq | sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
set echo on
set pagesize 10000
set linesize 100
col object_name format a30
col object_type format a30
select object_name, object_type from user_objects where status = 'INVALID';
select object_name, object_type, status from user_objects;
quit
eoq
   # output:
   #no rows selected
   #OBJECT_NAME                    OBJECT_TYPE                    STATUS
   #------------------------------ ------------------------------ -------
   #D_1F00271080000195             INDEX                          VALID
   #D_1F00271080000241             INDEX                          VALID
   #DMI_CHANGE_RECORD_S            TABLE                          VALID
   #D_1F002710800001A8             INDEX                          VALID
   #DMI_DD_ATTR_INFO_R             TABLE                          VALID
   #...
   #DM_INDEXES                     VIEW                           VALID
   #DM_RESYNC_DD_ATTR_INFO         VIEW                           VALID
   #DM_RESYNC_DD_TYPE_INFO         VIEW                           VALID
   #DMI_DD_ATTR_INFO_DDEN          VIEW                           VALID
   #
   #1931 rows selected.

   echo "======= refreshing the db statistics ======="
   # refresh the schema's statistics;
   # the job UpdateStats will do it later anyway;
   cat - <<eoq | sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}
set echo on
execute dbms_stats.gather_schema_stats(ownname => '${ACTIVE_DATABASE_OWNER}');
quit
eoq
   # output:
   #PL/SQL procedure successfully completed.
   sed -E -i -e "s/(database_owner *= *).+$/\1${ACTIVE_DOCBASE}/" ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini
else
   # postgresql;
   # so much simpler because the db is embeded now, binaries and data !
   cd ${ACTIVE_ROOT}/postgresql
   # explictly set the custom db port;
   sed -i -E "s/^#?(port[ \t]*=[ \t]*).+$/\1${ACTIVE_DB_SERVER_PORT}/" ./data/postgresql.conf
   # correct symlink to data tablespace in postgresql;
   cd ./data/pg_tblspc
   ls -lrt
   link=$(ls -l | grep -- '->' | sed -E "s/^.+ (.+) -> .+$/\1/")
   echo $link
   dest=$(ls -l | grep -- '->' | sed -E "s/^.+-> (.+)$/\1/")
   echo $dest
   rm ${link}
   ln -s $(echo ${dest} | sed -E "s|${SEED_DOCBASE}(/postgresql)|${ACTIVE_DOCBASE}\1|") $link
   ls -lrt
   pg_ctl --pgdata=${ACTIVE_ROOT}/postgresql/data --log=${ACTIVE_ROOT}/postgresql/logs/logfile --options="-k /tmp" start
   # adjust the postgres database for the new docbase;
   cat - <<eop | psql --port=${ACTIVE_DB_SERVER_PORT} --host=/tmp postgres
SELECT datname FROM pg_database;
\du
\connect ${SEED_DOCBASE}
alter schema ${SEED_DOCBASE} rename to ${ACTIVE_DOCBASE};
\connect postgres
alter database ${SEED_DOCBASE} rename to ${ACTIVE_DOCBASE};
alter user ${SEED_DATABASE_OWNER} rename to ${ACTIVE_DATABASE_OWNER};
alter user ${ACTIVE_DATABASE_OWNER} password '${ACTIVE_DATABASE_PASSWORD}';
alter user ${ACTIVE_DATABASE_OWNER} set search_path = ${ACTIVE_DATABASE_OWNER};
\connect ${ACTIVE_DOCBASE} ${ACTIVE_DATABASE_OWNER}
\du
select CURRENT_USER;
SELECT version();
SELECT current_date;
SELECT datname FROM pg_database;
select
    nsp.nspname as SchemaName
    ,cls.relname as ObjectName, length(cls.relname) as Len
    ,rol.rolname as ObjectOwner
    ,case cls.relkind
        when 'r' then 'TABLE'
        when 'm' then 'MATERIALIZED_VIEW'
        when 'i' then 'INDEX'
        when 'S' then 'SEQUENCE'
        when 'v' then 'VIEW'
        when 'c' then 'TYPE'
        else cls.relkind::text
    end as ObjectType
from pg_class cls
join pg_roles rol
	on rol.oid = cls.relowner
join pg_namespace nsp
	on nsp.oid = cls.relnamespace
where nsp.nspname not in ('information_schema', 'pg_catalog')
    and nsp.nspname not like 'pg_toast%'
order by nsp.nspname, cls.relname;
\q
eop
   # replace the possibly existing [postgres] connect string with the current definition;
   # remove the same pre-existing connect string;
#>>>>>>>>>>>>>>
# critical section here, to be corrected;
   tmp=$(mktemp); gawk -v connection_string="(${db_connect_string}|postgres)" 'BEGIN {cs_re = "^\\[" connection_string "\\]$"} {if (match($0, cs_re)) while ((getline > 0) && $0 && !match($0, /^[ \t]+$/)); else print}' ~/.odbc.ini > ${tmp}; cat ${tmp}; sudo mv ${tmp} ~/.odbc.ini
   # append the up-to-date connect string;
   cat - <<eop >> ~/.odbc.ini

[${ACTIVE_DOCBASE}]
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
   # test ODBC connection, still trusted;
   echo quit | isql -v ${ACTIVE_DOCBASE}
   # set the dedicated connect string;
   #sed -E -i -e "s/(docbase_name = ).+$/\1${ACTIVE_DOCBASE}/" -e "s/(database_name = ).+$/\1${ACTIVE_DOCBASE}/" -e "s/(database_owner = ).+$/\1${ACTIVE_DOCBASE}/" ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini
   sed -E -i -e "s/(database_name *= *).+$/\1${ACTIVE_DOCBASE}/" -e "s/(database_conn *= *).+$/\1${ACTIVE_DOCBASE}/" -e "s/(database_owner *= *).+$/\1${ACTIVE_DOCBASE}/" ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini
   #sed -E -i -e "s/(database_name = ).+$/\1${ACTIVE_DOCBASE}/" -e "s/(database_conn = ).+$/\1${ACTIVE_DOCBASE}/" ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini
fi

## troubleshooting;
#fi
#. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env

echo "======= changing the schema's password for the new repository ======="
# synchronize the db's schema password into the password file;
# it is still the ${SEED_DOCBASE}'s one because the password file in ${DOCUMENTUM}/dba/config/${SEED_DOCBASE} was copied from the seed docbase;
dm_encrypt_password -docbase ${SEED_DOCBASE} -rdbms -encrypt ${ACTIVE_DATABASE_PASSWORD} -keyname CSaek
echo "======= testing connection to db using the new password ======="
# test connectivity to db using the docbase info and the new password;
dmdbtest -docbase_name ${SEED_DOCBASE} -init_file ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini
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

# at this point, we have only moved the seed docbase to another base directory but its name is still ${SEED_DOCBASE} and its content is the same;
# let's rename it to ${ACTIVE_DOCBASE} and change its ID to ${ACTIVE_DOCBASE_ID}; these are the minimum tasks after cloning the ${SEED_DOCBASE} docbase;
# we will use the Documentum's migration utility MigrationUtil;
echo "======= preparing the migration utility's configuration ======="
# prepare the utility's configuration;
cd ${DM_HOME}/install/external_apps/MigrationUtil
cp config.xml config.xml_saved

# choice of RDBMS and connection info;
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   port_number=${db_listener_port}
else
   port_number=${ACTIVE_DB_SERVER_PORT}
fi
sed -i -E -e "s/(key=\"dbms\">)[^<]+</\1${ACTIVE_RDBMS}</" -e "s/(key=\"tgt_database_server\">)[^<]+</\1${db_server_host_alias}</" -e "s/(key=\"port_number\">)[^<]+</\1${port_number}</" -e "s/(key=\"InstallOwnerPassword\">)[^<]+</\1${dctm_password}</" config.xml

# change of password;
sed -i -E -e "s/(key=\"DocbaseName.1\">)[^<]+</\1${SEED_DOCBASE}</" -e "s/(key=\"DocbasePassword.1\">)[^<]+</\1${ACTIVE_DATABASE_PASSWORD}</" config.xml

# change docbase id and name;
sed -i -E -e 's|(key="ChangeDocbaseID">)[^<]+<|\1yes<|' -e "s|(key=\"Docbase_name\">)[^<]+<|\1${SEED_DOCBASE}<|" -e "s/(key=\"NewDocbaseID\">)[^<]+</\1${ACTIVE_DOCBASE_ID}</" config.xml

# change server name;
sed -i -E -e 's|(key=\"ChangeServerName\">)[^<]+<|\1yes<|' -e "s/(key=\"NewServerName.1\">)[^<]+</\1${ACTIVE_DOCBASE}</" -e "s/(key=\"NewDocbaseName.1\">)[^<]+</\1${ACTIVE_DOCBASE}</" config.xml

# current installation host different from seed's ?
if [[ ${dctm_machine} != ${SEED_HOST} ]]; then
   sed -i -E -e "s|(key=\"ChangeHostName\">)[^<]+<|\1yes<|" -e "s|(key=\"HostName\">)[^<]+<|\1${dctm_machine}<|" -e "s|(key=\"NewHostName\">)[^<]+<|\1${dctm_machine}<|" config.xml
else
   sed -i -E -e "s|(key=\"ChangeHostName\">)[^<]+<|\1no<|" config.xml
fi
# current installation owner different from the seed's ?
if [[ ${dctm_owner} != ${SEED_INSTALL_OWNER} ]]; then
   sed -i -E -e "s|(key=\"ChangeInstallOwner\">)[^<]+<|\1yes<|" -e "s|(key=\"InstallOwner\">)[^<]+<|\1${SEED_INSTALL_OWNER}<|" -e "s|(key=\"NewInstallOwner\">)[^<]+<|${dctm_owner}<|" -e "s|(key=\"NewInstallOwnerPassword\">)[^<]+<|${dctm_password}<|" config.xml
else
   sed -i -E -e "s|(key=\"ChangeInstallOwner\">)[^<]+<|\1no<|" config.xml
fi
sed -i -E -e "s|(key=\"DockerSeamlessUpgrade\">)[^<]+<|\1no<|" config.xml

# example of customized config.xml:
#cat config.xml
#<<
#<?xml version="1.0" encoding="UTF-8"?>
#<!DOCTYPE properties SYSTEM "http://java.sun.com/dtd/properties.dtd">
#<properties>
#<comment>Database connection details</comment>
# before:
#<entry key="dbms"> </entry> <!-- This would be either sqlserver, oracle, db2 or postgres -->
#<entry key="tgt_database_server">database_server</entry> <!-- Database Server host or IP -->
#<entry key="port_number">Database_port</entry> <!-- Database port number -->
#<entry key="InstallOwnerPassword">Install Owner Password</entry>
# after:
#<entry key="dbms">oracle</entry> <!-- This would be either sqlserver, oracle, db2 or postgres -->
#<entry key="tgt_database_server">db</entry> <!-- Database Server host or IP -->
#<entry key="port_number">1521</entry> <!-- Database port number -->
#<entry key="InstallOwnerPassword">dmadmin</entry>

#<entry key="isRCS">no</entry>    <!-- set it to yes, when running the utility on secondary CS -->
#<entry key="TomcatPath"></entry> <!-- Optional. set it to appropriate tomcat path if DM_JMS_HOME environment variable is not set -->
#
#<!-- <comment>List of docbases in the machine</comment> -->
# before:
#<entry key="DocbaseName.1">Docbase1</entry>
#after:
#<entry key="DocbaseName.1">seed</entry>

#<entry key="DocbaseName.2">Docbase2</entry>
#<entry key="DocbaseName.3"></entry>
#
#<!-- <comment>docbase owner password</comment> -->
# before:
# <entry key="DocbasePassword.1">Docbase owner password1</entry>
# after:
#<entry key="DocbasePassword.1">dctm1</entry>

#<entry key="DocbasePassword.2">Docbase owner password2</entry>
#<entry key="DocbasePassword.3"></entry>
#
# before:
# <entry key="ChangeDocbaseID">yes</entry> <!-- To change docbase ID or not -->
#  <entry key="Docbase_name">Docbase name</entry> <!-- has to match with DocbaseName.1 -->
# <entry key="NewDocbaseID">Target Docbase ID</entry> <!-- New docbase ID -->
# after:
#<entry key="ChangeDocbaseID">yes</entry> <!-- To change docbase ID or not -->
#<entry key="Docbase_name">seed</entry> <!-- has to match with DocbaseName.1 -->
#<entry key="NewDocbaseID">50000</entry> <!-- New docbase ID -->
#
# before:
# <entry key="ChangeServerName">yes</entry>
# <entry key="NewServerName.1">New Server name1</entry>
# after:
#<entry key="ChangeServerName">yes</entry>
#<entry key="NewServerName.1">dctm1</entry>

#<entry key="NewServerName.2"> </entry>
#
# before:
#<entry key="ChangeDocbaseName">yes</entry>
#<entry key="NewDocbaseName.1">New Docbase1</entry>
# after:
#<entry key="ChangeDocbaseName">yes</entry>
#<entry key="NewDocbaseName.1">dctm1</entry>

#<entry key="NewDocbaseName.2"> </entry>
#
# before:
# <entry key="ChangeHostName">yes</entry>
# after:
#<entry key="ChangeHostName">no</entry>

#<entry key="HostName">Old Host name </entry>
#<entry key="NewHostName">New Host name </entry>
#
# before:
# <entry key="ChangeInstallOwner">yes</entry>
# after:
#<entry key="ChangeInstallOwner">no</entry>

#<entry key="InstallOwner">Old Install Owner </entry>
#<entry key="NewInstallOwner"> New Install Owner </entry>
#<entry key="NewInstallOwnerPassword">New Install Owner password </entry>
#
# before:
# <entry key="DockerSeamlessUpgrade">yes</entry>
# after:
#<entry key="DockerSeamlessUpgrade">no</entry>

#<entry key="PrimaryHost">Primary Host name </entry>
#<entry key="SecondaryHost">Secondary Host name </entry>
#<entry key="PrimaryServerConfig">Primary Server name </entry>
#<entry key="SecondaryServerConfig">Secondary Server name </entry>
#<entry key="DocbaseService">Docbase Service name </entry>
#</properties>
#>>
echo "======= showing changes in the tool's configuration file ======= "
diff config.xml_saved config.xml

echo "======= testing the JDBC connectivity to the db ======="
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   #[[ ! -f ${jdbc_tester} ]] && wget https://github.com/aimtiaz11/oracle-jdbc-tester/releases/download/v1.1/${jdbc_tester}
   # make sure the jdbc connection works;
   #java -jar ${dctm_software}/${jdbc_tester} ${ACTIVE_DOCBASE} ${ACTIVE_DOCBASE} jdbc:oracle:thin:@${db_server_host_alias}:${db_listener_port}/${db_service_name}
   ln -s ${ORACLE_HOME}/ojdbc8.jar ${ORACLE_HOME}/ojdbc.jar
   export CLASSPATH=${ORACLE_HOME}/ojdbc.jar:$CLASSPATH
   java -cp $CLASSPATH:${scripts_dir} jdbc_tester_generic oracle.jdbc.driver.OracleDriver ${ACTIVE_DOCBASE} ${ACTIVE_DOCBASE} jdbc:oracle:thin:@//${db_server_host_alias}:${db_listener_port}/${db_service_name} "select 'now in Oracle db: ' || to_char(sysdate, 'DD/MM/YYYY HH24:MI:SS') as now from dual"
   #<<
   #23:22:47.747 [main] INFO Main - arg 0 = dctm1
   #23:22:47.753 [main] INFO Main - arg 1 = dctm1
   #23:22:47.753 [main] INFO Main - arg 2 = jdbc:oracle:thin:@db:1521:orcl
   #23:22:48.044 [main] INFO Main - ****** Starting JDBC Connection test *******
   #23:22:48.404 [main] INFO Main - Running SQL query: [select sysdate from dual]
   #23:22:48.422 [main] INFO Main - Result of SQL query: [2022-08-13 14:13:57.0]
   #23:22:48.424 [main] INFO Main - JDBC connection test successful!
   #>>
else
   # postgres;
   export CLASSPATH=${dctm_software}/${postgresql_jdbc_package}:$CLASSPATH
   java -cp $CLASSPATH:${scripts_dir} jdbc_tester_generic org.postgresql.Driver ${ACTIVE_DOCBASE} ${ACTIVE_DOCBASE} jdbc:postgresql://${db_server_host_alias}:${ACTIVE_DB_SERVER_PORT}/${ACTIVE_DOCBASE} "select 'now in postgresql db: ' || to_char(current_timestamp(0), 'DD/MM/YYYY HH24:MI:SS') as now;"
fi

echo "======= launching the migration utility ======="
./MigrationUtil.sh

# testing;
#. ${ACTIVE_ROOT}/${ACTIVE_DOCBASE}.env
#cd ${DM_HOME}/install/external_apps/MigrationUtil

#<<
#Welcome... Migration Utility invoked.
#
#Renamed log file to /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/DocbaseIdChange.log.13-08-2022_23.41.47
#Created new log File: /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/DocbaseIdChange.log
#Changing Docbase ID...
#Database owner password is read from config.xml
#Finished changing Docbase ID...
#
#Skipping Host Name Change...
#
#Skipping Install Owner Change...
#
#Changing Server Name...
#Renamed log file to /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/ServerNameChange.log.13-08-2022_23.43.00
#Created new log File: /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/ServerNameChange.log
#Finished changing Server Name...
#
#Changing Docbase Name...
#Renamed log file to /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/DocbaseNameChange.log.13-08-2022_23.43.00
#Created new log File: /u01/dctm1/documentum/product/22.2/install/external_apps/MigrationUtil/MigrationUtilLogs/DocbaseNameChange.log
#Finished changing Docbase Name...
#
#Skipping Docker Seamless Upgrade scenario...
#
#Migration Utility completed.
#>>
echo "======= post migration adaptations ======="
# adjust the locations' root;
cd ${DOCUMENTUM}/data
mv ${SEED_DOCBASE} ${ACTIVE_DOCBASE}

# rename docbase id sub-directories in the locations;
cd ${DOCUMENTUM}/data/${ACTIVE_DOCBASE}
for d in *; do mv $d/* $d/$(printf "%08x" ${ACTIVE_DOCBASE_ID}); done 2>/dev/null

# checked;
cd ${DOCUMENTUM}/dba
ls -lrt dm_start_${ACTIVE_DOCBASE} dm_shutdown_${ACTIVE_DOCBASE}
sed -i "s/${SEED_DOCBASE}/${ACTIVE_DOCBASE}/g" dm_shutdown_${ACTIVE_DOCBASE}

echo "======= adapting server.ini ${DOCUMENTUM}/dba/config/${SEED_DOCBASE}/server.ini ======="
[[ "${ACTIVE_RDBMS}" == "oracle" ]] && sed -i -E "s/${SEED_DOCBASE}(_INDEX)/${ACTIVE_DOCBASE}\1/Ig" ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini
#sed -i -E "s/(database_owner = )${SEED_DATABASE_OWNER}/\1${ACTIVE_DATABASE_OWNER}/g" ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini
[[ "${ACTIVE_RDBMS}" == "oracle" ]] && sed -i -E "s/(database_owner = )${SEED_DATABASE_OWNER}/\1${ACTIVE_DATABASE_OWNER}/g" ${DOCUMENTUM}/dba/config/${ACTIVE_DOCBASE}/server.ini

# check server.ini;
cat config/${ACTIVE_DOCBASE}/server.ini
# docbase_id, docbase_name, service OK
cd ${DOCUMENTUM}/dba
rm dm_documentum_config.txt_docbase_${SEED_DOCBASE}.backup
cd log
mv 00* $(printf "%08x" ${ACTIVE_DOCBASE_ID})
cd ${DOCUMENTUM}/share/data
for d in *; do mv $d/* $d/$(printf "%08x" ${ACTIVE_DOCBASE_ID}); done 2>/dev/null

# adjust the location paths and the job's target_server;
# the MigrationUtil does an incomplete job here;
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   db_cmd="sqlplus ${ACTIVE_DATABASE_OWNER}/${ACTIVE_DATABASE_PASSWORD}@${db_connect_string}"
elif [[ "${ACTIVE_RDBMS}" == "postgres" ]]; then
   db_cmd="psql --port=${ACTIVE_DB_SERVER_PORT} --port=${ACTIVE_DB_SERVER_PORT} --host=/tmp ${ACTIVE_DOCBASE} ${ACTIVE_DOCBASE}"
fi
cat - <<eos | ${db_cmd}
select file_system_path from dm_location_s;
update dm_location_s set file_system_path = replace(file_system_path, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}');
select file_system_path from dm_location_s;
update dm_mount_point_s set file_system_path = replace(file_system_path, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}');
select file_system_path from dm_mount_point_s;
update dm_method_s set method_verb = replace(method_verb, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}');
select method_verb from dm_method_s;
update dm_job_s set target_server = replace(target_server, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}');
select target_server from dm_job_s;
eos

# start !
echo "======= starting the new instance ======="
export DOCBROKER_PORT=${ACTIVE_DOCBROKER_PORT}
export DOCBROKER_NAME=${ACTIVE_DOCBROKER_NAME}
echo "testing docbroker"
if ! ps -ef | grep ${ACTIVE_DOCBROKER_NAME} | grep -v grep | gawk -v DOCBROKER_PORT=${ACTIVE_DOCBROKER_PORT} 'BEGIN {rc = 1; re = "-port (" DOCBROKER_PORT ") "} {match($0, re, f); rc = f[1] && f[1] == DOCBROKER_PORT ? 0 : 1} END {exit rc}'; then
   echo "launching the docbroker on port ${ACTIVE_DOCBROKER_PORT}..."
   dm_launch_${ACTIVE_DOCBROKER_NAME}
else
   echo "using the docbroker running on port ${ACTIVE_DOCBROKER_PORT}..."
fi
dm_start_${ACTIVE_DOCBASE}
for i in {1..10}; do
   echo "waiting for ${ACTIVE_DOCBASE} ..."
   sleep 1
   iapi ${ACTIVE_DOCBASE} -Q -U${dctm_owner} -Pxx
   [[ $? -eq 0 ]] && break
done
cat - <<eoi | iapi ${ACTIVE_DOCBASE} -U${dctm_owner} -Pxx
retrieve,c,dm_server_config
set,c,l,app_server_uri[0]
http://localhost:${ACTIVE_SERVER_HTTP_PORT}/DmMethods/servlet/DoMethod
set,c,l,app_server_uri[1]
http://localhost:${ACTIVE_SERVER_HTTP_PORT}/DmMail/servlet/DoMail
save,c,l
dump,c,l
retrieve,c,dm_docbase_config
dump,c,l
quit
eoi
# Output;
#   OpenText Documentum iapi - Interactive API interface
#   Copyright (c) 2022. OpenText Corporation
#   All rights reserved.
#   Client Library Release 22.2.0000.0051
#
#
#Connecting to Server using docbase dctm1
#[DM_SESSION_I_SESSION_START]info:  "Session 0100c35080000900 started for user dmadmin."
#==> note the docbase_id substring in the session id;
#
#API> retrieve,c,dm_server_config
#...
#3d00c35080000102
#==> here too;
#==> the id was changed successfully;
#
#API> dump,c,l
#...
#USER ATTRIBUTES
#
#  object_name                     : dctm1
#  ...
#  owner_name                      : SEED
#  ...
#  acl_domain                      : SEED
#  ==> default ACLs are owner by ${SEED_DOCBASE} instead of ${ACTIVE_DOCBASE};
#  ==> it can be a problem in applications, hence the good practive to define application-dependent owners of ACLs, i.e. domains;
#  ==> no need to change for system ACLs here;
#  ...
#  operator_name                   : SEED
#...
#  r_creator_name                  : SEED
#
#API> retrieve,c,dm_docbase_config
#...
#3c00c35080000103
#API> dump,c,l
#...
#USER ATTRIBUTES
#
#  object_name                     : seed
#  title                           : This is the seed docbase, an empty OOTB repository to be cloned and renamed
#  ...
#  ...
#  owner_name                      : SEED
#  ...
#  acl_domain                      : SEED
#  acl_name                        : dm_4500271080000100
#  ...
#  index_store                     : SEED_INDEX
#==> change those values;

echo "======= adaptations in dm_docbase_config ======="
cat - <<eoi | iapi ${ACTIVE_DOCBASE} -U${dctm_owner} -Pxx
retrieve,c,dm_docbase_config
dump,c,l
set,c,l,object_name
${ACTIVE_DOCBASE}
set,c,l,title
This is the ${ACTIVE_DOCBASE} docbase
set,c,l,index_store
${ACTIVE_DOCBASE^^}_INDEX
save,c,l
quit
eoi

echo "======= adaptations in dm_job ======="
# check jobs;
cat - <<eoi | iapi ${ACTIVE_DOCBASE} -U${dctm_owner} -Pxx
# force run ContentWarningDoc.txt, DBWarningDoc.txt, UpdateStatsDoc.txt and StateOfDocbaseDoc.txt;
?,c,select object_name, method_arguments from dm_job where object_name in ('dm_ContentWarning', 'dm_DBWarning', 'dm_StateOfDocbase', 'dm_UpdateStats', 'dm_ConsistencyChecker') order by r_object_id
?,c,update dm_job object set is_inactive = 0, set run_now = 1 where object_name in ('dm_ContentWarning', 'dm_DBWarning', 'dm_StateOfDocbase', 'dm_UpdateStats', 'dm_ConsistencyChecker')
eoi
# ==> check logs in ${DOCUMENTUM}/dba/log/$(printf "%08x" ${ACTIVE_DOCBASE_ID})/sysadmin/
# ==> e.g. ConsistencyCheckerDoc.txt;
# ==> OK;
#TO DO: correct time windows so they can run immediately;

# start the tomcat server;
echo "======= starting the tomcat server ======="
${DM_JMS_HOME}/bin/startMethodServer.sh start &
sleep 5
# check logs
#less ${DM_JMS_HOME}/logs/catalina.out
#less ${DM_JMS_HOME}/logs/catalina.2022-08-14.log
# OK;

# tomcat;
# check files;
echo "======= searching last traces of seed docbase in files ======="
cd ${DM_JMS_HOME}
find . -type f -exec grep -l ${SEED_DOCBASE} {} \;
# ==> done automatically;

# correct the following references to the former seed docbase;
# the list has been produced by db-crawler.sh in modify mode, see next section for details;
echo "======= correcting optional attributes (acl_domain, owner_name, etc ...) ======="
cat - <<eos | ${db_cmd}
update DMI_INDEX_S set DATA_SPACE = regexp_replace(DATA_SPACE, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(DATA_SPACE, '${SEED_DOCBASE}');
update DMI_REGISTRY_S set USER_NAME = regexp_replace(USER_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_NAME, '${SEED_DOCBASE}');
update DMR_CONTENT_S set SET_FILE = regexp_replace(SET_FILE, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(SET_FILE, '${SEED_DOCBASE}');
update DM_ACL_S set OWNER_NAME = regexp_replace(OWNER_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OWNER_NAME, '${SEED_DOCBASE}');
update DM_AUDITTRAIL_S set ACL_DOMAIN = regexp_replace(ACL_DOMAIN, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(ACL_DOMAIN, '${SEED_DOCBASE}');
update DM_AUDITTRAIL_S set ATTRIBUTE_LIST = regexp_replace(ATTRIBUTE_LIST, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(ATTRIBUTE_LIST, '${SEED_DOCBASE}');
update DM_AUDITTRAIL_S set STRING_2 = regexp_replace(STRING_2, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(STRING_2, '${SEED_DOCBASE}');
update DM_DOCBASE_CONFIG_S set INDEX_STORE = regexp_replace(INDEX_STORE, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(INDEX_STORE, '${SEED_DOCBASE}');
-- not needed because the Migration Utility create a new cabinet for ${ACTIVE_DOCBASE} and we will end up with 2 distinct cabinets, seed and ${ACTIVE_DOCBASE}, with the same r_folder_path;
-- update DM_FOLDER_R set R_FOLDER_PATH = regexp_replace(R_FOLDER_PATH, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(R_FOLDER_PATH, '${SEED_DOCBASE}');
update DM_GROUP_R set USERS_NAMES = regexp_replace(USERS_NAMES, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USERS_NAMES, '${SEED_DOCBASE}');
update DM_GROUP_S set OWNER_NAME = regexp_replace(OWNER_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OWNER_NAME, '${SEED_DOCBASE}');
update DM_REGISTERED_S set TABLE_OWNER = regexp_replace(TABLE_OWNER, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(TABLE_OWNER, '${SEED_DOCBASE}');
update DM_SERVER_CONFIG_S set OPERATOR_NAME = regexp_replace(OPERATOR_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OPERATOR_NAME, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set ACL_DOMAIN = regexp_replace(ACL_DOMAIN, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(ACL_DOMAIN, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set OBJECT_NAME = regexp_replace(OBJECT_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OBJECT_NAME, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set OWNER_NAME = regexp_replace(OWNER_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OWNER_NAME, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set R_CREATOR_NAME = regexp_replace(R_CREATOR_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(R_CREATOR_NAME, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set R_MODIFIER = regexp_replace(R_MODIFIER, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(R_MODIFIER, '${SEED_DOCBASE}');
update DM_SYSOBJECT_S set TITLE = regexp_replace(TITLE, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(TITLE, '${SEED_DOCBASE}');
update DM_TYPE_S set OWNER = regexp_replace(OWNER, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(OWNER, '${SEED_DOCBASE}');
update DM_USER_S set ACL_DOMAIN = regexp_replace(ACL_DOMAIN, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(ACL_DOMAIN, '${SEED_DOCBASE}');
update DM_USER_S set DEFAULT_FOLDER = regexp_replace(DEFAULT_FOLDER, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(DEFAULT_FOLDER, '${SEED_DOCBASE}');
update DM_USER_S set USER_ADDRESS = regexp_replace(USER_ADDRESS, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_ADDRESS, '${SEED_DOCBASE}');
update DM_USER_S set USER_DB_NAME = regexp_replace(USER_DB_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_DB_NAME, '${SEED_DOCBASE}');
update DM_USER_S set USER_GLOBAL_UNIQUE_ID = regexp_replace(USER_GLOBAL_UNIQUE_ID, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_GLOBAL_UNIQUE_ID, '${SEED_DOCBASE}');
update DM_USER_S set USER_LOGIN_NAME = regexp_replace(USER_LOGIN_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_LOGIN_NAME, '${SEED_DOCBASE}');
update DM_USER_S set USER_NAME = regexp_replace(USER_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_NAME, '${SEED_DOCBASE}');
update DM_USER_S set USER_OS_DOMAIN = regexp_replace(USER_OS_DOMAIN, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_OS_DOMAIN, '${SEED_DOCBASE}');
update DM_USER_S set USER_OS_NAME = regexp_replace(USER_OS_NAME, '${SEED_DOCBASE}', '${ACTIVE_DOCBASE}', 1, 0 ) where regexp_like(USER_OS_NAME, '${SEED_DOCBASE}');
eos

# optionally, check if there are left-over of the seed docbase in the schema;
# we will use the db crawler script presented in the article <a href="https://www.dbi-services.com/blog/db-crawler-a-database-search-utility-for-documentum/">db-crawler, a database search utility for Documentum</a>
# to search any occurrences of the ${SEED_DOCBASE} docbase's "${SEED_DOCBASE}" string;
# our version of the script searches the tables in case-sensitive mode;
# execute it in background;
if [[ "${ACTIVE_RDBMS}" == "oracle" ]]; then
   echo "======= launching the db-crawler in the background ======="
   echo "You may want to check the db-crawler.log output and the db_crawler.out files in ${scripts_dir} in a few minutes"
   cd ${ACTIVE_ROOT}
   nohup ${scripts_dir}/db-crawler.sh ${ACTIVE_DOCBASE}/${ACTIVE_DOCBASE}@${db_connect_string} "${SEED_DOCBASE}" y 2>&1 > ./${ACTIVE_DOCBASE}_db-crawler.log &
else
   # postgres;
   cd ${ACTIVE_ROOT}
   pg_dump --port=${ACTIVE_DB_SERVER_PORT} -U ${ACTIVE_DOCBASE} -h localhost ${ACTIVE_DOCBASE} >> sqlfile.sql
   grep -i ${SEED_DOCBASE} sqlfile.sql
   rm sqlfile.sql
fi
