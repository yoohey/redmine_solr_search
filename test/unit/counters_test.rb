# frozen_string_literal: true

require_relative '../light_helper'

# The counts that a search or a click adds (design D-45): which are added together, and in which order (the adding itself
# is the database's: docs/experiments/q18-search-log/concurrency_check.rb)
class CountersTest < Minitest::Test
  X = SolrSearch::Counters

  def test_the_same_key_is_added_once_with_the_sum
    assert_equal [['a', 3], ['b', 1]], X.merge([['a', 1], ['b', 1], ['a', 2]])
  end

  def test_the_keys_come_in_one_order_whatever_the_order_they_were_given_in
    one = X.merge([['searches:found', 1], ['duration:sum_ms', 40], ['hits:count', 1]])
    other = X.merge([['hits:count', 1], ['searches:found', 1], ['duration:sum_ms', 40]])
    assert_equal one, other
    assert_equal one.map(&:first).sort, one.map(&:first)
  end

  def test_nothing_to_add_is_nothing
    assert_equal [], X.merge([])
  end

  def test_what_a_search_adds_is_merged_without_losing_any_of_it
    increments = SolrSearch::SearchStats.search_increments(page: 1, hit_count: 30, took_ms: 80, dropped_count: 0, error: nil)
    merged = X.merge(increments)
    assert_equal increments.sum {|_k, n| n }, merged.sum {|_k, n| n }
    assert_equal increments.map(&:first).uniq.size, merged.size
  end
end
