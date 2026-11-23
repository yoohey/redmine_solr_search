# frozen_string_literal: true

module SolrSearch
  # The issue custom fields a user searches with "include attributes" (design D-31, R10): the searchable text fields
  # the user may see, and where. Like PermissionFilter, two halves: .for(user) reads Redmine (on every search), and the
  # rest writes the query's parts from those plain values (no database; test/unit).
  #
  # A field for all users (and every field, for an admin) is searched like the subject and description: its fields
  # join the main clause's qf. A field shown to some roles only is searched in the projects where the user has one of
  # them: a clause of its own, ({!edismax qf=... v=$uq} AND {!terms f=project_id ...}), one per set of projects.
  class CustomFieldQuery
    # project_ids: where the user may see the field; nil: wherever the user sees the issue
    Field = Struct.new(:id, :project_ids, keyword_init: true)

    attr_reader :fields

    def initialize(fields)
      @fields = fields
    end

    # IssueCustomField#visible_by?(project, user) for the projects where the user may see issues: the field is for all
    # users, or the user is an admin, or one of the field's roles is the user's role in that project. The user's roles
    # per project are those of Redmine's roles_for_project (PermissionFilter.project_ids_by_role).
    def self.for(user)
      custom_fields = IssueCustomField.where(searchable: true, field_format: RedmineDocuments::CUSTOM_FIELD_TEXT_FORMATS)
                                      .sorted.preload(:roles, :projects).to_a
      new(visible(custom_fields, user).map {|cf, project_ids| Field.new(id: cf.id, project_ids: project_ids)})
    end

    # [[custom field, project ids or nil], ...]: the fields the user may see, and in which projects (nil: wherever the user sees
    # the issue). Shared by the searched fields and the facets.
    def self.visible(custom_fields, user)
      return [] if custom_fields.empty?
      return custom_fields.map {|cf| [cf, nil]} if user.admin?

      by_role_id = PermissionFilter.project_ids_by_role(user).transform_keys(&:id)
      issue_project_ids = PermissionFilter.project_ids(user, :view_issues)
      custom_fields.filter_map do |cf|
        next [cf, nil] if cf.visible?

        ids = cf.roles.flat_map {|role| by_role_id[role.id] || []} & issue_project_ids
        ids &= cf.project_ids unless cf.is_for_all? # no issue elsewhere has the field: a shorter set
        [cf, ids.uniq.sort] if ids.any?
      end
    end

    # A custom field of the facets (D-49): kind is :values (chosen from a list of values: checkboxes), :number or :date (a range)
    Facet = Struct.new(:id, :name, :field_format, :kind, :project_ids, keyword_init: true)
    KINDS = {'int' => :number, 'float' => :number, 'date' => :date}.freeze

    # The issue custom fields that are used as a filter ("is_filter": Redmine's choice of what a list of issues can be narrowed by)
    # and that the user may see, with where (project_ids; nil: everywhere). Read on every search.
    def self.facets_for(user)
      custom_fields = IssueCustomField.where(is_filter: true, field_format: RedmineDocuments::CUSTOM_FIELD_FACET_FORMATS)
                                      .sorted.preload(:roles, :projects).to_a
      visible(custom_fields, user).map do |cf, project_ids|
        Facet.new(id: cf.id, name: cf.name, field_format: cf.field_format, kind: KINDS.fetch(cf.field_format, :values),
                  project_ids: project_ids)
      end
    end

    def empty?
      fields.empty?
    end

    # Fields of the main clause (beside the subject and description). exact: the n-gram copies only (D-24 R9).
    def main_fields(exact:)
      solr_fields(fields.select {|f| f.project_ids.nil?}, exact)
    end

    # [[clause, {parameter => qf}], ...]: one clause per set of projects, its qf in a parameter of its own
    def clauses(exact:)
      fields.reject {|f| f.project_ids.nil?}.group_by(&:project_ids).each_with_index.map do |(project_ids, group), i|
        name = "cfqf#{i}"
        ["({!edismax qf=$#{name} v=$uq} AND #{PermissionFilter.terms('project_id', project_ids)})",
         {name.to_sym => solr_fields(group, exact).join(' ')}]
      end
    end

    # The stored copies, for snippets. Solr returns them for any issue that matched, also where the field is hidden:
    # the screen drops those (D-31, docs/experiments/cf-d31 round 1).
    def highlight_fields
      fields.map {|f| "cft_#{Integer(f.id)}"}
    end

    private

    def solr_fields(fields, exact)
      fields.flat_map do |f|
        id = Integer(f.id)
        exact ? ["cft_#{id}"] : ["cfj_#{id}", "cft_#{id}"]
      end
    end
  end
end
