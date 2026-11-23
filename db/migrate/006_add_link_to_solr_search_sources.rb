# frozen_string_literal: true

# How an external source's documents are shown (design D-35): their path as text (the default), or as a link made from
# a pattern (SolrSearch::LinkPattern).
class AddLinkToSolrSearchSources < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_sources, :link_format, :string, null: false, default: 'text'
    add_column :solr_search_sources, :link_pattern, :string
  end
end
