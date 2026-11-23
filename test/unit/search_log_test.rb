# frozen_string_literal: true

require_relative '../light_helper'

# The row that a search leaves in the log (design D-45)
class SearchLogTest < Minitest::Test
  User = Struct.new(:id, :login, :logged?)
  Result = Struct.new(:hit_count, :group_count)

  def attrs(**over)
    SolrSearch::SearchLog.attributes(
      **{user: User.new(7, 'tanaka', true), query: 'nginx 設定', request_path: '/solr_search?q=nginx', project_id: nil, page: 1,
         took_ms: 12, result: Result.new(30, 20), shown: 20, shown_of: 20}.merge(over)
    )
  end

  def test_a_search_that_found_something
    a = attrs
    assert_equal [7, 'tanaka', 'nginx 設定', 1, 30, 20, 0, 12, nil],
                 a.values_at(:user_id, :user_login, :query, :page, :hit_count, :group_count, :dropped_count, :took_ms, :error)
  end

  def test_the_collection_and_the_external_sources_searched_are_kept
    a = attrs(collection: 'redmine_prod', sources: %w[src_12 src_13])
    assert_equal ['redmine_prod', 'src_12,src_13'], a.values_at(:collection, :external_sources)
  end

  def test_no_external_source_is_nil_not_an_empty_text
    assert_nil attrs(collection: 'redmine', sources: [])[:external_sources]
    assert_nil attrs[:external_sources]
  end

  def test_a_visitor_has_no_user
    a = attrs(user: User.new(2, 'anonymous', false))
    assert_nil a[:user_id]
    assert_nil a[:user_login]
  end

  def test_the_groups_that_the_screen_did_not_show_are_counted
    assert_equal 3, attrs(shown: 17, shown_of: 20)[:dropped_count]
  end

  def test_a_search_that_failed_has_no_counts_and_the_reason
    a = attrs(result: nil, shown: nil, shown_of: nil, error: 'Solr unreachable')
    assert_nil a[:hit_count]
    assert_nil a[:dropped_count]
    assert_equal 'Solr unreachable', a[:error]
  end

  def test_a_search_with_no_hit_keeps_its_zero
    a = attrs(result: Result.new(0, 0), shown: 0, shown_of: 0)
    assert_equal 0, a[:hit_count]
  end

  def test_long_texts_are_cut
    a = attrs(query: 'あ' * 5000, request_path: 'x' * 9000, error: 'e' * 900)
    assert_equal SolrSearch::SearchLog::QUERY_MAX, a[:query].size
    assert_equal SolrSearch::SearchLog::PATH_MAX, a[:request_path].size
    assert_equal SolrSearch::SearchLog::ERROR_MAX, a[:error].size
  end

  def test_each_search_has_a_mark_of_its_own_that_its_screen_sends_back_with_clicks
    first = attrs[:click_token]
    assert_match(/\A\h{32}\z/, first)
    refute_equal first, attrs[:click_token]
    assert_equal 'f' * 32, attrs(click_token: 'f' * 32)[:click_token]
  end

  def test_the_error_fits_a_column_of_255_characters
    assert_equal 255, attrs(error: 'x' * 1000)[:error].size
  end
end
