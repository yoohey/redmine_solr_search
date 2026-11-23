#!/usr/bin/env bash
# The sample data for trying it out (the seed service of compose.redmine.yaml): Redmine's default data in Japanese, then
# the dataset ja-basic (projects, users, issues, wiki pages, documents, attachments), and the attachments' text in the
# index (the rest of the index is made by the scheduler as soon as it starts). Only once: a mark in the files
# volume says it was done, so later `docker compose up` leave the data alone. Runs in /usr/src/redmine.
set -euo pipefail
export RAILS_ENV=production
MARK=files/.solr-search-sample-data
if [[ -e "${MARK}" ]]; then
  echo "The sample data is there already."
  exit 0
fi
# through the image's entrypoint, which writes config/database.yml (from REDMINE_DB_*) before rake (only for rake/rails)
/docker-entrypoint.sh rake redmine:load_default_data REDMINE_LANG=ja
bin/rails runner plugins/redmine_solr_search/docker/seed/ja-basic/seed.rb
bin/rails runner plugins/redmine_solr_search/docker/redmine/trial-settings.rb
# the attachments' text at once (the scheduler would take 200 every 10 minutes): Tika may still be starting, so a few tries
for try in 1 2 3; do
  bin/rake redmine:solr_search:reindex TYPES=attachment && break
  sleep 20
done
touch "${MARK}"
echo "The sample data is in. Log in at http://localhost:${REDMINE_PORT:-3000}/ as admin."
