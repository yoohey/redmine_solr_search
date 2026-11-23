# frozen_string_literal: true

# What the controllers of Administration > Full-text search have in common (design D-28; Q-40): the admin layout and menu, the helpers,
# only for administrators, and the views, which are all in app/views/solr_search_admin because the tabs share partials.
class SolrSearchAdminBaseController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :solr_search

  helper :solr_search_admin
  before_action :require_admin

  class << self
    private

    # a view is looked for in the controller's own folder, then in the admin page's
    def local_prefixes
      [controller_path, 'solr_search_admin']
    end
  end

  private

  # The admin page's patience with Solr (Status, design D-28)
  def admin_client
    SolrSearch::Status.admin_client
  end
end
