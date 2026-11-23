# frozen_string_literal: true

# What a request from the admin page asks for (design D-42): JSON, {"types" => [...]}. Empty for the runs that the
# scheduler and rake start on their own.
class AddRequestOptionsToSolrSearchRuns < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_runs, :request_options, :text
  end
end
