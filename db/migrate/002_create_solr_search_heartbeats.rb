# frozen_string_literal: true

# When a long-running process of the plugin (the crawl scheduler) last showed it is alive (design D-22). The admin
# page warns when it stops moving.
class CreateSolrSearchHeartbeats < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_heartbeats do |t|
      t.string :name, null: false   # scheduler
      t.string :info                # where it runs: host and pid
      t.datetime :started_at
      t.datetime :beat_at
    end
    add_index :solr_search_heartbeats, :name, unique: true
  end
end
