# frozen_string_literal: true

module SolrSearch
  # Which external index sources a user may search (design D-32, D-33): the sources linked to a project where the user
  # has both permissions :search_external_sources and :use_solr_search (module on, project not archived; a closed
  # project counts, the permissions only read; an admin has them in every project with the module on; the built-in
  # roles for a non member and the anonymous user count only if given them). Read on every search, so that a change
  # of role, module or link applies at once.
  module SourceAccess
    PERMISSION = :search_external_sources
    # PERMISSION only adds to this one: both in the same project (D-32, 2026-10-17). Redmine cannot declare a
    # permission depending on another, so a role may have PERMISSION alone; it then gives nothing.
    SEARCH_PERMISSION = :use_solr_search

    # {project id => collection names} for the projects where the user has both permissions: which external sources a
    # project brings (D-49: the count of a project in the facet is its own documents and those of its sources).
    def self.by_project(user)
      allowed = PermissionFilter.project_ids(user, PERMISSION)
      allowed &= PermissionFilter.project_ids(user, SEARCH_PERMISSION) if allowed.any?
      return {} if allowed.empty?

      SolrSearchProjectSource.joins(:source).where(project_id: allowed)
                             .pluck(:project_id, 'solr_search_sources.collection')
                             .select {|_, name| SolrSearch.external_collection?(name)}
                             .group_by(&:first).transform_values {|rows| rows.map(&:last).uniq.sort }
    end

    # Collection names, sorted and without duplicates: what goes into Solr's collection parameter and into the
    # filter of source values (D-33). project_ids: only the links of those projects (the screen's own narrowing, D-33),
    # or nil for every project the user has both permissions in. Empty: nothing external to ask.
    def self.collections(user, project_ids: nil)
      allowed = PermissionFilter.project_ids(user, PERMISSION)
      allowed &= PermissionFilter.project_ids(user, SEARCH_PERMISSION) if allowed.any?
      allowed &= project_ids.to_a unless project_ids.nil?
      return [] if allowed.empty?

      SolrSearchSource.joins(:project_sources)
                      .where(solr_search_project_sources: {project_id: allowed})
                      .distinct.pluck(:collection)
                      # the name goes into the filter as it is: only what a source may be (D-35)
                      .select {|name| SolrSearch.external_collection?(name)}.sort
    end
  end
end
