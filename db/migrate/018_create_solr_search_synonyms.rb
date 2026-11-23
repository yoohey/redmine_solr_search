# frozen_string_literal: true

# The query expansion dictionary (design D-53, Q-27): every saving of its tab on the admin page is a row, and the last row is
# the dictionary in force. So the table is both the text and its history; nothing is changed or deleted. No row: no dictionary.
class CreateSolrSearchSynonyms < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_synonyms do |t|
      t.integer :user_id
      t.string :user_login
      t.text :body, null: false
      t.datetime :created_at, null: false
    end
  end
end
