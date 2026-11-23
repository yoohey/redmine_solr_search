# frozen_string_literal: true

# One run of the golden query sets (design D-45): how the search does against what is known to be right. A row for each
# run, kept as the history to compare before and after a change (the weights, a reranker). Apart from the search log.
class CreateSolrSearchGoldenRuns < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_golden_runs do |t|
      t.string :kind, null: false, limit: 20          # coverage (set A) or ranking (set B)
      t.string :dataset, limit: 100
      t.datetime :ran_at, null: false
      t.integer :duration_ms
      t.integer :queries, null: false, default: 0     # searches made
      t.integer :expected, null: false, default: 0    # coverage: containers that should be found; ranking: queries
      t.integer :found, null: false, default: 0
      t.integer :leaks, null: false, default: 0       # coverage only: found, but the user may not see it
      t.float :recall
      t.float :precision                              # coverage only
      t.float :mrr                                    # ranking only
      t.float :recall_at_k                            # ranking only
      t.integer :k                                    # ranking only
      t.string :note, limit: 255                      # what was changed before this run (GOLDEN_NOTE)
      t.text :details                                 # JSON: what did not go as expected (first ones)
    end
    add_index :solr_search_golden_runs, %i[kind ran_at]
  end
end
