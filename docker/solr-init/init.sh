#!/usr/bin/env bash
# Runs via the solr-init service on every `docker compose up -d` and then exits. Safe to re-run.
#   1. Builds every configset in ../solr/configsets (mounted at /solr/configsets) together with the common part
#      ../solr/common (design D-26), and uploads it to ZooKeeper, so edits there take effect on the next `docker compose up -d`.
#      Files in ZooKeeper that are not in the built configset are removed: git is the source of truth, so this also
#      removes what the Config API / Request Parameters API would write there (configoverlay.json, params.json).
#   2. Reloads every existing collection that uses one of these configsets (redmine, src_<ID>, ...), so the uploaded
#      config is applied everywhere.
#   3. Creates the "redmine" collection (1 shard x REPLICATION_FACTOR replicas) if it does not exist yet.
#      Collections of external sources (src_<ID>) are not created here (design Q-12).
set -euo pipefail

ZK_HOST="${ZK_HOST:-zoo1:2181,zoo2:2181,zoo3:2181}"
SOLR_URL="${SOLR_URL:-http://solr1:8983/solr}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-2}"   # 1 for one Solr node, 2 for SolrCloud with two
COLLECTION="redmine"
CONFIGSET="redmine"

# Collections API call: on failure, print Solr's answer and stop (-f alone would drop the body)
api() {
  local out
  out="$(curl -sS --fail-with-body "${SOLR_URL}/admin/collections?$1&wt=json&indent=off")" || { echo "${out}" >&2; return 1; }
  # a Collections API call can be "status 0" and still have failed on a node (a RELOAD of a core whose config does not
  # load, 2026-10-20): its answer then has a "failure" part
  if grep -q '"failure"' <<< "${out}"; then echo "${out}" >&2; return 1; fi
  echo "${out}"
}

build="$(mktemp -d)"
trap 'rm -rf "${build}"' EXIT

configsets=()
for conf in /solr/configsets/*/conf; do
  name="$(basename "$(dirname "${conf}")")"
  configsets+=("${name}")
  # A configset = its own conf/ + solr/common/ (XIncluded files must sit inside the configset).
  # A file in both would be silently overwritten by the common one, so refuse that.
  (cd /solr/common && find . -type f) | while read -r rel; do
    if [[ -e "${conf}/${rel#./}" ]]; then
      echo "ERROR: ${rel#./} は configsets/${name}/conf と common の両方にあります" >&2; exit 1
    fi
  done
  mkdir -p "${build}/${name}"
  cp -r "${conf}/." "${build}/${name}/"
  cp -r /solr/common/. "${build}/${name}/"
  echo "==> configset ${name} を ZooKeeper にアップロードします（solr/common を含む）"
  solr zk upconfig -n "${name}" -d "${build}/${name}" -z "${ZK_HOST}"

  # upconfig only adds and overwrites: files removed from git (e.g. managed-schema.xml of _default) stay in
  # ZooKeeper. Remove whatever is not in the configset just built.
  mkdir -p "${build}/zk/${name}"
  solr zk cp -r "zk:/configs/${name}" "${build}/zk/${name}" -z "${ZK_HOST}" > /dev/null
  (cd "${build}/zk/${name}" && find . -mindepth 1 | sort) | while read -r rel; do
    rel="${rel#./}"
    [[ -e "${build}/${name}/${rel}" || ! -e "${build}/zk/${name}/${rel}" ]] && continue
    echo "    ZooKeeper から削除します: ${rel}"
    solr zk rm -r "zk:/configs/${name}/${rel}" -z "${ZK_HOST}" > /dev/null
    rm -rf "${build}/zk/${name}/${rel}"   # so its children are skipped
  done
done

# Every existing collection whose configset was just uploaded is reloaded
collections="$(api 'action=LIST' | grep -o '"collections":\[[^]]*\]' | grep -o '"[^"]*"' | tr -d '"' | grep -v '^collections$' || true)"
for c in ${collections}; do
  cfg="$(api "action=CLUSTERSTATUS&collection=${c}" | grep -o '"configName":"[^"]*"' | head -1 | cut -d'"' -f4)"
  if [[ " ${configsets[*]} " == *" ${cfg} "* ]]; then
    echo "==> ${c}（configset ${cfg}）をリロードします"
    api "action=RELOAD&name=${c}" > /dev/null
  fi
done

if ! grep -qx "${COLLECTION}" <<< "${collections}"; then
  echo "==> ${COLLECTION} を作成します（1 shard x ${REPLICATION_FACTOR} replicas, configset ${CONFIGSET}）"
  # waitForFinalState: return only when every replica is active
  api "action=CREATE&name=${COLLECTION}&numShards=1&replicationFactor=${REPLICATION_FACTOR}&collection.configName=${CONFIGSET}&waitForFinalState=true" > /dev/null
fi

echo "==> 完了しました"
