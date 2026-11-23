# frozen_string_literal: true

require_relative '../light_helper'

# The id of a container (design D-27; Q-40)
class GroupIdTest < Minitest::Test
  G = SolrSearch::GroupId

  def test_the_kind_and_the_number
    assert_equal ['issue', 12], G.parse('issue-12')
    assert_equal ['wiki_page', 5], G.parse('wiki_page-5')
    assert_equal 'document', G.kind('document-3')
    assert_equal 'issue-12', G.build('issue', 12)
  end

  def test_an_id_of_another_form_has_neither
    ['file://fileserver/部門01/a-12', 'issue', 'issue-', 'issue-x', '-12', 'Issue-12', 'issue-12-3', '', nil].each do |id|
      assert_nil G.parse(id), id.inspect
      assert_nil G.kind(id), id.inspect
    end
  end

  def test_the_numbers_of_a_list_by_kind
    found = G.numbers_by_kind(%w[issue-12 issue-3 document-7 file://x/y-1 version-2 wiki_page-9])
    assert_equal({'issue' => [12, 3], 'document' => [7], 'version' => [2], 'wiki_page' => [9]}, found)
    assert_nil found['project'], 'a kind that is not there is nil (no default)'
    assert_equal({}, G.numbers_by_kind([]))
  end
end
