# frozen_string_literal: true

module SolrSearch
  # The crawl tasks of design D-22, as rake, the scheduler and (later) the admin page start them. Each goes through
  # TaskRun: recorded, and never two at a time. logger: a callable that takes a progress message, or nil.
  module Tasks
    # The incremental crawl starts this much before the start of the last good run, so that nothing changed while
    # that run was reading is missed. Sending a record twice gives the same result.
    OVERLAP = 5.minutes

    module_function

    # Process 4: every record of the given types, overwritten. Removes nothing. An unknown type is refused before
    # anything is recorded (a typo in TYPES= is not a failed run).
    # request: a waiting row of the admin page that becomes the run (design D-42)
    def reindex(types = Indexer.types, triggered_by:, logger: nil, request: nil, scope: nil)
      return reindex_partial(scope, triggered_by: triggered_by, logger: logger, request: request) if scope

      Indexer.check_types!(types)
      # the types are written, so that a reindex of some types only is not taken for the incremental crawl's (Scheduler)
      TaskRun.perform('reindex', triggered_by: triggered_by, request: request, options: {'types' => types}) do |run|
        Indexer.new(logger: progress(run, logger)).reindex(types)
      end
    end

    # Process 4 limited to the issues of a scope (design D-57): its issues and their notes, and the permission and custom
    # field values of their attachments. The run records the scope, so that the starting point of the incremental crawl
    # and the schedule leave it out (incremental_since, Scheduler.last_start).
    # scope: ReindexScope.normalize's result
    def reindex_partial(scope, triggered_by:, logger: nil, request: nil)
      TaskRun.perform('reindex', triggered_by: triggered_by, request: request,
                                 options: {'types' => %w[issue journal], 'scope' => scope}) do |run|
        Indexer.new(logger: progress(run, logger)).reindex_partial(scope)
      end
    end

    # Process 1. With nothing to start from (just installed), a full reindex instead.
    def incremental(triggered_by:, logger: nil)
      since = incremental_since
      return reindex(triggered_by: triggered_by, logger: logger) unless since

      TaskRun.perform('incremental', triggered_by: triggered_by, since: since) do |run|
        Indexer.new(logger: progress(run, logger)).incremental(since)
      end
    end

    # Process 5 (design D-36): the attachments the index does not have yet, with the text of their files. A run takes at
    # most PER_RUN of them and stops starting new ones after RUN_SECONDS; the next run goes on.
    ATTACHMENTS_PER_RUN = 200
    # the scheduler runs one task at a time: a long run would keep the incremental crawl waiting (M4 review, #18)
    ATTACHMENTS_RUN_SECONDS = 180

    def attachments(triggered_by:, logger: nil)
      TaskRun.perform('attachments', triggered_by: triggered_by) do |run|
        AttachmentIndexer.new(logger: progress(run, logger)).crawl(limit: ATTACHMENTS_PER_RUN, seconds: ATTACHMENTS_RUN_SECONDS)
      end
    end

    # Process 2: wiki pages and documents sent again (their edits leave no timestamp)
    def resend(triggered_by:, logger: nil)
      TaskRun.perform('resend', triggered_by: triggered_by) do |run|
        Indexer.new(logger: progress(run, logger)).resend
      end
    end

    # Process 3: removes from the index what Redmine no longer has in scope
    def reconcile(triggered_by:, logger: nil)
      TaskRun.perform('reconcile', triggered_by: triggered_by) do |run|
        Indexer.new(logger: progress(run, logger)).reconcile
      end
    end

    # OVERLAP before the start of the last successful incremental crawl or full reindex (of every type: one limited
    # to some types does not cover the others); nil when there is none.
    # Reads the last incremental crawl and the reindexes after it only, not every record (M1 review A8).
    def incremental_since
      succeeded = SolrSearchRun.where(status: 'succeeded')
      last = succeeded.where(task: 'incremental').order(started_at: :desc).first
      # a partial reindex (D-57) is no starting point, whatever its counts show
      reindexes = succeeded.where(task: 'reindex').where(SolrSearchRun::NOT_PARTIAL).order(started_at: :desc)
      reindexes = reindexes.where('started_at > ?', last.started_at) if last
      start = reindexes.find {|run| (Indexer.types - run.counts.to_h.keys).empty?}&.started_at || last&.started_at
      start && (start - OVERLAP)
    end

    # Reports progress and keeps the run alive (TaskRun::STALE_AFTER); raises TaskRun::SlotLost when it was given up
    def progress(run, logger)
      lambda do |message|
        logger&.call(message)
        TaskRun.keep_alive(run)
      end
    end
    private_class_method :progress
  end
end
