# frozen_string_literal: true

# Which collection a search went to, and which external sources it also searched (design D-45): the name of the collection
# of Redmine's data is a setting that can change (D-44), so it has to be kept with each search. Rows from before are empty.
class AddCollectionAndSourcesToSolrSearchLogs < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_logs, :collection, :string
    add_column :solr_search_logs, :external_sources, :text # the collections of the sources, separated by commas
  end
end
