# frozen_string_literal: true

# The first click of a search is marked on the search's own row (design D-45; M6 review 9, 10). It says "this search had
# something opened" without a subquery over the clicks (the list and the totals of the log screen asked "which searches
# are not among the clicks", which gets slow as the clicks grow), and the first click is decided by one UPDATE
# (clicked_at IS NULL), so two clicks at once cannot both be the first, or neither. The clicks get an index on what was
# opened (the top of what is opened, and its title, group by it).
class AddClickedAtAndClickGroupIndex < ActiveRecord::Migration[SolrSearch.migration_version]
  def up
    add_column :solr_search_logs, :clicked_at, :datetime
    # the searches that were clicked before this: the time of their first click (plain SQL, the same on every database)
    execute <<~SQL.squish
      UPDATE solr_search_logs SET clicked_at =
        (SELECT MIN(created_at) FROM solr_search_clicks WHERE solr_search_clicks.log_id = solr_search_logs.id)
      WHERE EXISTS (SELECT 1 FROM solr_search_clicks WHERE solr_search_clicks.log_id = solr_search_logs.id)
    SQL
    add_index :solr_search_clicks, :group_id
  end

  def down
    remove_index :solr_search_clicks, :group_id
    remove_column :solr_search_logs, :clicked_at
  end
end
