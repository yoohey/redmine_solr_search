# frozen_string_literal: true

# External index sources (design D-4, D-17, D-32, D-33): a source is one collection (src_<id>) of documents crawled
# from one place, linked to the projects whose members may search it; every change to them is kept as history.
class CreateSolrSearchSources < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    create_table :solr_search_sources do |t|
      t.string :name, null: false               # the label people see; the collection is named after the id
      t.text :description
      t.datetime :missing_collection_at         # when a search last found no collection for it (design D-33)
      t.timestamps
    end
    add_index :solr_search_sources, :name, unique: true

    # many to many (design D-4)
    create_table :solr_search_project_sources do |t|
      t.integer :project_id, null: false
      t.integer :source_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :solr_search_project_sources, [:project_id, :source_id], unique: true
    add_index :solr_search_project_sources, :source_id

    # The links are the only thing that guards external documents (design chapter 5): who changed what, kept with the
    # names as they were, so it stays readable after the source or the project is gone (design D-32)
    create_table :solr_search_source_changes do |t|
      t.integer :user_id
      t.string :action, null: false             # source_created, source_updated, source_deleted, linked, unlinked
      t.integer :source_id
      t.string :source_name
      t.integer :project_id
      t.string :project_name
      t.text :details                           # JSON: the changed values, or why a link went away
      t.datetime :created_at, null: false
    end
    add_index :solr_search_source_changes, :created_at
    add_index :solr_search_source_changes, :source_id
  end
end
