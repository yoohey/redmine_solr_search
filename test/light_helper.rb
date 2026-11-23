# frozen_string_literal: true

# Light tests (M1 review D2): the parts of the plugin that need neither a database nor Solr, run with plain minitest
# and Active Support, without Redmine's test database or fixtures. What depends on Redmine's permissions or on Solr
# is checked in the experiment rounds (docs/experiments/) on the seed data instead.
#
#   bin/rake redmine:solr_search:light_test      (in the Redmine folder; see lib/tasks/solr_search.rake)
require 'minitest/autorun'
# Active Support 6.1 (Redmine 5.1) uses Logger without requiring it, which newer concurrent-ruby no longer loads for it
require 'logger'
require 'active_support'
require 'active_support/core_ext'

LIB = File.expand_path('../lib', __dir__)
require File.join(LIB, 'solr_search')
%w[client tika_client attachment_text link_pattern path_mapping external_hits spelling_variants permission_filter custom_field_query searcher/facets searcher/filters searcher/reranking searcher redmine_documents status metrics requests solr_url schema_check collection_check search_log clicks log_export collection_info search_stats counters index_health golden source_status snippet filter_translator tuning query_dictionary reranker settings group_id reindex_scope count_rounding icon_helper].each {|name| require File.join(LIB, 'solr_search', name)}
