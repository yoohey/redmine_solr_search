# frozen_string_literal: true

# The link pattern and the path mapping of an external source (design D-35) as text columns. As strings, MySQL makes them
# varchar(255), shorter than what the model lets through (1000 and 500 characters: M4 review, #23). The model keeps the
# limits. 006 and 007 stay as they were run: a migration that has run is not changed afterwards.
class ChangeSourceTextsToText < ActiveRecord::Migration[SolrSearch.migration_version]
  def up
    change_column :solr_search_sources, :link_pattern, :text
    change_column :solr_search_sources, :path_from, :text
    change_column :solr_search_sources, :path_to, :text
  end

  def down
    change_column :solr_search_sources, :link_pattern, :string
    change_column :solr_search_sources, :path_from, :string
    change_column :solr_search_sources, :path_to, :string
  end
end
