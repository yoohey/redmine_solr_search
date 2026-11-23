# frozen_string_literal: true

# The counts that Prometheus reads about the searches (design D-45): a few rows, one for each count, added to as searches
# and clicks happen. Apart from the log on purpose: deleting the log does not make them smaller, and reading them does not
# walk a log that grows for ever.
class CreateSolrSearchCounters < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_counters do |t|
      t.string :key, null: false, limit: 100
      t.bigint :value, null: false, default: 0
    end
    add_index :solr_search_counters, :key, unique: true
  end
end
