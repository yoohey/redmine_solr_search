# frozen_string_literal: true

module SolrSearch
  # Runs one crawl task and records it in solr_search_runs (design D-22), whoever starts it (the scheduler, rake from
  # cron, the admin page). Only one task runs at a time: the running row holds running_slot = 1, which a unique index
  # lets only one row have. A run that stops moving (its process was killed) is given up after STALE_AFTER.
  #
  #   counts = TaskRun.perform('reindex', triggered_by: 'rake') do |run|
  #     ... TaskRun.keep_alive(run) after each batch ...
  #     {'issue' => {'sent' => 3}}
  #   end
  class TaskRun
    # Another run holds the slot
    class Busy < StandardError; end
    # This run was given up (it made no progress for STALE_AFTER) and another may be running: it must stop
    class SlotLost < StandardError; end
    # The request to run is not waiting any more (it was cancelled, or another process took it)
    class Gone < StandardError; end

    STALE_AFTER = 30.minutes
    # Lines of a failure's backtrace written to the log
    BACKTRACE_LINES = 10

    # Yields the running SolrSearchRun; the block returns the counts. Records success or failure (and re-raises the
    # failure, so that rake exits non-zero for cron and job schedulers), then removes records older than the retention.
    # A run that lost its slot leaves its record as the run that gave it up wrote it, and raises SlotLost.
    # request: a waiting row (status requested, design D-42) that becomes this run, instead of a new row
    def self.perform(task, triggered_by:, since: nil, request: nil, options: nil)
      run = request ? claim(request) : start(task, triggered_by, since, options) # raises Busy before anything is recorded
      begin
        counts = yield run
        release(run, status: 'succeeded', counts: counts) or raise SlotLost, lost_message
        log :info, "run ##{run.id} #{task} succeeded in #{run.reload.duration&.round(1)} s: #{counts.to_json}"
        counts
      rescue SlotLost => e
        log :warn, "run ##{run.id} #{task} stopped: #{e.message}"
        raise
      rescue StandardError, SignalException => e # also a stop (Ctrl-C, SIGTERM): the row must not stay running
        fail_run(run, task, e)
        raise
      ensure
        purge_old
      end
    end

    # Keeps a run alive (a progress report): moves its updated_at, as long as it still holds the slot. Raises SlotLost
    # when it does not, so that it stops before it does more beside the run that took over (M1 review A10).
    def self.keep_alive(run)
      SolrSearchRun.where(id: run.id, running_slot: 1).update_all(updated_at: Time.current).positive? or
        raise SlotLost, lost_message
    end

    def self.lost_message
      "given up by another run while still running (no progress for #{STALE_AFTER.inspect}); not recorded as finished"
    end
    private_class_method :lost_message

    # Finishes the run's record if it still holds the slot; false when it does not (the record is then left alone).
    # update_all casts through the attribute types: counts is given as a Hash, like to update!
    def self.release(run, status:, counts: nil, error: nil)
      SolrSearchRun.where(id: run.id, running_slot: 1)
                   .update_all(status: status, finished_at: Time.current, counts: counts, error: error,
                               running_slot: nil, updated_at: Time.current).positive?
    end
    private_class_method :release

    # Logged first: when the record cannot be written either (the database gone), the failure is still in the log
    def self.fail_run(run, task, error)
      log :error, "run ##{run.id} #{task} failed: #{error.class}: #{error.message}\n" \
                  "#{Array(error.backtrace).first(BACKTRACE_LINES).join("\n")}"
      released = release(run, status: 'failed', error: "#{error.class}: #{error.message}")
      log :warn, "run ##{run.id} #{task}: #{lost_message}" unless released
    rescue StandardError => e
      log :error, "run ##{run.id} #{task} failed, and its record could not be written: #{e.class}: #{e.message}"
    end
    private_class_method :fail_run

    # The waiting request becomes the running run, in one UPDATE: the unique index on running_slot lets it fail when
    # another run holds the slot (the request then stays as it was), and the condition on the status lets it fail when
    # the request was cancelled or taken meanwhile.
    def self.claim(request)
      give_up_stale
      now = Time.current
      claimed = SolrSearchRun.where(id: request.id, status: 'requested')
                             .update_all(status: 'running', running_slot: 1, started_at: now, updated_at: now)
      raise Gone, "request ##{request.id} is not waiting any more" if claimed.zero?

      run = SolrSearchRun.find(request.id)
      log :info, "run ##{run.id} #{run.task} started (by #{run.triggered_by}, a request from the admin page)"
      run
    rescue ActiveRecord::RecordNotUnique
      other = SolrSearchRun.find_by(running_slot: 1)
      message = "another run is in progress: ##{other&.id} #{other&.task} started at #{other&.started_at}"
      log :warn, "request ##{request.id} not started: #{message}"
      raise Busy, message
    end
    private_class_method :claim

    def self.start(task, triggered_by, since, options = nil)
      give_up_stale
      run = SolrSearchRun.create!(task: task, status: 'running', triggered_by: triggered_by, running_slot: 1,
                                  since: since, started_at: Time.current, request_options: options)
      log :info, "run ##{run.id} #{task} started (by #{triggered_by}#{", since #{since.utc.iso8601}" if since})"
      run
    rescue ActiveRecord::RecordNotUnique
      other = SolrSearchRun.find_by(running_slot: 1)
      message = "another run is in progress: ##{other&.id} #{other&.task} started at #{other&.started_at}"
      log :warn, "#{task} (by #{triggered_by}) not started: #{message}"
      raise Busy, message
    end
    private_class_method :start

    # A dead run ends where it last moved (updated_at), so its duration is how long it really ran
    def self.give_up_stale
      SolrSearchRun.where(running_slot: 1).where(updated_at: ...STALE_AFTER.ago).find_each do |run|
        run.update!(status: 'failed', finished_at: run.updated_at, running_slot: nil,
                    error: "stopped without finishing (no progress for #{STALE_AFTER.inspect})")
        log :warn, "run ##{run.id} #{run.task} given up: no progress since #{run.finished_at}"
      end
    end
    private_class_method :give_up_stale

    def self.log(level, message)
      SolrSearch.log(level, message)
    end
    private_class_method :log

    # Days to keep the records (plugin setting; 0 keeps them for ever)
    def self.retention_days
      Settings['run_retention_days'].to_i
    end

    # Called from ensure: a failure here (the database gone) is logged, not raised, so that it does not replace the
    # run's own result or failure (Gemini review 2026-10-05, item 8)
    def self.purge_old
      days = retention_days
      SolrSearchRun.finished.where(finished_at: ...days.days.ago).delete_all if days.positive?
    rescue StandardError => e
      log :error, "old run records could not be removed: #{e.class}: #{e.message}"
    end
    private_class_method :purge_old
  end
end
