# frozen_string_literal: true

require_relative '../light_helper'

# What a partial reindex is limited to (design D-57): the rules for the scope and the Solr query
class ReindexScopeTest < Minitest::Test
  Scope = SolrSearch::ReindexScope

  def test_nothing_chosen_is_a_full_reindex
    assert_nil Scope.normalize
    assert_nil Scope.normalize(trackers: [], fields: '')
    assert_nil Scope.of(nil)
    assert_nil Scope.of({})
  end

  def test_trackers_are_integers_sorted_and_each_once
    assert_equal({'trackers' => [1, 3]}, Scope.normalize(trackers: %w[3 1 3]))
    assert_equal({'trackers' => [1, 3]}, Scope.normalize(trackers: '3, 1'))
  end

  def test_fields_are_the_same
    assert_equal({'fields' => [9, 12]}, Scope.normalize(fields: [12, 9]))
  end

  def test_both_kinds_at_once_are_refused
    error = assert_raises(Scope::Invalid) { Scope.normalize(trackers: [1], fields: [2]) }
    assert_equal :both, error.reason
  end

  def test_an_id_that_is_not_a_positive_integer_is_refused
    ['0', '-1', 'abc', '1.5', '1;2', '99999999999'].each do |bad|
      error = assert_raises(Scope::Invalid, bad) { Scope.normalize(fields: [bad]) }
      assert_equal :bad_id, error.reason
    end
  end

  def test_too_many_ids_are_refused
    assert_equal 150, Scope.normalize(fields: (1..150).to_a)['fields'].size
    assert_raises(Scope::Invalid) { Scope.normalize(fields: (1..151).to_a) }
  end

  def test_a_hash_is_refused_like_any_bad_id
    error = assert_raises(Scope::Invalid) { Scope.normalize(trackers: {'a' => '1'}) }
    assert_equal :bad_id, error.reason
  end

  def test_a_single_integer_is_one_id
    assert_equal({'fields' => [9]}, Scope.normalize(fields: 9))
  end

  def test_a_stored_scope_comes_back_the_same
    assert_equal({'fields' => [9]}, Scope.of({'fields' => [9]}))
    assert_equal({'trackers' => [2]}, Scope.of({'trackers' => [2], 'fields' => nil}))
  end

  def test_a_run_is_partial_when_its_options_have_a_scope
    assert Scope.partial?({'types' => %w[issue journal], 'scope' => {'fields' => [9]}})
    refute Scope.partial?({'types' => %w[issue]})
    refute Scope.partial?(nil)
  end

  def test_the_solr_query_names_every_field_of_a_custom_field
    assert_equal 'cft_9:* OR cfj_9:* OR cfs_9:* OR cfn_9:* OR cfd_9:*', Scope.solr_query([9])
    assert_equal 2 * 5 - 1, Scope.solr_query([9, 12]).scan(' OR ').size
  end

  def test_the_solr_query_takes_integers_only
    assert_raises(ArgumentError) { Scope.solr_query(['9 OR *:*']) }
  end

  def test_the_field_ids_are_read_from_the_names_of_the_index
    names = %w[id type cft_12 cfj_12 cfs_3 cfn_7 cfd_9 cft_x cftx_5 cft_0 cft_012 project_id]
    assert_equal [3, 7, 9, 12], Scope.field_ids(names)
  end

  INCREMENTAL = %w[issue journal wiki_page document].freeze

  def test_a_reindex_of_every_type_stands_for_the_incremental_crawl
    assert Scope.covers?({'types' => INCREMENTAL}, nil, INCREMENTAL)
    assert Scope.covers?({'types' => INCREMENTAL + %w[attachment]}, {}, INCREMENTAL)
  end

  def test_a_reindex_of_some_types_only_does_not
    refute Scope.covers?({'types' => %w[document]}, {'document' => {'sent' => 5}}, INCREMENTAL)
    refute Scope.covers?({'types' => %w[attachment]}, nil, INCREMENTAL)
  end

  def test_a_partial_reindex_does_not
    refute Scope.covers?({'types' => %w[issue journal], 'scope' => {'trackers' => [1]}}, nil, INCREMENTAL)
  end

  def test_an_older_run_is_judged_by_its_counts
    assert Scope.covers?(nil, INCREMENTAL.to_h {|type| [type, {'sent' => 1}] }, INCREMENTAL)
    refute Scope.covers?(nil, {'attachment' => {'sent' => 1}}, INCREMENTAL)
  end

  def test_a_run_with_nothing_known_counts_as_before
    assert Scope.covers?(nil, nil, INCREMENTAL)
    assert Scope.covers?({}, {}, INCREMENTAL)
  end
end
