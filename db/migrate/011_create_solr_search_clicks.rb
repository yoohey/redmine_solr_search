# frozen_string_literal: true

# What was opened from the result list of a search (design D-45): one row for each click on a link of the list, with the
# place of the item in the list. Only the click: nothing after it. Deleted together with the search it belongs to.
class CreateSolrSearchClicks < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_clicks do |t|
      t.datetime :created_at, null: false
      t.integer :log_id, null: false     # the row of solr_search_logs that this click follows
      t.string :group_id, null: false    # what was opened: issue-12, wiki_page-3 ...; an external document's id
      t.integer :rank                    # the place of the group on the page, from 1
      t.string :kind                     # title, note, attachment, more, other
      t.string :title                    # as the link read when it was clicked
      t.text :href                       # where the link goes
    end
    add_index :solr_search_clicks, :log_id
  end
end
