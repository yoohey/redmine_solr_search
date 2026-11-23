# frozen_string_literal: true

module SolrSearch
  # What the admin page asks for, and who does it (design D-42, Q-20): the page writes a row of solr_search_runs with
  # the status "requested"; the scheduler (or `rake redmine:solr_search:requests`) takes it and runs it. The page never
  # runs anything itself: a long task would hold the web server, time out and die with a restart.
  module Requests
    # Raised when asking for a reindex the page should refuse. reason: :no_type, :unknown_type, :unknown_scope or :waiting (the screen
    # has a text for each); the message is for the log.
    class Invalid < StandardError
      attr_reader :reason

      def initialize(message, reason)
        super(message)
        @reason = reason
      end
    end

    # what run_next answers for a request that was refused (recorded as failed)
    REFUSED = :refused

    module_function

    # The asked types, each once, in the order of `allowed`. Pure (no database): checked by a light test.
    def normalize_types(types, allowed)
      asked = Array(types).map(&:to_s).reject(&:empty?).uniq
      raise Invalid.new('no type chosen', :no_type) if asked.empty?

      unknown = asked - allowed
      raise Invalid.new("unknown type(s): #{unknown.join(', ')}", :unknown_type) if unknown.any?

      allowed & asked
    end

    # Writes a request for a reindex of the types. Returns the row; raises Invalid when there is none to write: the same
    # types are already waiting (the page does not pile them up).
    # scope: a partial reindex (D-57), ReindexScope.normalize's result; its types are always the issues and their notes.
    # Two requests are the same when their types and their scopes are: a scope that overlaps another is not refused.
    def request_reindex(types, scope: nil)
      scope = ReindexScope.of(scope) # the ids sorted, each once: [3, 1] and [1, 3] are the same request
      if scope
        check_scope!(scope)
        types = PARTIAL_TYPES
      else
        types = normalize_types(types, Indexer.all_types) # attachments too: heavy, so the page offers them apart (D-42)
      end
      raise Invalid.new('the same request is already waiting', :waiting) if waiting.any? {|row| types_of(row) == types && scope_of(row) == scope}

      options = {'types' => types}
      options['scope'] = scope if scope
      SolrSearchRun.create!(task: 'reindex', status: 'requested', triggered_by: 'admin', request_options: options)
    end

    PARTIAL_TYPES = %w[issue journal].freeze

    # A tracker that is not there is refused (a typing mistake; a custom field may be gone: that is the point)
    def check_scope!(scope)
      return unless ReindexScope.kind(scope) == 'trackers'

      ids = ReindexScope.ids_of(scope)
      unknown = ids - Tracker.where(id: ids).pluck(:id)
      raise Invalid.new("unknown tracker(s): #{unknown.join(', ')}", :unknown_scope) if unknown.any?
    end
    private_class_method :check_scope!

    # The scope of a request (ReindexScope.normalize's result), or nil for a full one
    # (nil too for a stored scope that cannot be read: the run of such a request is refused, see run_next)
    def scope_of(row)
      ReindexScope.of(row.request_options.to_h['scope'])
    rescue ReindexScope::Invalid
      nil
    end

    # How many finished requests the page lists. They are ordinary run records: the retention setting removes them like
    # the others, so the page shows what is left of the last days.
    FINISHED_LISTED = 3

    # Whether a request is the attachments' own (their button, their list), not one of the other types
    def attachment_request?(row)
      types_of(row) == [Indexer::ATTACHMENT]
    end

    # The requests of the admin page that one section of the page lists, newest first: those waiting or running, and the
    # last FINISHED_LISTED that finished. The row of a request is the row of its run. attachments: the attachments' own
    # section's, or (default) the other one's.
    # rows: the rows of admin_rows, when the page lists both sections: they are read once (M6 review 22)
    def recent(attachments: false, rows: nil)
      rows = (rows || admin_rows).select {|row| attachment_request?(row) == attachments }
      finished, open = rows.partition {|row| %w[succeeded failed].include?(row.status)}
      (open + finished.first(FINISHED_LISTED)).sort_by {|row| -row.id }
    end

    # Every request of the admin page that is still kept, newest first
    def admin_rows
      SolrSearchRun.where(triggered_by: 'admin').order(id: :desc).to_a
    end

    # The requests that wait, oldest first
    def waiting
      SolrSearchRun.where(status: 'requested').order(:id)
    end

    def types_of(row)
      Array(row.request_options.to_h['types'])
    end

    # Takes a waiting request back. false when it is not waiting any more (started, finished or gone).
    def cancel(id)
      SolrSearchRun.where(id: id, status: 'requested').delete_all.positive?
    end

    # Runs the oldest waiting request (one: the next call takes the next). Returns the counts, or nil when there was
    # nothing to run, another run held the slot (the request stays and is tried again), or it was cancelled meanwhile.
    # A request that cannot be run at all (a type that is not there any more) is recorded as failed, not retried for ever,
    # and answers REFUSED: it is no longer waiting, so a caller that goes on until nothing waits goes on to the next one.
    def run_next(logger: nil)
      request = waiting.first or return nil

      types = types_of(request)
      begin
        Indexer.check_types!(types)
        # a scope that was written and cannot be read (the database changed by hand): refused, not left to block the others
        raise ArgumentError, 'the scope of the request cannot be read' if request.request_options.to_h['scope'].present? && scope_of(request).nil?
      rescue ArgumentError => e
        request.update!(status: 'failed', started_at: Time.current, finished_at: Time.current, error: e.message)
        SolrSearch.log(:warn, "request ##{request.id} refused: #{e.message}")
        return REFUSED
      end
      Tasks.reindex(types, triggered_by: 'admin', logger: logger, request: request, scope: scope_of(request))
    rescue TaskRun::Busy, TaskRun::Gone
      nil
    end
  end
end
