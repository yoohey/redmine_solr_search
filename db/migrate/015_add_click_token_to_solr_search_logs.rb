# frozen_string_literal: true

# The mark of a search that its screen sends back with each click (design D-45; M6 review 2). Only the page that the search
# was made for knows it, so a click can be taken only from there: the number of the log row is a running number that anyone
# can guess, and a user who is not logged in has no user to compare. Rows from before have none: they take no clicks.
class AddClickTokenToSolrSearchLogs < ActiveRecord::Migration[SolrSearch.migration_version]
  def change
    add_column :solr_search_logs, :click_token, :string, limit: 32
  end
end
