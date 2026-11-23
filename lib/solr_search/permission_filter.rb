# frozen_string_literal: true

module SolrSearch
  # The permission filter of the search screen (design D-30): Redmine's own conditions (Issue.visible_condition,
  # Journal.visible_notes_condition, Project.allowed_to_condition) written as one Solr filter query, so that what
  # Solr counts and pages is close to what Redmine shows. It is not the last word: the screen checks every hit with
  # Redmine's visible? before showing it.
  #
  # Two halves: .for(user) reads the user's side from Redmine (read on every search, so a change of role or
  # membership applies at once), and #to_s writes the filter from those plain values (no database; test/unit).
  class PermissionFilter
    # One role's share of the issue condition: the projects where the user has it, its "issues visibility"
    # ('all', 'default', 'own'), and the trackers it may view (nil: all of them).
    # A filter that lets nothing through; the Searcher compares with it, so there is one spelling of it
    NOTHING = '-*:*'

    Role = Struct.new(:project_ids, :issues_visibility, :tracker_ids, keyword_init: true)

    # admin: Redmine skips the roles for an admin; the one role given then stands for the projects alone.
    # logged: false for the anonymous user, who is held to "not private" whatever the role says (Redmine does so).
    # principal_ids: the user and their groups (an issue can be assigned to a group).
    # private_notes_project_ids: where the user may see others' private notes.
    # file_project_ids: where the user has view_files (the "Files" module: the attachments of a project and of its versions).
    attr_reader :user_id, :principal_ids, :logged, :issue_roles, :private_notes_project_ids,
                :wiki_project_ids, :document_project_ids, :file_project_ids

    def initialize(user_id:, principal_ids:, logged:, issue_roles:, private_notes_project_ids:,
                   wiki_project_ids:, document_project_ids:, file_project_ids: [])
      @user_id = user_id
      @principal_ids = principal_ids
      @logged = logged
      @issue_roles = issue_roles
      @private_notes_project_ids = private_notes_project_ids
      @wiki_project_ids = wiki_project_ids
      @document_project_ids = document_project_ids
      @file_project_ids = file_project_ids
    end

    def self.for(user)
      new(user_id: user.id,
          principal_ids: [user.id, *user.groups.pluck(:id)].compact,
          logged: user.logged?,
          issue_roles: issue_roles(user),
          private_notes_project_ids: project_ids(user, :view_private_notes, skip_pre_condition: true),
          wiki_project_ids: project_ids(user, :view_wiki_pages),
          document_project_ids: project_ids(user, :view_documents),
          file_project_ids: project_ids(user, :view_files))
    end

    def self.project_ids(user, permission, options = {})
      Project.where(Project.allowed_to_condition(user, permission, options)).pluck(:id)
    end

    # The roles as Project.allowed_to_condition(user, :view_issues) walks them: the built-in role (non member or
    # anonymous) on public projects the user is no member of, then each role the user has through memberships (the
    # built-in groups' roles included). Each role's projects are cut down to the projects that pass the condition
    # as a whole, which brings in its first part (project status, the issue tracking module).
    def self.issue_roles(user)
      allowed = project_ids(user, :view_issues)
      return [Role.new(project_ids: allowed, issues_visibility: 'all', tracker_ids: nil)] if user.admin?

      project_ids_by_role(user).filter_map do |role, ids|
        next unless role.allowed_to?(:view_issues) && ids.any?

        trackers = role.permissions_all_trackers?(:view_issues) ? nil : role.permissions_tracker_ids(:view_issues)
        Role.new(project_ids: ids & allowed, issues_visibility: role.issues_visibility, tracker_ids: trackers)
      end
    end

    # {Role => project ids}: the user's roles as User#roles_for_project gives them, project by project. The built-in
    # role (non member or anonymous) on public projects where neither the user nor the built-in group is a member;
    # each role the user has through memberships, the built-in group's roles included (Project#override_roles).
    # Archived projects are left out. Shared with CustomFieldQuery (IssueCustomField#visible_by?).
    def self.project_ids_by_role(user)
      by_role = {user.builtin_role => builtin_role_project_ids(user)}
      user.project_ids_by_role.each {|role, ids| by_role[role] = (by_role[role] || []) | ids}
      by_role
    end

    def self.builtin_role_project_ids(user)
      projects = Project.where(is_public: true).where.not(status: Project::STATUS_ARCHIVED)
      if user.id
        group = user.anonymous? ? Group.anonymous : Group.non_member
        projects = projects.where.not(id: Member.where(user_id: [user.id, group.id].compact).select(:project_id))
      end
      projects.pluck(:id)
    end
    private_class_method :builtin_role_project_ids

    # Every operator is written out, so the request's q.op and sow cannot change the meaning (design chapter 5).
    def to_s
      clauses = [*issue_clauses, project_clause('wiki_page', wiki_project_ids), project_clause('document', document_project_ids),
                 *attachment_clauses].compact
      return NOTHING if clauses.empty? # nothing to see

      "source:#{SOURCE} AND (#{clauses.join(' OR ')})"
    end

    private

    # The issues, their notes, and the attachments of the issues (design D-36: Attachment#visible? asks the issue, so the
    # attachments have the roles' conditions of the issue, and not the notes')
    def issue_clauses
      roles = issue_roles.filter_map {|role| role_clause(role)}
      return [] if roles.empty?

      ["(type:(issue OR journal) AND (#{roles.join(' OR ')}) AND (#{notes_condition}))",
       "(type:attachment AND container_type:issue AND (#{roles.join(' OR ')}))"]
    end

    # The attachments of the other containers (design D-36; Redmine's attachments_visible?): of a wiki page, view_wiki_pages
    # in its project; of a document, view_documents; of a project or one of its versions, view_files (a version's in the
    # version's own project)
    def attachment_clauses
      [attachment_clause('wiki_page', wiki_project_ids), attachment_clause('document', document_project_ids),
       attachment_clause('(project OR version)', file_project_ids)]
    end

    def attachment_clause(container_types, ids)
      return if ids.empty?

      "(type:attachment AND container_type:#{container_types} AND #{terms('project_id', ids)})"
    end

    # Journal.visible_notes_condition. Issues have no is_private_note, so they pass by their type.
    # Redmine's anonymous user is a row of users and has an id; without one, no note is one's own.
    def notes_condition
      parts = ['type:issue', 'is_private_note:false']
      parts << "note_author_id:#{Integer(user_id)}" if user_id
      parts << terms('project_id', private_notes_project_ids) if private_notes_project_ids.any?
      parts.join(' OR ')
    end

    def role_clause(role)
      return if role.project_ids.empty?
      return if role.tracker_ids&.empty? # a role that may view no tracker sees nothing

      visibility = visibility_condition(role.issues_visibility)
      return if visibility == false

      parts = [terms('project_id', role.project_ids)]
      parts << visibility if visibility
      parts << terms('tracker_id', role.tracker_ids) if role.tracker_ids
      "(#{parts.join(' AND ')})"
    end

    # nil: no condition; false: nothing passes
    def visibility_condition(issues_visibility)
      return 'is_private:false' unless logged

      own = "author_id:#{Integer(user_id)} OR #{terms('assigned_to_id', principal_ids)}"
      case issues_visibility
      when 'all' then nil
      when 'default' then "(is_private:false OR #{own})"
      when 'own' then "(#{own})"
      else false
      end
    end

    def project_clause(type, ids)
      return if ids.empty?

      "(type:#{type} AND #{terms('project_id', ids)})"
    end

    def terms(field, ids)
      self.class.terms(field, ids)
    end

    # A set of ids as one query, whatever its size ({!terms}; a plain OR list hits maxBooleanClauses, M1 review D1)
    def self.terms(field, ids)
      "{!terms f=#{field} v='#{ids.map {|id| Integer(id)}.uniq.sort.join(',')}'}"
    end
  end
end
