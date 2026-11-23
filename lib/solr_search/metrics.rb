# frozen_string_literal: true

module SolrSearch
  # The crawl's state in the Prometheus text format (design D-39, M6): is the scheduler alive, and how did each task's
  # last run end. Read from Redmine's database only; Solr is not asked, so a Solr that hangs cannot hold this page.
  # Pure formatting: SolrSearchMetricsController gives it what it read, so it is checked by a light test.
  module Metrics
    CONTENT_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
    ENV_TOKEN = 'SOLR_SEARCH_METRICS_TOKEN'

    # heartbeat: an object with beat_at, or nil (no scheduler has ever beaten)
    # last_runs: {task => the task's last finished run, or nil}; a run answers status, finished_at and duration
    # running:   the tasks that are running now
    # Series whose value is not known (no beat, never finished) are left out rather than written as 0: an alert must
    # not take "never ran" for "ran and succeeded", nor for "ran at 1970".
    # counters: {key => value} of SolrSearch::Counters, or nil to leave out what is counted about the searches (design D-45)
    # golden: {'coverage' => the last run, 'ranking' => the last run} of the golden query sets (SolrSearchGoldenRun; a missing
    # one is nil), or nil to leave them out
    def self.render(heartbeat:, last_runs:, running:, now: Time.current, counters: nil, golden: nil)
      out = []
      beat_at = heartbeat&.beat_at
      family(out, 'solr_search_scheduler_heartbeat_age_seconds',
             "Seconds since the crawl scheduler's last beat (no series: it has never beaten)") do
        [[{}, [now - beat_at, 0].max]] if beat_at # not clamp(0, nil): Ruby 2.7 (Redmine 5.1 allows it) wants both ends
      end
      family(out, 'solr_search_task_running', '1 while the task is running') do
        last_runs.keys.map {|task| [{task: task}, running.include?(task) ? 1 : 0]}
      end
      family(out, 'solr_search_task_last_success',
             "1 if the task's last finished run succeeded, 0 if it failed (no series: it has never finished)") do
        finished(last_runs) {|run| run.status == 'succeeded' ? 1 : 0}
      end
      family(out, 'solr_search_task_last_finished_timestamp_seconds',
             "Unix time at which the task's last run finished (no series: it has never finished)") do
        finished(last_runs) {|run| run.finished_at.to_f}
      end
      family(out, 'solr_search_task_last_duration_seconds', "How long the task's last finished run took") do
        finished(last_runs) {|run| run.duration}
      end
      search_counts(out, counters) if counters
      golden_runs(out, golden) if golden
      out.join("\n") << "\n"
    end

    # What is counted about the searches and the clicks (design D-45), as counters and histograms. A count that was never
    # added to is 0, not missing: a counter that starts at 0 lets rate() and increase() see the first search. Neither the
    # words nor the users are here: those are for the administrator's page only.
    def self.search_counts(out, counters)
      count = ->(key) { counters[key].to_i }
      typed(out, 'solr_search_searches_total', 'Searches of the search screen (first pages), by result', 'counter',
            %w[found zero failed].map {|result| [{result: result}, count.("searches:#{result}")] })
      histogram(out, 'solr_search_search_duration_seconds', 'How long a search took, from asking Solr to the list ready (every page)',
                counters, 'duration', SearchStats::DURATION_MS, 'duration:sum_ms', 1000.0)
      histogram(out, 'solr_search_search_hits', 'How many documents a search found (first pages)', counters, 'hits', SearchStats::HITS, 'hits:sum', 1)
      typed(out, 'solr_search_dropped_groups_total', "Groups of results that Redmine's own checks did not show (should stay about 0)",
            'counter', [[{}, count.('dropped_groups')]])
      typed(out, 'solr_search_clicks_total', 'Clicks on the results of a search, by what kind of link', 'counter',
            SearchStats::CLICK_KINDS.map {|kind| [{kind: kind}, count.("clicks:kind:#{kind}")] })
      typed(out, 'solr_search_searches_with_click_total', 'Searches that found something and had something opened', 'counter',
            [[{}, count.('searches_with_click')]])
      histogram(out, 'solr_search_click_rank', 'The place in the list of what was opened', counters, 'click_rank', SearchStats::RANK,
                'click_rank:sum', 1)
    end

    # How the search did on the golden query sets in their last runs (design D-45). A set that was never run, and a value
    # that does not exist for a run (the precision of a run that found nothing), are left out, not written as 0.
    def self.golden_runs(out, golden)
      runs = golden.select {|_set, run| run}
      # only: the one set that the value is of (the leaks and the precision are the coverage's; the MRR and the share the ranking's)
      field = lambda do |name, help, key, only = nil|
        family(out, name, help) do
          runs.filter_map {|set, run| [{set: set}, run.public_send(key)] unless run.public_send(key).nil? || (only && set != only)}
        end
      end
      field.call('solr_search_golden_recall', 'Of what the search should find, the share it found (golden set, last run)', :recall)
      field.call('solr_search_golden_precision', 'Of what the search found, the share that was right (coverage set, last run)', :precision, 'coverage')
      field.call('solr_search_golden_leaks', 'Found, but the user may not see it: must be 0 (coverage set, last run)', :leaks, 'coverage')
      field.call('solr_search_golden_mrr', 'Mean reciprocal rank of the first right container (ranking set, last run)', :mrr, 'ranking')
      field.call('solr_search_golden_top_share', 'Share of the queries with a right container in their first places (ranking set, last run)', :recall_at_k, 'ranking')
      field.call('solr_search_golden_queries', 'Searches made in the last run of the set', :queries)
      family(out, 'solr_search_golden_last_run_timestamp_seconds', 'Unix time of the last run of the set') do
        runs.map {|set, run| [{set: set}, run.ran_at.to_f]}
      end
    end

    # A histogram from the counts in each bucket (not cumulative: they are made cumulative here). scale: what turns the unit of
    # the buckets and of the sum into the unit of the metric (milliseconds into seconds).
    def self.histogram(out, name, help, counters, prefix, bounds, sum_key, scale)
      out << "# HELP #{name} #{help}" << "# TYPE #{name} histogram"
      running = 0
      bounds.each do |bound|
        running += counters["#{prefix}:le:#{bound}"].to_i
        out << "#{name}_bucket{le=\"#{number(bound / scale)}\"} #{running}"
      end
      total = running + counters["#{prefix}:le:inf"].to_i
      out << "#{name}_bucket{le=\"+Inf\"} #{total}" << "#{name}_sum #{number(counters[sum_key].to_i / scale)}" << "#{name}_count #{total}"
    end
    private_class_method :histogram

    # [[labels, value]] for the tasks that have a last run and whose block answers a value
    def self.finished(last_runs)
      last_runs.filter_map do |task, run|
        value = run && yield(run)
        [{task: task}, value] unless value.nil?
      end
    end
    private_class_method :finished

    def self.family(out, name, help, &block)
      typed(out, name, help, 'gauge', block.call)
    end

    def self.typed(out, name, help, type, samples)
      return if samples.nil? || samples.empty?

      out << "# HELP #{name} #{help}" << "# TYPE #{name} #{type}"
      samples.each {|labels, value| out << "#{name}#{label_text(labels)} #{number(value)}"}
    end
    private_class_method :typed
    private_class_method :family

    def self.label_text(labels)
      return '' if labels.empty?

      '{' + labels.map {|key, value| "#{key}=\"#{value.to_s.gsub(/[\\"\n]/) {|c| c == "\n" ? '\n' : "\\#{c}"}}\""}.join(',') + '}'
    end

    def self.number(value)
      value.is_a?(Integer) ? value.to_s : format('%.3f', value).sub(/\.?0+\z/, '')
    end
  end
end
