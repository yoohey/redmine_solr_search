# frozen_string_literal: true

# The tuning of the order of the results (design D-51, Q-34): every saving of the admin page's "fine tuning" tab is a row,
# and the last row is the tuning in force. So the table is both the value and its history; nothing is changed or deleted.
# No row: the defaults (what the search always sent).
class CreateSolrSearchTunings < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_tunings do |t|
      t.integer :user_id
      t.string :user_login
      t.text :settings, null: false
      t.datetime :created_at, null: false
    end
  end
end
