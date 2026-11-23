# frozen_string_literal: true

require_relative '../light_helper'
require 'set'

# Which hits are external documents, and which are Redmine's (second guard before display; security review 2026-10-06, 1)
class ExternalHitsTest < Minitest::Test
  Hit = SolrSearch::Searcher::Hit
  Group = SolrSearch::Searcher::Group

  def file(source, id = 'file://fs/a.docx')
    Hit.new(id: id, type: 'file', source: source)
  end
  def redmine(type = 'issue', source = 'redmine')
    Hit.new(id: "#{type}-12", type: type, item_id: 12, source: source)
  end

  def sort_out(groups, sources = %w[src_901])
    ids = SolrSearch::ExternalHits.sort_out(groups, sources)
    [ids, groups.map(&:hits)]
  end

  def test_an_external_document_of_a_source_asked_for_is_kept
    g = Group.new(group_id: 'file://fs/a.docx', hits: [file('src_901')])
    ids, hits = sort_out([g])
    assert_equal Set['file://fs/a.docx'], ids
    assert_equal [[g.hits.first]], hits
  end

  def test_an_external_document_of_another_source_is_dropped
    g = Group.new(group_id: 'file://fs/a.docx', hits: [file('src_902')])
    ids, hits = sort_out([g])
    assert_empty ids
    assert_equal [[]], hits
  end

  def test_a_group_of_redmine_stays_redmine_whatever_rode_along
    # an external document that took the group id of an issue: its hit goes, the group is looked up in Redmine
    g = Group.new(group_id: 'issue-12', hits: [redmine, file('src_901', 'issue-12')])
    ids, hits = sort_out([g])
    assert_empty ids
    assert_equal ['issue'], hits.first.map(&:type)
  end

  def test_a_hit_that_says_it_is_redmines_must_have_redmine_as_its_source
    # a document of a source that gives itself the type of an issue (the filter holds the type, this is the second guard)
    g = Group.new(group_id: 'issue-12', hits: [redmine('issue', 'src_901')])
    ids, hits = sort_out([g])
    assert_empty ids
    assert_equal [[]], hits
  end

  def test_without_the_source_field_nothing_external_can_have_come
    g = Group.new(group_id: 'issue-12', hits: [redmine('issue', nil)])
    ids, hits = sort_out([g], [])
    assert_empty ids
    assert_equal 1, hits.first.size
  end

  def test_each_group_on_its_own
    a = Group.new(group_id: 'file://fs/a.docx', hits: [file('src_901')])
    b = Group.new(group_id: 'wiki_page-3', hits: [redmine('wiki_page')])
    ids, hits = sort_out([a, b])
    assert_equal Set['file://fs/a.docx'], ids
    assert_equal [1, 1], hits.map(&:size)
  end
end
