#!/usr/bin/env bash

LOG_FILE=$(mktemp --suffix CORTEX-DEBUG)

RED='\033[0;31m'
GREEN='\033[0;32m'
BROWN='\033[0;33m'
NC='\033[0m' # No Color


log() {
  echo -en "${BROWN}$1 ... ${NC}" | tee -a ${LOG_FILE} >&2
}

ok() {
	echo -e "${GREEN}OK${NC}" >&2
}

ko() {
	echo -e "${RED}KO${NC}" >&2
}

check() {
	expected=$1
	shift
	status_code=$(curl -v "$@" -s -o /dev/stderr -w '%{http_code}' 2>>${LOG_FILE})
	if [ "${status_code}" = "${expected}" ]
	then
	  ok
	else
	  ko
	  echo "got ${status_code}, expected ${expected}" >&2
	  echo "see more detail in $LOG_FILE" >&2
	  exit 1
	fi
}

get() {
	expected=$1
	shift
   . <({ result=$({ status_code=$(curl "$@" -s -o /dev/stderr -w '%{http_code}'); } 2>&1; declare -p status_code >&2); declare -p result; } 2>&1)
   echo ${result} > ${LOG_FILE}
	if [ "${status_code}" = "${expected}" ]
	then
	  echo ${result}
	  ok
	else
	  ko
	  echo "got ${status_code}, expected ${expected}" >&2
	  echo "see more detail in $LOG_FILE" >&2
	  exit 1
	fi
}

log 'Delete the index'
check 200 -XDELETE 'http://127.0.0.1:9200/cortex_1'

log 'Create the index'
check 204 -XPOST 'http://127.0.0.1:9001/api/maintenance/migrate'

log 'Checking if default organization exist'
check 200 'http://127.0.0.1:9001/api/organization/default'

log 'Create the initial user'
check 201 'http://127.0.0.1:9001/api/user' -H 'Content-Type: application/json' -d '
		{
		  "login" : "admin",
		  "name" : "admin",
		  "roles" : [
			  "read",
			  "write",
			  "admin"
		   ],
		  "preferences" : "{}",
		  "password" : "admin",
		  "organization": "default"
		}'

log 'Checking admin user is correctly created'
check 200 -u admin:admin 'http://127.0.0.1:9001/api/user/admin'

log 'Get analyzer list'
ANALYZERS=($(get 200 -u admin:admin 'http://127.0.0.1:9001/api/analyzerdefinition' | jq -r '.[] | .id'))
for A in "${ANALYZERS[@]}}"
do
	echo "  - ${A}"
done

log 'Analyzer MaxMind_GeoIP_3_0 should exist'
case "${ANALYZERS[@]}" in  *"MaxMind_GeoIP_3_0"*) echo "OK" ;; esac

log 'Create an MaxMind analyzer in default organization'
check 201 -u admin:admin 'http://127.0.0.1:9001/api/organization/default/analyzer/MaxMind_GeoIP_3_0' \
	-H 'Content-Type: application/json' -d '
		{
		  "name" : "GeoIP"
		}'

log 'Get ID of the created analyzer'
GEOIP_ID=$(get 200 -u admin:admin 'http://127.0.0.1:9001/api/analyzer' | jq -r '.[] | .id')
echo "  ${GEOIP_ID}"

log 'Get analyzer for IP data'
IP_ANALYZERS=$(get 200 -u admin:admin 'http://127.0.0.1:9001/api/analyzer/type/ip')

log 'GeoIP analyzer should be available for IP data'
echo ${IP_ANALYZERS} | jq -r '.[] | .id' | grep -q "^${GEOIP_ID}$" && ok || ko

log 'Run an analyze'
JOB_ID=$(get 200 -u admin:admin "http://127.0.0.1:9001/api/analyzer/${GEOIP_ID}/run" \
	-H 'Content-Type: application/json' -d '
		{
		  "data" : "82.225.219.43",
          "dataType" : "ip"
        }' | jq -r '.id')
echo "  $(echo ${JOB_ID} )"

log 'Wait report'
REPORT=$(get 200 -u admin:admin "http://127.0.0.1:9001/api/job/${JOB_ID}/waitreport")

log 'Status of the report should be success'
echo ${REPORT} | jq -r '.status' | grep -q '^Success$' && ok || {
  ko
  jq . <<< ${REPORT}
}