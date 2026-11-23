# frozen_string_literal: true

require_relative '../light_helper'

# The filters of Redmine's issue query written for Solr (design D-49). The meaning of an operator is Redmine's own
# (Query#sql_for_field); the days are the user's: a Tokyo user's Tuesday starts at 15:00 UTC of Monday.
class FilterTranslatorTest < Minitest::Test
  T = SolrSearch::FilterTranslator
  Custom = Struct.new(:id, :kind, :project_ids, keyword_init: true)

  # Tuesday, 2026-10-20; weeks start on Monday (1) unless said otherwise
  def context(first_day: 1, custom: [])
    T::Context.new(today: Date.new(2026, 10, 20), zone: ActiveSupport::TimeZone['Tokyo'], first_day_of_week: first_day,
                   open_status_ids: [1, 2], closed_status_ids: [3, 5], my_ids: {'author_id' => [7], 'assigned_to_id' => [7, 40, 41]},
                   custom: custom)
  end

  def run_filters(filters, **options)
    T.call(filters, context(**options))
  end

  def one(field, operator, *values, **options)
    run_filters({field => {operator: operator, values: values}}, **options).expressions.last
  end

  def test_nothing_to_write_nothing_narrowed
    result = run_filters({})
    assert_empty result.expressions
    refute result.narrowing?
    unknown = run_filters({'subject' => {operator: '~', values: ['x']}, 'done_ratio' => {operator: '>=', values: ['50']}})
    assert_empty unknown.expressions # the issues are not narrowed for filters that were not understood
    assert_equal %w[subject done_ratio], unknown.ignored
  end

  def test_what_is_written_is_for_issues_only
    result = run_filters({'status_id' => {operator: '=', values: ['1']}})
    assert_equal [T::ISSUES, "{!terms f=status_id v='1'}"], result.expressions
    assert_equal "{!prefix f=group_id v='issue-'}", T::ISSUES
  end

  def test_ids
    assert_equal "{!terms f=tracker_id v='1,3'}", one('tracker_id', '=', '3', '1', '3')
    assert_equal "(*:* -{!terms f=priority_id v='4'})", one('priority_id', '!', '4')
    assert_equal 'fixed_version_id:[* TO *]', one('fixed_version_id', '*', '')
    assert_equal '(*:* -category_id:[* TO *])', one('category_id', '!*', '')
    assert_equal '-*:*', one('tracker_id', '=') # equal to nothing: nothing
    assert_nil one('tracker_id', '!') # not any of nothing: no narrowing
    assert_equal "{!terms f=tracker_id v='1'}", one('tracker_id', '=', 'x', '1', "1'; drop") # only whole numbers
  end

  def test_the_status_open_and_closed
    assert_equal "{!terms f=status_id v='1,2'}", one('status_id', 'o', '')
    assert_equal "{!terms f=status_id v='3,5'}", one('status_id', 'c', '')
    assert_nil one('tracker_id', 'o', '') # only the status has them
  end

  def test_me_is_the_user_and_for_the_assignee_the_groups_of_the_user
    assert_equal "{!terms f=author_id v='7,9'}", one('author_id', '=', 'me', '9')
    assert_equal "{!terms f=assigned_to_id v='7,40,41'}", one('assigned_to_id', '=', 'me')
    assert_equal "(*:* -{!terms f=assigned_to_id v='7,40,41'})", one('assigned_to_id', '!', 'me')
  end

  def test_dates_of_a_time_are_the_days_of_the_users_zone
    # Tokyo is UTC+9: 2026-10-19 starts at 2026-10-18T15:00:00Z, and ends at 2026-10-19T14:59:59Z
    assert_equal 'updated_at:[2026-10-18T15:00:00Z TO 2026-10-19T14:59:59Z]', one('updated_on', '=', '2026-10-19')
    assert_equal 'updated_at:[2026-10-18T15:00:00Z TO *]', one('updated_on', '>=', '2026-10-19')
    assert_equal 'issue_created_at:[* TO 2026-10-19T14:59:59Z]', one('created_on', '<=', '2026-10-19')
    assert_equal 'issue_closed_at:[2026-10-18T15:00:00Z TO 2026-10-20T14:59:59Z]', one('closed_on', '><', '2026-10-19', '2026-10-20')
  end

  def test_dates_of_a_day_are_the_midnight_utc_of_it
    assert_equal 'due_date:[2026-10-19T00:00:00Z TO 2026-10-19T23:59:59Z]', one('due_date', '=', '2026-10-19')
    assert_equal 'start_date:[* TO 2026-10-19T23:59:59Z]', one('start_date', '<=', '2026-10-19')
  end

  def test_the_days_relative_to_today
    day = ->(from, to) { "due_date:[#{from}T00:00:00Z TO #{to}T23:59:59Z]" }
    assert_equal day.('2026-10-20', '2026-10-20'), one('due_date', 't')
    assert_equal day.('2026-10-19', '2026-10-19'), one('due_date', 'ld')
    assert_equal day.('2026-10-21', '2026-10-21'), one('due_date', 'nd')
    assert_equal 'due_date:[2026-10-13T00:00:00Z TO *]', one('due_date', '>t-', '7')
    assert_equal 'due_date:[* TO 2026-10-13T23:59:59Z]', one('due_date', '<t-', '7')
    assert_equal day.('2026-10-13', '2026-10-13'), one('due_date', 't-', '7')
    assert_equal day.('2026-10-13', '2026-10-20'), one('due_date', '><t-', '7')
    assert_equal 'due_date:[2026-10-23T00:00:00Z TO *]', one('due_date', '>t+', '3')
    assert_equal 'due_date:[* TO 2026-10-23T23:59:59Z]', one('due_date', '<t+', '3')
    assert_equal day.('2026-10-23', '2026-10-23'), one('due_date', 't+', '3')
    assert_equal day.('2026-10-20', '2026-10-23'), one('due_date', '><t+', '3')
  end

  def test_weeks_months_and_the_year
    day = ->(from, to) { "due_date:[#{from}T00:00:00Z TO #{to}T23:59:59Z]" }
    # today is a Tuesday: this week, from Monday the 19th to Sunday the 25th
    assert_equal day.('2026-10-19', '2026-10-25'), one('due_date', 'w')
    assert_equal day.('2026-10-12', '2026-10-18'), one('due_date', 'lw')
    assert_equal day.('2026-10-05', '2026-10-18'), one('due_date', 'l2w')
    assert_equal day.('2026-10-26', '2026-11-01'), one('due_date', 'nw')
    # a week that starts on a Sunday (7): from Sunday the 18th
    assert_equal day.('2026-10-18', '2026-10-24'), one('due_date', 'w', first_day: 7)
    # a week that starts on Wednesday (3) holds a Tuesday at its end: from Wednesday the 14th
    assert_equal day.('2026-10-14', '2026-10-20'), one('due_date', 'w', first_day: 3)
    assert_equal day.('2026-10-01', '2026-10-31'), one('due_date', 'm')
    assert_equal day.('2026-09-01', '2026-09-30'), one('due_date', 'lm')
    assert_equal day.('2026-11-01', '2026-11-30'), one('due_date', 'nm')
    assert_equal day.('2026-01-01', '2026-12-31'), one('due_date', 'y')
  end

  def test_a_date_that_is_not_one_and_an_operator_that_is_not_known_write_nothing
    assert_nil one('due_date', '=', 'tomorrow')
    assert_nil one('due_date', '><', '2026-10-01', '')
    assert_nil one('due_date', '~', 'x')
    assert_nil one('due_date', 'ev', '1')
    assert_equal 'due_date:[* TO *]', one('due_date', '*')
    assert_equal '(*:* -due_date:[* TO *])', one('due_date', '!*')
  end

  def test_custom_fields_by_kind
    custom = [Custom.new(id: 4, kind: :values, project_ids: nil), Custom.new(id: 7, kind: :number, project_ids: nil),
              Custom.new(id: 9, kind: :date, project_ids: nil)]
    assert_equal "({!term f=cfs_4 v='A'} OR {!term f=cfs_4 v='it\\'s'})", one('cf_4', '=', 'A', "it's", custom: custom)
    assert_equal "(*:* -({!term f=cfs_4 v='A'}))", one('cf_4', '!', 'A', custom: custom)
    assert_equal 'cfs_4:[* TO *]', one('cf_4', '*', custom: custom)
    assert_equal 'cfn_7:[1.5 TO *]', one('cf_7', '>=', '1.5', custom: custom)
    assert_equal 'cfn_7:[1.0 TO 3.0]', one('cf_7', '><', '1', '3', custom: custom)
    assert_equal 'cfn_7:[* TO 2.0]', one('cf_7', '<=', '2', custom: custom)
    assert_equal 'cfd_9:[2026-10-01T00:00:00Z TO 2026-10-31T23:59:59Z]', one('cf_9', 'm', custom: custom)
    assert_nil one('cf_7', '>=', 'x', custom: custom)
  end

  def test_a_custom_field_the_user_does_not_see_is_not_understood_and_one_seen_in_some_projects_is_kept_to_them
    custom = [Custom.new(id: 5, kind: :values, project_ids: [2, 9])]
    assert_nil one('cf_6', '=', 'A', custom: custom) # not one of the user's
    assert_equal "(({!term f=cfs_5 v='A'}) AND {!terms f=project_id v='2,9'})", one('cf_5', '=', 'A', custom: custom)
  end

  def test_more_filters_all_hold
    result = run_filters({'status_id' => {operator: 'o', values: ['']}, 'assigned_to_id' => {operator: '=', values: ['me']}})
    assert_equal [T::ISSUES, "{!terms f=status_id v='1,2'}", "{!terms f=assigned_to_id v='7,40,41'}"], result.expressions
  end
end
