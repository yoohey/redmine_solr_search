# frozen_string_literal: true

# Which projects may link an external index source (design D-34): all of them, or the ones an administrator chose.
# A project links a source on its own settings tab, among the sources it is allowed.
class CreateSolrSearchSourceAllowedProjects < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_sources, :all_projects, :boolean, null: false, default: false

    create_table :solr_search_source_allowed_projects do |t|
      t.integer :source_id, null: false
      t.integer :project_id, null: false   # this project only, not its subprojects (design D-34)
      t.datetime :created_at, null: false
    end
    add_index :solr_search_source_allowed_projects, [:source_id, :project_id], unique: true, name: 'index_solr_search_allowed_on_source_and_project'
    add_index :solr_search_source_allowed_projects, :project_id
  end
end
