# frozen_string_literal: true

require_relative '../light_helper'

# The permission filter written from the user's side (design D-30). Whether it lets through what Redmine shows is
# checked on the seed data (docs/experiments/perm-m2); here, only its shape.
class PermissionFilterTest < Minitest::Test
  Role = SolrSearch::PermissionFilter::Role

  def filter(roles, logged: true, private_notes: [], wiki: [], documents: [], files: [])
    SolrSearch::PermissionFilter.new(user_id: 5, principal_ids: [5, 9], logged: logged, issue_roles: roles,
                                     private_notes_project_ids: private_notes, wiki_project_ids: wiki,
                                     document_project_ids: documents, file_project_ids: files).to_s
  end

  def role(ids, visibility = 'all', trackers = nil)
    Role.new(project_ids: ids, issues_visibility: visibility, tracker_ids: trackers)
  end

  NOTES = 'type:issue OR is_private_note:false OR note_author_id:5'

  def test_nothing_to_see
    assert_equal '-*:*', filter([])
    assert_equal '-*:*', filter([role([])], wiki: [])
  end

  def test_all_visibility_is_projects_alone
    assert_equal "source:redmine AND ((type:(issue OR journal) AND (({!terms f=project_id v='1,2'})) AND (#{NOTES})) OR " \
                 "(type:attachment AND container_type:issue AND (({!terms f=project_id v='1,2'}))))",
                 filter([role([2, 1, 2])])
  end

  def test_default_and_own_visibility
    own = "author_id:5 OR {!terms f=assigned_to_id v='5,9'}"
    assert_includes filter([role([1], 'default')]), "({!terms f=project_id v='1'} AND (is_private:false OR #{own}))"
    assert_includes filter([role([1], 'own')]), "({!terms f=project_id v='1'} AND (#{own}))"
  end

  def test_unknown_visibility_passes_nothing
    assert_equal '-*:*', filter([role([1], 'something')])
  end

  def test_anonymous_is_not_private_whatever_the_role
    %w[all default own].each do |visibility|
      assert_includes filter([role([1], visibility)], logged: false), "({!terms f=project_id v='1'} AND is_private:false)"
    end
  end

  def test_no_user_id_no_own_notes
    f = SolrSearch::PermissionFilter.new(user_id: nil, principal_ids: [], logged: false, issue_roles: [role([1])],
                                         private_notes_project_ids: [], wiki_project_ids: [],
                                         document_project_ids: []).to_s
    assert_includes f, '(type:issue OR is_private_note:false)'
    refute_includes f, 'note_author_id'
  end

  def test_trackers_inside_the_role
    f = filter([role([1], 'all', [3, 4]), role([2], 'default')])
    assert_includes f, "({!terms f=project_id v='1'} AND {!terms f=tracker_id v='3,4'})"
    assert_includes f, " OR ({!terms f=project_id v='2'} AND (is_private:false OR "
  end

  def test_a_role_with_no_tracker_makes_no_clause
    assert_equal '-*:*', filter([role([1], 'all', [])])
    refute_includes filter([role([1], 'all', []), role([2])]), "v='1'"
  end

  def test_private_notes_permission
    assert_includes filter([role([1])], private_notes: [1]), "(#{NOTES} OR {!terms f=project_id v='1'})"
  end

  def test_wiki_and_documents_by_project
    assert_equal "source:redmine AND ((type:wiki_page AND {!terms f=project_id v='3'}) OR " \
                 "(type:document AND {!terms f=project_id v='4'}) OR " \
                 "(type:attachment AND container_type:wiki_page AND {!terms f=project_id v='3'}) OR " \
                 "(type:attachment AND container_type:document AND {!terms f=project_id v='4'}))",
                 filter([], wiki: [3], documents: [4])
  end

  def test_ids_must_be_integers
    assert_raises(ArgumentError) { filter([role(['1) OR (*:*'])]) }
  end

  # Attachments (design D-36): Attachment#visible? asks the container, and its permission for that kind of container
  def test_the_attachments_of_issues_have_the_roles_conditions_but_not_the_notes
    clause = "(type:attachment AND container_type:issue AND (({!terms f=project_id v='1'} AND (is_private:false OR " \
             "author_id:5 OR {!terms f=assigned_to_id v='5,9'}) AND {!terms f=tracker_id v='3'})))"
    assert_includes filter([role([1], 'default', [3])]), clause
    refute_includes clause, 'is_private_note'
  end

  def test_the_attachments_of_a_wiki_page_a_document_and_the_files_module
    f = filter([], wiki: [4, 3], documents: [5], files: [6, 2])
    assert_equal "source:redmine AND ((type:wiki_page AND {!terms f=project_id v='3,4'}) OR " \
                 "(type:document AND {!terms f=project_id v='5'}) OR " \
                 "(type:attachment AND container_type:wiki_page AND {!terms f=project_id v='3,4'}) OR " \
                 "(type:attachment AND container_type:document AND {!terms f=project_id v='5'}) OR " \
                 "(type:attachment AND container_type:(project OR version) AND {!terms f=project_id v='2,6'}))", f
  end

  def test_the_files_module_alone_gives_only_the_attachments_of_projects_and_versions
    assert_equal "source:redmine AND ((type:attachment AND container_type:(project OR version) AND {!terms f=project_id v='6'}))",
                 filter([], files: [6])
  end

  def test_no_permission_for_a_kind_no_attachments_of_it
    f = filter([role([1])], wiki: [], documents: [], files: [])
    refute_includes f, 'container_type:wiki_page'
    refute_includes f, 'container_type:document'
    refute_includes f, 'container_type:(project OR version)'
  end
end
