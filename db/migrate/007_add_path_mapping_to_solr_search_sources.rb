# frozen_string_literal: true

# How an external source shows where a document is (design D-35, SolrSearch::PathMapping): a path in the index that starts
# with path_from is shown with path_to in its place.
class AddPathMappingToSolrSearchSources < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_sources, :path_from, :string
    add_column :solr_search_sources, :path_to, :string
  end
end
