#!/usr/bin/env bash
# Makes an external source of redmine_solr_search from a folder, for the ManifoldCF of compose.manifoldcf.yaml:
#   1. the Solr collection (configset "src", which solr-init uploads), unless it exists;
#   2. ManifoldCF's connections: allowed-documents, tika-server and content-limiter are shared by every source (kept when
#      they exist); fs-<name>, fixed-<name> and solr-<name> belong to this source (<name>: the collection, - for _);
#   3. the job: File system -> Allowed documents -> Tika Server -> Content limiter -> Metadata adjuster -> Solr.
# It never deletes nor overwrites: it stops when a connection or the job of this source exists, and when the collection
# exists, unless --use-existing (two jobs writing to one collection delete each other's documents). Registering the
# source on Redmine (the admin page, then each project's settings) stays a step of its own.
# The same as publish/windows/add-folder.ps1 (ManifoldCF on Windows itself); see that for the reasons of the details.
#
#   manifoldcf/add-folder.sh <folder as ManifoldCF sees it> <collection> [options]
#     e.g.  manifoldcf/add-folder.sh /source src_shared --start          (run in docker/; /source is MCF_SOURCE_PATH)
#   --schedule M[,M...]|manual   when ManifoldCF starts the job by itself: minutes of every hour (default 0), or never
#   --start                      start the job at once
#   --use-existing               use the collection when it exists already
#   --dry-run                    print what would be sent, send nothing
#   --mcf URL --solr URL         where ManifoldCF and Solr answer from here (default http://127.0.0.1:8345, :8983/solr)
#   --mcf-solr URL               where ManifoldCF reaches Solr, when not through ZooKeeper (default http://solr:8983/solr)
#   --tika HOST:PORT             where ManifoldCF reaches Tika (default tika:9998)
#   -h, --help                   show this help
# Needs curl. The status of the tika-server connection is never checked (ManifoldCF 2.31 then loses a connection and the
# crawl waits 15 minutes: docs/operations.md, 5.1).
set -euo pipefail

# the help is the comment at the top: usage [exit status] (0 when asked for, 1 after a wrong call)
usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
for arg in "$@"; do [[ "${arg}" == -h || "${arg}" == --help ]] && usage 0; done
[[ $# -ge 2 ]] || { echo "give the folder and the collection (-h for help)" >&2; exit 1; }
FOLDER="$1"; COLLECTION="$2"; shift 2
SCHEDULE=0; START=0; USE_EXISTING=0; DRY=0
MCF=http://127.0.0.1:8345; SOLR=http://127.0.0.1:8983/solr; MCF_SOLR=http://solr:8983/solr; TIKA=tika:9998
while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule) SCHEDULE="$2"; shift 2 ;;
    --start) START=1; shift ;;
    --use-existing) USE_EXISTING=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --mcf) MCF="$2"; shift 2 ;;
    --solr) SOLR="$2"; shift 2 ;;
    --mcf-solr) MCF_SOLR="$2"; shift 2 ;;
    --tika) TIKA="$2"; shift 2 ;;
    *) echo "unknown option: $1 (-h for help)" >&2; exit 1 ;;
  esac
