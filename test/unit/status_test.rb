# frozen_string_literal: true

require_relative '../light_helper'

# The admin page's marks on replicas that differ (M1 review A5; docs/experiments/crawl-m1 round 8)
class StatusTest < Minitest::Test
  T1 = Time.utc(2026, 9, 29, 13, 20)
  T0 = Time.utc(2026, 9, 29, 12, 50)

  def flags(*views)
    replicas = views.map {|num_docs, newest| SolrSearch::Status::Replica.new(num_docs: num_docs, newest: newest)}
    SolrSearch::Status.flag(replicas).map(&:flag)
  end

  def test_all_the_same
    assert_equal [nil, nil], flags([15_173, T1], [15_173, T1])
  end

  def test_an_older_newest_is_behind
    assert_equal [nil, :behind], flags([15_173, T1], [15_170, T0])
  end

  def test_same_newest_different_counts_marks_them_all
    assert_equal %i[count_differs count_differs], flags([15_177, T1], [15_173, T1])
    assert_equal %i[count_differs count_differs count_differs], flags([15_173, T1], [15_177, T1], [15_173, T1])
  end

  def test_no_response
    assert_equal [nil, :no_response], flags([15_173, T1], [nil, nil])
    assert_equal [nil, :no_response, :behind], flags([15_173, T1], [nil, nil], [15_170, T0])
  end

  def test_empty_replicas
    assert_equal [nil, :behind], flags([15_173, T1], [0, nil])
    assert_equal [nil, nil], flags([0, nil], [0, nil])
  end
end
