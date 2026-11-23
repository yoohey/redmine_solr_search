# frozen_string_literal: true

require_relative '../light_helper'

# The crawl's state as Prometheus text (design D-39, M6)
class MetricsTest < Minitest::Test
  NOW = Time.utc(2026, 10, 18, 12, 0, 0)
  Beat = Struct.new(:beat_at)
  Run = Struct.new(:status, :finished_at, :duration, keyword_init: true)

  def render(heartbeat: Beat.new(NOW - 12.5), last_runs: {}, running: [])
    SolrSearch::Metrics.render(heartbeat: heartbeat, last_runs: last_runs, running: running, now: NOW)
  end

  def test_the_age_of_the_last_beat
    assert_includes render, "solr_search_scheduler_heartbeat_age_seconds 12.5\n"
  end

  def test_no_beat_ever_writes_no_series_rather_than_zero
    text = render(heartbeat: nil)
    refute_includes text, 'heartbeat_age'
  end

  def test_a_beat_in_the_future_is_not_negative
    assert_includes render(heartbeat: Beat.new(NOW + 5)), "solr_search_scheduler_heartbeat_age_seconds 0\n"
  end

  def test_a_task_that_never_finished_has_no_success_series
    text = render(last_runs: {'reindex' => nil}, running: [])
    assert_includes text, %(solr_search_task_running{task="reindex"} 0)
    refute_includes text, 'last_success'
    refute_includes text, 'last_finished_timestamp'
    refute_includes text, 'last_duration'
  end

  def test_success_and_failure_are_1_and_0
    ok = Run.new(status: 'succeeded', finished_at: Time.utc(2026, 10, 18, 11, 0), duration: 2.0)
    ng = Run.new(status: 'failed', finished_at: Time.utc(2026, 10, 18, 11, 30), duration: nil)
    text = render(last_runs: {'incremental' => ok, 'attachments' => ng})
    assert_includes text, %(solr_search_task_last_success{task="incremental"} 1)
    assert_includes text, %(solr_search_task_last_success{task="attachments"} 0)
    assert_includes text, %(solr_search_task_last_finished_timestamp_seconds{task="incremental"} #{Time.utc(2026, 10, 18, 11).to_i})
    assert_includes text, %(solr_search_task_last_duration_seconds{task="incremental"} 2)
  end

  def test_a_failed_run_without_a_duration_leaves_that_series_out
    ng = Run.new(status: 'failed', finished_at: NOW, duration: nil)
    text = render(last_runs: {'attachments' => ng})
    refute_includes text, 'last_duration_seconds{'
  end

  def test_running_is_1
    text = render(last_runs: {'incremental' => nil, 'reindex' => nil}, running: ['reindex'])
    assert_includes text, %(solr_search_task_running{task="reindex"} 1)
    assert_includes text, %(solr_search_task_running{task="incremental"} 0)
  end

  def test_each_family_has_help_and_type_once
    text = render(last_runs: {'a' => Run.new(status: 'succeeded', finished_at: NOW, duration: 1), 'b' => nil})
    assert_equal 1, text.scan('# TYPE solr_search_task_last_success gauge').size
    assert_equal 1, text.scan('# HELP solr_search_task_last_success ').size
  end

  def test_ends_with_a_newline_and_is_valid_when_empty
    assert render(heartbeat: nil).end_with?("\n")
  end

  # what is counted about the searches (design D-45)
  def counted(counters)
    SolrSearch::Metrics.render(heartbeat: nil, last_runs: {}, running: [], now: NOW, counters: counters)
  end

  def test_nothing_about_the_searches_without_counters
    refute_includes render, 'solr_search_searches_total'
  end

  def test_counters_that_were_never_added_to_are_zero_not_missing
    text = counted({})
    %w[found zero failed].each {|result| assert_includes text, %(solr_search_searches_total{result="#{result}"} 0\n) }
    assert_includes text, "solr_search_dropped_groups_total 0\n"
    assert_includes text, %(solr_search_clicks_total{kind="title"} 0\n)
    assert_includes text, %(solr_search_search_duration_seconds_bucket{le="+Inf"} 0\n)
    assert_includes text, "solr_search_search_duration_seconds_count 0\n"
  end

  def test_the_types_are_counter_and_histogram
    text = counted({})
    assert_includes text, '# TYPE solr_search_searches_total counter'
    assert_includes text, '# TYPE solr_search_search_duration_seconds histogram'
    assert_includes text, '# TYPE solr_search_click_rank histogram'
    assert_includes render(last_runs: {'incremental' => nil}), '# TYPE solr_search_task_running gauge'
  end

  def test_the_counts_of_the_searches_by_result
    text = counted({'searches:found' => 7, 'searches:zero' => 2, 'searches:failed' => 1, 'dropped_groups' => 4, 'searches_with_click' => 5})
    assert_includes text, %(solr_search_searches_total{result="found"} 7\n)
    assert_includes text, %(solr_search_searches_total{result="zero"} 2\n)
    assert_includes text, %(solr_search_searches_total{result="failed"} 1\n)
    assert_includes text, "solr_search_dropped_groups_total 4\n"
    assert_includes text, "solr_search_searches_with_click_total 5\n"
  end

  def test_a_histogram_is_cumulative_in_seconds_with_a_sum_and_a_count
    text = counted({'duration:le:25' => 2, 'duration:le:250' => 1, 'duration:le:inf' => 1, 'duration:sum_ms' => 12_000, 'duration:count' => 4})
    {'0.025' => 2, '0.05' => 2, '0.1' => 2, '0.25' => 3, '0.5' => 3, '1' => 3, '2.5' => 3, '5' => 3, '10' => 3, '+Inf' => 4}.each do |le, n|
      assert_includes text, %(solr_search_search_duration_seconds_bucket{le="#{le}"} #{n}\n), le
    end
    assert_includes text, "solr_search_search_duration_seconds_sum 12\n"
    assert_includes text, "solr_search_search_duration_seconds_count 4\n"
  end

  def test_the_hits_and_the_rank_are_histograms_in_their_own_units
    text = counted({'hits:le:0' => 1, 'hits:le:20' => 2, 'hits:sum' => 25, 'click_rank:le:1' => 3, 'click_rank:le:inf' => 1, 'click_rank:sum' => 70})
    assert_includes text, %(solr_search_search_hits_bucket{le="0"} 1\n)
    assert_includes text, %(solr_search_search_hits_bucket{le="20"} 3\n)
    assert_includes text, %(solr_search_search_hits_bucket{le="+Inf"} 3\n)
    assert_includes text, "solr_search_search_hits_sum 25\n"
    assert_includes text, %(solr_search_click_rank_bucket{le="1"} 3\n)
    assert_includes text, %(solr_search_click_rank_bucket{le="+Inf"} 4\n)
    assert_includes text, "solr_search_click_rank_sum 70\n"
  end

  def test_no_word_and_no_user_is_in_what_is_counted
    text = counted({'searches:found' => 1})
    refute_match(/user|query|login/i, text.lines.reject {|l| l.start_with?('# HELP') }.join)
  end

  def test_label_values_are_escaped
    text = render(last_runs: {%(a"b\\c) => nil})
    assert_includes text, %(task="a\\"b\\\\c")
  end

  GoldenRun = Struct.new(:recall, :precision, :leaks, :mrr, :recall_at_k, :queries, :ran_at, keyword_init: true)

  def golden(**sets)
    SolrSearch::Metrics.render(heartbeat: nil, last_runs: {}, running: [], now: NOW, golden: sets.transform_keys(&:to_s))
  end

  def test_the_last_run_of_each_golden_set_is_written_by_its_set
    text = golden(coverage: GoldenRun.new(recall: 0.97, precision: 0.5, leaks: 0, queries: 300, ran_at: NOW - 60),
                  ranking: GoldenRun.new(mrr: 0.75, recall_at_k: 0.9, queries: 16, ran_at: NOW - 30))
    assert_includes text, %(solr_search_golden_recall{set="coverage"} 0.97\n)
    assert_includes text, %(solr_search_golden_leaks{set="coverage"} 0\n)
    assert_includes text, %(solr_search_golden_mrr{set="ranking"} 0.75\n)
    assert_includes text, %(solr_search_golden_top_share{set="ranking"} 0.9\n)
    assert_includes text, %(solr_search_golden_queries{set="ranking"} 16\n)
    assert_includes text, %(solr_search_golden_last_run_timestamp_seconds{set="coverage"} #{(NOW - 60).to_f.to_i}\n)
    refute_includes text, 'precision{set="ranking"}' # not a value of that set: left out, not 0
    refute_includes text, 'leaks{set="ranking"}'
    refute_includes text, 'mrr{set="coverage"}'
    refute_includes text, 'mrr{set="coverage"}'
  end

  def test_a_set_never_run_has_no_series
    text = golden(coverage: nil, ranking: nil)
    refute_includes text, 'solr_search_golden'
  end

  def test_numbers_are_written_whole_or_with_up_to_three_decimals
    n = SolrSearch::Metrics.method(:number)
    assert_equal '0', n.call(0)
    assert_equal '7', n.call(7)
    assert_equal '0', n.call(0.0)
    assert_equal '100', n.call(100.0)
    assert_equal '0.5', n.call(0.5)
    assert_equal '0.123', n.call(0.1234)
    assert_equal '10', n.call(10.0004)
    assert_equal '-1.25', n.call(-1.25)
  end

  def test_the_golden_sets_are_left_out_when_not_asked_for
    refute_includes render, 'solr_search_golden'
  end
end
