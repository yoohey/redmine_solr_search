# frozen_string_literal: true

# The query expansion dictionary starts with a few groups (config/default_synonyms.txt; design D-53): they show what the tab is for,
# and a search for either word of a group finds both. Put in once, when the plugin is installed: nothing is put in when there
# is a dictionary already (an environment that had one before this migration keeps it), and a dictionary emptied later is not
# filled again (the migration does not run twice). The row is the first of the history (user "(install)").
class AddDefaultSolrSearchSynonyms < ActiveRecord::Migration[SolrSearch.migration_version]
  FILE = File.expand_path('../../config/default_synonyms.txt', __dir__)
  INSTALL_LOGIN = '(install)'

  class Row < ActiveRecord::Base
    self.table_name = 'solr_search_synonyms'
  end

  def up
    Row.reset_column_information
    return if Row.exists?

    Row.create!(user_login: INSTALL_LOGIN, body: File.read(FILE, encoding: 'UTF-8'), created_at: Time.current)
  end

  def down
    Row.where(user_login: INSTALL_LOGIN).delete_all
  end
end
