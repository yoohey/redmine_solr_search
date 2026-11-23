# frozen_string_literal: true

# One row for each search that the search screen made in Solr (design D-45): what the people of the system look for,
# and how it went. Kept until an administrator deletes it (nothing removes it by itself). The user is kept twice, the id
# and the login of that time, because the log outlives the user.
class CreateSolrSearchLogs < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_logs do |t|
      t.datetime :created_at, null: false
      t.integer :user_id                 # nil: not logged in
      t.string :user_login
      t.text :query, null: false
      t.text :request_path               # as sent: the path and the query string (the conditions, the page ...)
      t.integer :project_id              # the project the search was opened from, if any
      t.integer :page, null: false, default: 1
      t.integer :hit_count               # what Solr counted; nil when the search failed
      t.integer :group_count
      t.integer :dropped_count           # groups of the page that Redmine's own checks did not show (should be about 0)
      t.integer :took_ms
      t.string :error                    # why the search failed
    end
    add_index :solr_search_logs, :created_at
    add_index :solr_search_logs, [:hit_count, :created_at]
  end
end
