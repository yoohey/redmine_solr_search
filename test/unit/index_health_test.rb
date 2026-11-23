# frozen_string_literal: true

require_relative '../light_helper'

# How the index is against Redmine, as Prometheus text (design D-45)
class IndexHealthTest < Minitest::Test
  X = SolrSearch::IndexHealth
  NOW = Time.utc(2026, 10, 18, 12, 0, 0)

  def data(**over)
    {up: true, now: NOW,
     types: {'issue' => {redmine_count: 3128, redmine_newest: NOW - 60, solr_count: 3128, solr_newest: NOW - 60},
             'document' => {redmine_count: 61, redmine_newest: NOW - 30, solr_count: 60, solr_newest: NOW - 3600}}}.merge(over)
  end

  def text(**over)
    X.render(data(**over))
  end

  def test_a_type_that_the_list_does_not_know_has_no_newest_time_instead_of_failing_the_page
    assert_nil X::NEWEST_IN_REDMINE.fetch('a_new_type') { X::NO_NEWEST }.call(:scope)
  end

  def test_the_lag_is_how_far_solr_is_behind_and_never_negative
    assert_equal 0, X.lag(NOW, NOW)
    assert_equal 90, X.lag(NOW, NOW - 90)
    assert_equal 0, X.lag(NOW - 90, NOW) # Solr newer than Redmine (a document that Redmine has deleted): not behind
  end

  def test_the_same_update_is_not_late_because_the_database_keeps_milliseconds
    assert_equal 0, X.lag(NOW + 0.162, NOW)
    assert_equal 0, X.lag(NOW + 0.999, NOW)
    assert_equal 1, X.lag(NOW + 1.2, NOW)
  end

  def test_the_timestamps_are_whole_seconds_on_both_sides
    t = text(types: {'issue' => {redmine_count: 1, redmine_newest: NOW + 0.162, solr_count: 1, solr_newest: NOW}})
    assert_includes t, %(solr_search_index_newest_timestamp_seconds{type="issue",where="redmine"} #{NOW.to_i}\n)
  end

  def test_the_lag_is_not_known_without_both_sides
    assert_nil X.lag(nil, NOW)
    assert_nil X.lag(NOW, nil)
  end

  def test_the_counts_of_each_type_in_redmine_and_in_solr
    t = text
    assert_includes t, %(solr_search_index_documents{type="issue",where="redmine"} 3128\n)
    assert_includes t, %(solr_search_index_documents{type="document",where="solr"} 60\n)
    assert_includes t, %(solr_search_index_documents{type="document",where="redmine"} 61\n)
  end

  def test_the_lag_and_the_age_of_the_newest_in_seconds
    t = text
    assert_includes t, %(solr_search_index_lag_seconds{type="document"} 3570\n)
    assert_includes t, %(solr_search_index_lag_seconds{type="issue"} 0\n)
    assert_includes t, %(solr_search_index_newest_age_seconds{type="document"} 3600\n)
    assert_includes t, %(solr_search_index_newest_timestamp_seconds{type="issue",where="solr"} #{(NOW - 60).to_i}\n)
  end

  def test_when_solr_does_not_answer_only_what_redmine_has_is_given
    t = text(up: false, types: {'issue' => {redmine_count: 3128, redmine_newest: NOW, solr_count: nil, solr_newest: nil}})
    assert_includes t, "solr_search_index_up 0\n"
    assert_includes t, %(solr_search_index_documents{type="issue",where="redmine"} 3128\n)
    refute_includes t, 'where="solr"'
    refute_includes t, 'solr_search_index_lag_seconds'
    refute_includes t, 'solr_search_index_newest_age_seconds'
  end

  def test_a_type_with_no_document_in_solr_has_a_count_of_zero_and_no_newest
    t = text(types: {'journal' => {redmine_count: 5, redmine_newest: NOW, solr_count: 0, solr_newest: nil}})
    assert_includes t, %(solr_search_index_documents{type="journal",where="solr"} 0\n)
    refute_includes t, 'solr_search_index_lag_seconds{type="journal"}'
  end

  def test_up_is_one_when_solr_answered
    assert_includes text, "solr_search_index_up 1\n"
  end

  def test_every_family_is_a_gauge_with_help
    t = text
    %w[up documents newest_timestamp_seconds lag_seconds newest_age_seconds].each do |name|
      assert_includes t, "# TYPE solr_search_index_#{name} gauge"
      assert_includes t, "# HELP solr_search_index_#{name} "
    end
  end

  def test_the_deleted_fields_are_counted_when_they_were_looked_for
    t = text(orphan_fields: [{id: 12, count: 340}, {id: 15, count: 2}])
    assert_includes t, "solr_search_index_deleted_fields 2\n"
    assert_includes t, "solr_search_index_deleted_field_issues 342\n"
  end

  def test_no_deleted_fields_is_a_zero_and_not_looked_for_is_nothing
    assert_includes text(orphan_fields: []), "solr_search_index_deleted_fields 0\n"
    refute_includes text, 'solr_search_index_deleted_fields'
    refute_includes text(orphan_fields: nil), 'solr_search_index_deleted_fields'
  end
end
