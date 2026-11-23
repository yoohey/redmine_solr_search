# frozen_string_literal: true

# The crawl tasks (design D-22). Each is recorded in solr_search_runs and refused while another one runs (exit 1).
# Needs the Solr address: set on the admin page, or the environment variable SOLR_URL (e.g. http://127.0.0.1:8983/solr).
namespace :redmine do
  namespace :solr_search do
    run_task = lambda do |&block|
      started = Time.current
      counts = block.call(->(msg) { puts "  #{msg}" })
      counts.each do |type, c|
        puts "#{type}: #{c['sent']} sent, #{c['deleted'].to_i} deleted"
        extra = c.except('sent', 'deleted')
        puts "  #{extra.to_json}" if extra.any?
      end
      puts "done in #{(Time.current - started).round(1)} s"
    rescue SolrSearch::TaskRun::Busy, SolrSearch::TaskRun::SlotLost => e
      abort e.message
    end

    desc <<~DESC
      Send every Redmine record to Solr again (full reindex, design D-22).
      Overwrites documents; does not delete what Redmine no longer has.
      TYPES=issue,... limits it to some types (default: all).
      TRACKERS=1,2 or FIELDS=9,10 (one of them) makes it a partial reindex (design D-57): the issues of these trackers, or
      the issues that have, or had, a value in these custom fields (a deleted field's id too), with their notes and the
      permission and custom field values of their attachments. TYPES does not apply to it.
    DESC
    task reindex: :environment do
      begin
        scope = SolrSearch::ReindexScope.normalize(trackers: ENV['TRACKERS'], fields: ENV['FIELDS'])
      rescue SolrSearch::ReindexScope::Invalid => e
        abort "#{e.message} (give TRACKERS=1,2 or FIELDS=9,10, not both)"
      end
      types = ENV['TYPES'].present? ? ENV['TYPES'].split(',').map(&:strip) : SolrSearch::Indexer.types
      run_task.call {|logger| SolrSearch::Tasks.reindex(types, triggered_by: 'rake', logger: logger, scope: scope)}
    end

    desc <<~DESC
      Run the requests waiting from the admin page (design D-42, Q-20): full reindexes asked for there. The scheduler
      does this itself every minute; this is for a place without it (cron every minute). Takes them one after the
      other, oldest first; stops when none waits, or when another run holds the slot (exit 1: nothing is lost, the
      request stays).
    DESC
    task requests: :environment do
      ran = refused = 0
      while (counts = SolrSearch::Requests.run_next(logger: ->(msg) { puts "  #{msg}" }))
        if counts == SolrSearch::Requests::REFUSED
          refused += 1 # recorded as failed: go on to the next one
          next
        end
        ran += 1
        counts.each {|type, c| puts "#{type}: #{c['sent']} sent, #{c['deleted'].to_i} deleted"}
      end
      puts "#{ran} request(s) run, #{refused} refused, #{SolrSearch::Requests.waiting.count} still waiting"
    end

    desc <<~DESC
      Send what changed since the last incremental crawl or full reindex (incremental crawl, design D-22).
      Removes what fell out of the index's scope (a note emptied ...). Runs a full reindex when there is no
      earlier run to start from.
    DESC
    task incremental: :environment do
      run_task.call {|logger| SolrSearch::Tasks.incremental(triggered_by: 'rake', logger: logger)}
    end

    desc <<~DESC
      Run the golden query sets and record the run (design D-45): how the search does against what is known to be right.
      SET=coverage (every container a user may see that holds a word of the seed's expected.yml: recall, precision, leaks),
      ranking (golden.yml: MRR and the share found in the first places); default those of the two that the data set has.
      DATASET=<folder under docker/seed> (default ja-cf where it is, else ja-basic). NOTE="..." says what was changed before
      the run. Makes searches only; changes nothing in the index.
    DESC
    task golden: :environment do
      sets = ENV['SET'].present? ? ENV['SET'].split(',').map(&:strip) : SolrSearchGoldenRun::KINDS
      abort "SET must be #{SolrSearchGoldenRun::KINDS.join(' or ')}" unless (sets - SolrSearchGoldenRun::KINDS).empty?

      runner = SolrSearch::GoldenRunner.new(dataset: ENV['DATASET'].presence || SolrSearch::GoldenRunner.default_dataset,
                                            note: ENV['NOTE'], logger: ->(msg) { puts "  #{msg}" })
      puts "data set: #{runner.dataset}"
      if ENV['SET'].blank? && runner.available_sets.any? # SET asked for, or none there: said by the runner
        (sets - runner.available_sets).each {|set| puts "#{set}: left out (#{runner.dataset} has no file for it)" }
        sets &= runner.available_sets
      end
      sets.each do |set|
        run = runner.public_send(set)
        if set == 'coverage'
          puts format('coverage: recall %.4f  precision %.4f  leaks %d  (%d of %d found)',
                      run.recall.to_f, run.precision.to_f, run.leaks, run.found, run.expected)
        else
          puts format('ranking: MRR %.4f  in the first places %d of %d (%.1f%%)',
                      run.mrr.to_f, run.found, run.expected, run.recall_at_k.to_f * 100)
        end
        run.details_list.first(10).each {|d| puts "  #{d.to_json}"}
      end
    rescue SolrSearch::Golden::Invalid => e
      abort "golden: #{e.message}" # a golden.yml that cannot be read, or a user that is not there: nothing is recorded
    end

    desc <<~DESC
      Send every wiki page and document again: renaming or moving a wiki page and editing a document leave no
      timestamp for the incremental crawl (design D-22, process 2).
    DESC
    task resend: :environment do
      run_task.call {|logger| SolrSearch::Tasks.resend(triggered_by: 'rake', logger: logger)}
    end

    desc <<~DESC
      Remove from Solr what Redmine no longer has in the index's scope: deleted records, and records out of scope
      without a timestamp to show it (reconciliation, design D-22, process 3).
    DESC
    task reconcile: :environment do
      run_task.call {|logger| SolrSearch::Tasks.reconcile(triggered_by: 'rake', logger: logger)}
    end

    desc <<~DESC
      Send the attachments the index does not have yet, with the text Tika makes of their files (design D-36, process 5).
      Tika: the address on the status tab, else TIKA_URL, else http://tika:9998 (design D-61). Takes some of them in a run;
      the next run goes on. Attachments and Tika: a full reindex of them is TYPES=attachment.
    DESC
    task attachments: :environment do
      run_task.call {|logger| SolrSearch::Tasks.attachments(triggered_by: 'rake', logger: logger)}
    end

    desc <<~DESC
      Run the crawl tasks at the intervals set in the plugin settings, until stopped (SIGTERM, Ctrl-C). The default
      way to start them (design D-22); in Docker, the scheduler service runs it. Where no long-running process is
      wanted, start the tasks above from cron or a job scheduler instead, and turn them off in the settings.
    DESC
    task scheduler: :environment do
      # stdout is not a terminal in a container: without this, its log lines (RAILS_LOG_TO_STDOUT) stay in Ruby's
      # buffer and reach docker compose logs late
      $stdout.sync = true
      SolrSearch::Scheduler.new.run
    end

    desc <<~DESC
      Run the plugin's light tests (test/unit): what needs neither a database nor Solr (M1 review D2). Permissions
      and the crawl are checked on the seed data in docs/experiments instead.
    DESC
    task :light_test do
      test_dir = File.expand_path('../../test', __dir__)
      files = Dir[File.join(test_dir, 'unit', '*_test.rb')].sort
      # a Ruby of its own: no Rails environment, and minitest runs the tests when it exits
      ruby "-I#{test_dir}", '-e', files.map {|f| "require #{f.dump}"}.join(';')
    end
  end
end
