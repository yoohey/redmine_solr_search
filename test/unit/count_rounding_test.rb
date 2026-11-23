# frozen_string_literal: true

require_relative '../light_helper'

# Q-48: the count on the screen keeps its two leading digits from 100 up
class CountRoundingTest < Minitest::Test
  def round(count)
    SolrSearch::CountRounding.round(count)
  end

  def test_small_counts_are_as_they_are
    assert_equal 0, round(0)
    assert_equal 87, round(87)
    assert_equal 99, round(99)
  end

  def test_from_100_up_two_leading_digits_are_kept
    assert_equal 100, round(100)
    assert_equal 120, round(123)
    assert_equal 990, round(989)
    assert_equal 1_200, round(1_234)
    assert_equal 35_000, round(34_567)
    assert_equal 1_200_000, round(1_234_567)
  end

  def test_rounding_up_into_the_next_digit
    assert_equal 1_000, round(999)
    assert_equal 100_000, round(99_999)
  end

  def test_nil_stays_nil
    assert_nil round(nil)
  end
end
