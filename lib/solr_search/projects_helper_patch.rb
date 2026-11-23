# frozen_string_literal: true

module SolrSearch
  # Extends ProjectsHelper to add the full-text search tab to project settings (design D-34).
  module ProjectsHelperPatch
    include SolrSearchAdminHelper

    def project_settings_tabs
      tabs = super
      if @project.module_enabled?(:solr_search) && User.current.allowed_to?(:manage_solr_search_sources, @project)
        tabs << {
          name: 'solr_search',
          action: :manage_solr_search_sources,
          module: :solr_search,
          partial: 'projects/settings/solr_search',
          label: :label_solr_search
        }
      end
      tabs
    end
  end
end
