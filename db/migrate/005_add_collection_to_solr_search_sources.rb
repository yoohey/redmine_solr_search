# frozen_string_literal: true

# A source is a collection chosen among Solr's, named on Solr's side (design D-35), no longer src_<id>: the name is
# kept. Sources made before keep the collection they were named after.
class AddCollectionToSolrSearchSources < ActiveRecord::Migration[SolrSearch.migration_version]
  def up
    add_column :solr_search_sources, :collection, :string
    execute "UPDATE solr_search_sources SET collection = 'src_' || id"
    change_column_null :solr_search_sources, :collection, false
    add_index :solr_search_sources, :collection, unique: true
  end

  def down
    remove_index :solr_search_sources, :collection
    remove_column :solr_search_sources, :collection
  end
end