done
[[ "${COLLECTION}" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "the collection: letters, digits, _ and - only" >&2; exit 1; }
[[ "${SCHEDULE}" == manual || "${SCHEDULE}" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "--schedule: minutes like 0,30, or manual" >&2; exit 1; }
NAME="${COLLECTION//_/-}"
API="${MCF}/mcf-api-service/json"

# the same lists as the plugin's attachments (and publish/windows/add-folder.ps1)
EXTENSIONS="doc docx xls xlsx ppt pptx odt ods odp rtf txt md csv tsv json xml html htm log yml yaml ini conf pdf"
MIMETYPES="application/msword application/vnd.openxmlformats-officedocument.wordprocessingml.document
application/vnd.ms-excel application/vnd.openxmlformats-officedocument.spreadsheetml.sheet application/vnd.ms-powerpoint
application/vnd.openxmlformats-officedocument.presentationml.presentation application/vnd.oasis.opendocument.text
application/vnd.oasis.opendocument.spreadsheet application/vnd.oasis.opendocument.presentation application/rtf text/rtf
application/pdf text/plain text/markdown text/csv text/tab-separated-values application/json application/xml text/xml
text/html application/xhtml+xml application/x-yaml text/yaml text/x-yaml text/x-web-markdown text/x-log text/x-ini
application/octet-stream"
EXCLUDED="._* .DS_Store Thumbs.db desktop.ini *.zip *.tar *.gz *.tgz *.bz2 *.xz *.7z *.rar *.jar *.war *.cab *.iso"

# JSON string: backslashes, quotes and control characters escaped (a folder may have any name)
js() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"; printf '"%s"' "$s"; }
# a list, one to a line, as ManifoldCF's filter wants it
lines() { local out="" w; for w in $1; do out+="${w}"$'\n'; done; js "${out%$'\n'}"; }
param() { printf '{"_type_":"_PARAMETER_","_attribute_name":%s,"_value_":%s}' "$(js "$1")" "$(js "$2")"; }
node() { printf '{"_type_":%s,"_attribute_value":%s}' "$(js "$1")" "$(js "$2")"; }

call() {   # call METHOD PATH [BODY]: prints the answer
  local method="$1" path="$2" body="${3:-}"
  if [[ ${DRY} -eq 1 && "${method}" != GET ]]; then echo "--- ${method} ${API}${path}" >&2; [[ -n "${body}" ]] && echo "${body}" >&2; echo '{}'; return; fi
  if [[ -n "${body}" ]]; then
    curl -sS -X "${method}" -H 'Content-Type: application/json; charset=utf-8' --data-binary "${body}" "${API}${path}"
  else
    curl -sS -X "${method}" "${API}${path}"
  fi
}
exists() { call GET "/$1/$3" | grep -q "\"$2\""; }   # exists PLURAL KIND NAME
put_connection() {   # put_connection PLURAL KIND NAME CLASS DESCRIPTION CONFIG-JSON-LIST [MAX]
  local body answer
  body="{\"$2\":{\"name\":$(js "$3"),\"class_name\":$(js "$4"),\"description\":$(js "$5"),\"max_connections\":\"${7:-10}\",\"configuration\":{\"_children_\":[$6]}}}"
  answer="$(call PUT "/$1/$3" "${body}")"
  if grep -q '"error"' <<< "${answer}"; then echo "PUT /$1/$3: ${answer}" >&2; exit 1; fi
  echo "made $1/$3"
}
check_connection() {   # check_connection PLURAL NAME: must be "Connection working"
  [[ ${DRY} -eq 1 ]] && return
  local answer; answer="$(call GET "/status/$1/$2")"
  echo "  status of $2: $(grep -o '"check_result":"[^"]*"' <<< "${answer}" | cut -d'"' -f4)"
  grep -q '"check_result":"Connection working"' <<< "${answer}" || { echo "$2 is not working" >&2; exit 1; }
}

# --- before anything: ManifoldCF, Solr, the configset, nothing of this source there yet
curl -sf -o /dev/null "${MCF}/mcf-crawler-ui/" || curl -s -o /dev/null -w '%{http_code}' "${MCF}/mcf-crawler-ui/" | grep -q '^30' \
  || { echo "ManifoldCF does not answer at ${MCF}" >&2; exit 1; }
curl -sf "${SOLR}/admin/configs?action=LIST&wt=json" | grep -q '"src"' \
  || { echo "Solr at ${SOLR} has no configset src (solr-init uploads it)" >&2; exit 1; }
for own in "repositoryconnections repositoryconnection fs-${NAME}" "transformationconnections transformationconnection fixed-${NAME}" \
           "outputconnections outputconnection solr-${NAME}"; do
  set -- ${own}
  if exists "$1" "$2" "$3"; then echo "ManifoldCF has a connection $3 already: nothing done" >&2; exit 1; fi
done
if call GET /jobs | grep -q "\"_type_\":\"description\",\"_value_\":\"${COLLECTION}[ \"]"; then
  echo "ManifoldCF has a job of ${COLLECTION} already: nothing done" >&2; exit 1
fi

# where ManifoldCF sends: through ZooKeeper when Solr has its own ZooKeeper nodes (SolrCloud, compose.solrcloud.yaml);
# straight to the URL when its ZooKeeper is the embedded one, which listens inside Solr's container only
ZK="$(curl -sf "${SOLR}/admin/info/system?wt=json" | grep -o '"zkHost":"[^"]*"' | cut -d'"' -f4 || true)"
if [[ -n "${ZK}" && ! "${ZK}" =~ (localhost|127\.0\.0\.1|:9983) ]]; then
  WHERE="$(param 'Solr type' solrcloud)"
  for hp in ${ZK//,/ }; do WHERE+=",{\"_type_\":\"zookeeper\",\"_attribute_host\":$(js "${hp%%:*}"),\"_attribute_port\":$(js "${hp##*:}")}"; done
  WHERE+=",$(param 'ZooKeeper znode path' ''),$(param Collection "${COLLECTION}")"
  REPLICAS="$(curl -sf "${SOLR}/admin/collections?action=CLUSTERSTATUS&wt=json" | grep -o '"live_nodes":\[[^]]*\]' | grep -o '_solr"' | wc -l)"
else
  proto="${MCF_SOLR%%://*}"; rest="${MCF_SOLR#*://}"; hostport="${rest%%/*}"; webapp="${rest#*/}"
  WHERE="$(param 'Solr type' standard),$(param 'Server protocol' "${proto}"),$(param 'Server name' "${hostport%%:*}")"
  WHERE+=",$(param 'Server port' "${hostport##*:}"),$(param 'Server web application' "${webapp%/}"),$(param 'Solr core name' "${COLLECTION}")"
  REPLICAS=1
fi
[[ "${REPLICAS}" -ge 2 ]] && REPLICAS=2 || REPLICAS=1

# --- 1. the collection
if curl -sf "${SOLR}/admin/collections?action=LIST&wt=json" | grep -q "\"${COLLECTION}\""; then
  [[ ${USE_EXISTING} -eq 1 ]] || { echo "Solr has a collection ${COLLECTION} already: another name, or --use-existing" >&2; exit 1; }
  echo "the collection ${COLLECTION} exists: used as it is"
elif [[ ${DRY} -eq 1 ]]; then
  echo "--- would make the collection ${COLLECTION} (configset src, ${REPLICAS} replica(s))" >&2
else
  curl -sf "${SOLR}/admin/collections?action=CREATE&name=${COLLECTION}&numShards=1&replicationFactor=${REPLICAS}&collection.configName=src&waitForFinalState=true&wt=json" \
    | grep -q '"status":0' || { echo "Solr did not make ${COLLECTION}" >&2; exit 1; }
  echo "made the collection ${COLLECTION} (${REPLICAS} replica(s))"
fi

# --- 2. the connections
exists transformationconnections transformationconnection allowed-documents || put_connection transformationconnections \
  transformationconnection allowed-documents org.apache.manifoldcf.agents.transformation.documentfilter.DocumentFilter 'Allowed documents' ''
# few calls at a time: Tika Server refuses many at once
exists transformationconnections transformationconnection tika-server || put_connection transformationconnections \
  transformationconnection tika-server org.apache.manifoldcf.agents.transformation.tikaservice.TikaExtractor 'Tika Server' \
  "$(param tikaHostname "${TIKA%%:*}"),$(param tikaPort "${TIKA##*:}")" 4
exists transformationconnections transformationconnection content-limiter || put_connection transformationconnections \
  transformationconnection content-limiter org.apache.manifoldcf.agents.transformation.contentlimiter.ContentLimiter 'Content limiter' ''
put_connection repositoryconnections repositoryconnection "fs-${NAME}" \
  org.apache.manifoldcf.crawler.connectors.filesystem.FileConnector "File system (${FOLDER})" ''
check_connection repositoryconnections "fs-${NAME}"
put_connection transformationconnections transformationconnection "fixed-${NAME}" \
  org.apache.manifoldcf.agents.transformation.forcedmetadata.ForcedMetadataConnector 'Metadata adjuster' ''
put_connection outputconnections outputconnection "solr-${NAME}" org.apache.manifoldcf.agents.output.solr.SolrConnector "${COLLECTION}" \
  "${WHERE},$(param 'Server update handler' /update),$(param 'Server remove handler' /update),$(param 'Server status handler' /admin/ping),$(param 'Use extract update handler' false),$(param 'Solr id field name' id),$(param 'Solr content field name' content),$(param 'Solr filename field name' title),$(param 'Solr modified date field name' updated_at),$(param 'Maximum document length' 52428800),$(param Commits true),$(param 'Commit within' 10000)"
check_connection outputconnections "solr-${NAME}"

# --- 3. the job
rules=""
for m in ${EXCLUDED}; do rules+="{\"_type_\":\"exclude\",\"_attribute_type\":\"file\",\"_attribute_match\":$(js "${m}")},"; done
rules+='{"_type_":"include","_attribute_type":"file","_attribute_match":"*"},{"_type_":"include","_attribute_type":"directory","_attribute_match":"*"}'
stage() {   # stage ID PREREQUISITE CONNECTION SPEC-LIST [output]
  printf '{"stage_id":"%s",%s"stage_isoutput":"%s","stage_connectionname":%s,"stage_specification":{"_children_":[%s]}}' \
    "$1" "${2:+\"stage_prerequisite\":\"$2\",}" "${5:-false}" "$(js "$3")" "$4"
}
# the lists of the filter are the text of their nodes, one to a line (a "value" attribute would let nothing through)
pipeline="$(stage 0 '' allowed-documents "{\"_type_\":\"extensions\",\"_value_\":$(lines "${EXTENSIONS}")},{\"_type_\":\"mimetypes\",\"_value_\":$(lines "${MIMETYPES}")},$(node maxlength 52428800)")"
pipeline+=",$(stage 1 0 tika-server "$(node keepAllMetadata false),$(node lowerNames false),$(node ignoreException false),$(node writeLimit 10000000)")"
pipeline+=",$(stage 2 1 content-limiter "$(node maxlength 3000000)")"
pipeline+=",$(stage 3 2 "fixed-${NAME}" "$(node keepAllMetadata false),$(node filterEmpty true),{\"_type_\":\"expression\",\"_attribute_parameter\":\"url\",\"_attribute_value\":\"file:\${uri}\"},{\"_type_\":\"expression\",\"_attribute_parameter\":\"path\",\"_attribute_value\":\"\${uri}\"}")"
pipeline+=",$(stage 4 3 "solr-${NAME}" '' true)"
if [[ "${SCHEDULE}" == manual ]]; then
  start='"start_mode":"manual"'
else   # a window starts at each of those minutes; with no duration, a run is never cut short
  start="\"start_mode\":\"schedule window start\",\"schedule\":[{\"minutesofhour\":{\"value\":[${SCHEDULE}]}}]"
fi
job="{\"job\":{\"description\":$(js "${COLLECTION} (${FOLDER})"),\"repository_connection\":$(js "fs-${NAME}"),\"document_specification\":{\"_children_\":[{\"_type_\":\"startpoint\",\"_attribute_path\":$(js "${FOLDER}"),\"_children_\":[${rules}]}]},${start},\"run_mode\":\"scan once\",\"hopcount_mode\":\"accurate\",\"priority\":\"5\",\"pipelinestage\":[${pipeline}]}}"
answer="$(call POST /jobs "${job}")"
if grep -q '"error"' <<< "${answer}"; then echo "POST /jobs: ${answer}" >&2; exit 1; fi
job_id="$(grep -o '"job_id":"[0-9]*"' <<< "${answer}" | cut -d'"' -f4 || true)"
echo "made the job ${job_id:-?} (${COLLECTION}, schedule: ${SCHEDULE})"
if [[ ${START} -eq 1 && ${DRY} -eq 0 && -n "${job_id}" ]]; then
  call PUT "/start/${job_id}" > /dev/null
  echo "started the job ${job_id}: see ManifoldCF's 'Status and job management'"
fi
echo "Next: register ${COLLECTION} on Redmine (Administration > Full-text search > External sources) and link it to projects."
