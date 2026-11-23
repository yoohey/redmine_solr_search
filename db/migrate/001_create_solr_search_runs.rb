# frozen_string_literal: true

# One row per run of a crawl task (design D-22): what ran, who started it, when, what it sent and removed, and whether
# it succeeded. The incremental crawl takes its starting point from here, and the admin page shows it.
class CreateSolrSearchRuns < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_runs do |t|
      t.string :task, null: false          # incremental, resend, reconcile, reindex
      t.string :status, null: false        # requested, running, succeeded, failed
      t.string :triggered_by, null: false  # scheduler, rake, admin
      # 1 while running, NULL otherwise. The unique index lets only one run at a time hold it, whatever the task.
      t.integer :running_slot
      t.datetime :since                    # the incremental crawl's starting point
      t.datetime :started_at
      t.datetime :finished_at
      t.text :counts                       # JSON: {type => {"sent" => n, "deleted" => n}}
      t.text :error
      t.timestamps                         # updated_at moves while running; a run that stops moving is dead
    end
    add_index :solr_search_runs, :running_slot, unique: true
    add_index :solr_search_runs, [:task, :status, :started_at]
  end
end
