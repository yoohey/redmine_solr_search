# frozen_string_literal: true

require_relative '../light_helper'

# The arithmetic and the reading of the golden query sets (design D-45): no database, no Solr
class GoldenTest < Minitest::Test
  X = SolrSearch::Golden

  def test_a_key_of_the_expectations_is_the_container_of_its_row
    assert_equal 'issue-12', X.container('issue#12')
    assert_equal 'issue-12', X.container('journal#3@issue#12')
    assert_equal 'issue-12', X.container('attachment#7@issue#12')
    assert_nil X.container('custom_field#4@issue#12') # searched only when asked for
    assert_equal 'wiki_page-2', X.container('wiki#2')
    assert_equal 'wiki_page-2', X.container('attachment#7@wiki#2')
    assert_equal 'document-9', X.container('document#9')
    assert_equal 'document-9', X.container('attachment#7@document#9')
    assert_nil X.container('attachment#7@project#1')
    assert_nil X.container('something')
  end

  def test_what_a_user_should_find_is_what_the_records_the_user_may_see_lead_to
    entry = {'records' => [{'visible_to' => %w[admin sato], 'ids' => ['issue#1', 'journal#5@issue#1', 'wiki#3']},
                           {'visible_to' => ['admin'], 'ids' => ['attachment#8@issue#2', 'attachment#9@project#1']}]}
    assert_equal %w[issue-1 wiki_page-3 issue-2], X.wanted(entry, 'admin')
    assert_equal %w[issue-1 wiki_page-3], X.wanted(entry, 'sato')
    assert_equal [], X.wanted(entry, 'anonymous')
    assert_equal [], X.wanted({}, 'admin')
  end

  def test_one_search_of_the_coverage_set
    row = X.coverage_row(%w[a b c], %w[b c d x])
    assert_equal({want: 3, got: 4, hit: 2, leaks: %w[d x], missing: %w[a]}, row)
    assert_equal 0, X.coverage_row(%w[a a], %w[a a])[:leaks].size # duplicates are one container
  end

  def test_the_totals_of_the_coverage_set_are_over_all_the_searches
    rows = [X.coverage_row(%w[a b], %w[a]), X.coverage_row(%w[c], %w[c z])]
    totals = X.coverage_totals(rows)
    assert_equal 3, totals[:expected]
    assert_equal 2, totals[:found]
    assert_equal 1, totals[:leaks]
    assert_in_delta 2.0 / 3, totals[:recall]
    assert_in_delta 2.0 / 3, totals[:precision]
  end

  def test_nothing_to_find_or_found_has_no_ratio_rather_than_a_zero
    totals = X.coverage_totals([X.coverage_row([], [])])
    assert_nil totals[:recall]
    assert_nil totals[:precision]
    assert_equal 0, totals[:leaks]
    assert_nil X.coverage_totals([X.coverage_row(%w[a], [])])[:precision]
    assert_equal 0.0, X.coverage_totals([X.coverage_row(%w[a], [])])[:recall]
  end

  def test_the_best_place_of_a_right_container
    assert_equal 1, X.best_rank(%w[a], %w[a b])
    assert_equal 3, X.best_rank(%w[x c], %w[a b c d])
    assert_equal 2, X.best_rank(%w[d b], %w[a b c d]) # the first of the right ones counts
    assert_nil X.best_rank(%w[z], %w[a b])
    assert_nil X.best_rank(%w[a], [])
  end

  def test_mrr_and_the_share_in_the_first_places
    rows = [{rank: 1, top: 5}, {rank: 2, top: 5}, {rank: 10, top: 5}, {rank: nil, top: 5}]
    totals = X.ranking_totals(rows)
    assert_in_delta (1 + 0.5 + 0.1 + 0) / 4, totals[:mrr]
    assert_equal 2, totals[:found]
    assert_in_delta 0.5, totals[:recall_at_k]
    assert_equal 5, totals[:k]
  end

  def test_each_query_has_its_own_places_to_be_in
    totals = X.ranking_totals([{rank: 3, top: 3}, {rank: 3, top: 2}])
    assert_equal 1, totals[:found]
    assert_equal 3, totals[:k]
  end

  def test_no_queries_has_no_score
    totals = X.ranking_totals([])
    assert_nil totals[:mrr]
    assert_equal 0, totals[:expected]
  end

  def test_the_cases_get_their_defaults
    list = [{'query' => ' 文書管理規程 ', 'expect' => 'wiki_page-10'},
            {'query' => 'q', 'user' => 'sato', 'expect' => %w[issue-1 document-2], 'top' => 3, 'purpose' => 'p'}]
    first, second = X.cases(list)
    assert_equal({query: '文書管理規程', user: 'admin', expect: %w[wiki_page-10], top: 5, purpose: ''}, first)
    assert_equal({query: 'q', user: 'sato', expect: %w[issue-1 document-2], top: 3, purpose: 'p'}, second)
  end

  def test_top_must_be_a_whole_number_of_one_or_more
    ['x', 0, -1, 2.5, ''].each do |top|
      error = assert_raises(X::Invalid, top.inspect) { X.cases([{'query' => 'a', 'expect' => 'wiki_page-1', 'top' => top}]) }
      assert_match(/entry 1/, error.message)
    end
    assert_equal 10, X.cases([{'query' => 'a', 'expect' => 'wiki_page-1', 'top' => '10'}]).first[:top]
  end

  def test_a_bad_entry_is_refused_with_its_place
    assert_raises(X::Invalid) { X.cases('x') }
    assert_raises(X::Invalid) { X.cases(['x']) }
    error = assert_raises(X::Invalid) { X.cases([{'query' => 'a', 'expect' => 'wiki_page-1'}, {'query' => '', 'expect' => 'issue-1'}]) }
    assert_match(/entry 2/, error.message)
    assert_raises(X::Invalid) { X.cases([{'query' => 'a'}]) }
    assert_raises(X::Invalid) { X.cases([{'query' => 'a', 'expect' => 'issue#1'}]) }
  end

  def test_what_went_wrong_is_kept_and_what_went_right_is_not
    rows = [{query: 'ok', user: 'admin', leaks: [], missing: []},
            {query: 'bad', user: 'sato', leaks: %w[issue-9], missing: %w[issue-1 issue-2]}]
    details = X.coverage_details(rows)
    assert_equal 1, details.size
    assert_equal({query: 'bad', user: 'sato', leaks: %w[issue-9], missing_count: 2, missing: %w[issue-1 issue-2]}, details.first)
    ranked = [{query: 'a', user: 'admin', expect: %w[x], rank: 1, top: 5, first: []},
              {query: 'b', user: 'admin', expect: %w[y], rank: 9, top: 5, first: %w[q]},
              {query: 'c', user: 'admin', expect: %w[z], rank: nil, top: 5, first: []}]
    assert_equal %w[b c], X.ranking_details(ranked).map {|d| d[:query]}
  end
end
