# frozen_string_literal: true

require_relative '../light_helper'

# What a search and a click add to the counts that Prometheus reads (design D-45)
class SearchStatsTest < Minitest::Test
  S = SolrSearch::SearchStats

  def search(**over)
    S.search_increments(**{page: 1, hit_count: 30, took_ms: 120, dropped_count: 0, error: nil}.merge(over)).to_h
  end

  def test_the_bucket_is_the_smallest_bound_that_is_not_less
    assert_equal 'duration:le:25', S.bucket_key('duration', S::DURATION_MS, 0)
    assert_equal 'duration:le:25', S.bucket_key('duration', S::DURATION_MS, 25)
    assert_equal 'duration:le:50', S.bucket_key('duration', S::DURATION_MS, 26)
    assert_equal 'duration:le:10000', S.bucket_key('duration', S::DURATION_MS, 10_000)
    assert_equal 'duration:le:inf', S.bucket_key('duration', S::DURATION_MS, 10_001)
    assert_equal 'hits:le:0', S.bucket_key('hits', S::HITS, 0)
  end

  def test_a_search_that_found_something
    got = search
    assert_equal 1, got['searches:found']
    assert_equal [1, 120, 1], [got['duration:le:250'], got['duration:sum_ms'], got['duration:count']]
    assert_equal [1, 30, 1], [got['hits:le:100'], got['hits:sum'], got['hits:count']]
    refute got.key?('dropped_groups')
  end

  def test_a_search_with_no_hit_is_zero_and_in_the_zero_hit_bucket
    got = search(hit_count: 0)
    assert_equal 1, got['searches:zero']
    assert_equal 1, got['hits:le:0']
  end

  def test_a_search_that_failed_counts_only_as_failed
    assert_equal({'searches:failed' => 1}, search(hit_count: nil, took_ms: 5, error: 'down'))
  end

  def test_a_second_page_is_not_a_search_nor_a_hit_count_but_has_a_time
    got = search(page: 2)
    refute(got.keys.any? {|key| key.start_with?('searches:') || key.start_with?('hits:') })
    assert_equal 1, got['duration:count']
  end

  def test_a_second_page_that_failed_adds_nothing
    assert_empty search(page: 2, hit_count: nil, error: 'down')
  end

  def test_the_groups_that_were_dropped_are_added
    assert_equal 3, search(dropped_count: 3)['dropped_groups']
  end

  def test_a_click
    got = S.click_increments(kind: 'title', rank: 3, first_click: true).to_h
    assert_equal [1, 1, 1], [got['clicks:total'], got['clicks:kind:title'], got['searches_with_click']]
    assert_equal [1, 3, 1], [got['click_rank:le:3'], got['click_rank:sum'], got['click_rank:count']]
  end

  def test_a_click_after_the_first_does_not_count_the_search_again
    refute S.click_increments(kind: 'note', rank: 1, first_click: false).to_h.key?('searches_with_click')
  end

  def test_an_unknown_kind_is_other_and_no_rank_adds_no_rank
    got = S.click_increments(kind: 'whatever', rank: nil, first_click: false).to_h
    assert_equal 1, got['clicks:kind:other']
    refute(got.keys.any? {|key| key.start_with?('click_rank') })
  end

  def test_every_key_fits_the_column
    keys = S::DURATION_MS.map {|b| "duration:le:#{b}" } + S::HITS.map {|b| "hits:le:#{b}" } + S::RANK.map {|b| "click_rank:le:#{b}" }
    assert keys.all? {|key| key.size <= 100 }
  end
end
