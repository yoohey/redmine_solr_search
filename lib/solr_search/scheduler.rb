# frozen_string_literal: true

require 'socket'

module SolrSearch
  # The default way to start the crawl tasks (design D-22): a long-running process (rake redmine:solr_search:scheduler,
  # the scheduler service in Docker) that wakes every minute, reads the plugin settings again and runs each task whose
  # interval has passed since its last start. Anything else can start the same tasks instead (cron ...): the tasks
  # record their runs and never run two at a time, whoever starts them.
  class Scheduler
    TICK = 60 # seconds
    TASKS = %w[incremental resend reconcile attachments].freeze
    NAME = 'scheduler'
    BEAT_EVERY = 10 # seconds: the least time between two beats while a task reports progress

    # When the task is due next: nil when the scheduler does not run it (disabled), now when it never ran
    def self.next_run(task)
      interval = Settings.interval(task) or return nil
      last = last_start(task)
      last ? last + interval : Time.current
    end

    # The last start of the task, failed runs included (a Solr that is down is not retried every minute). For the
    # incremental crawl a full reindex counts too: with no earlier run, an incremental crawl runs a full reindex.
    def self.last_start(task)
      runs = SolrSearchRun.where.not(status: 'requested')
      return runs.where(task: task).maximum(:started_at) unless task == 'incremental'

      last = runs.where(task: 'incremental').maximum(:started_at)
      # a partial reindex (D-57), or one of some types only (a request for the documents ...), does not count: it is not
      # the reindex of everything the incremental crawl would otherwise wait for
      reindexes = runs.where(task: 'reindex').where(SolrSearchRun::NOT_PARTIAL).order(started_at: :desc)
      reindexes = reindexes.where('started_at > ?', last) if last
      full = reindexes.find {|run| ReindexScope.covers?(run.request_options, run.counts, Indexer.types) }
      [last, full&.started_at].compact.max
    end

    def initialize
      @started_at = Time.current
      @info = "#{Socket.gethostname} pid #{Process.pid}"
    end

    # Runs until stopped (SIGTERM from docker compose stop, Ctrl-C). A task running then is recorded as failed.
    def run
      log :info, "scheduler started (#{@info}, every #{TICK} s)"
      loop do
        tick
        sleep TICK
      end
    rescue SignalException => e # Interrupt is one too
      log :info, "scheduler stopped (#{e.class}: #{e.message})"
    end

    def tick
      Setting.check_cache # settings changed on the settings page since the last tick
      beat(force: true)
      run_request
      TASKS.each do |task|
        next_run = self.class.next_run(task)
        next unless next_run && next_run <= Time.current

        Tasks.public_send(task, triggered_by: 'scheduler', logger: ->(_message) { beat })
      rescue TaskRun::Busy
        # another run holds the slot (TaskRun has logged it); try again at the next tick
      rescue StandardError
        # recorded and logged by TaskRun; the next try is an interval later
      end
    rescue StandardError => e # the database not ready, the tables not there yet (migrations): wait and go on
      log :error, "scheduler tick failed: #{e.class}: #{e.message}"
    end

    private

    # A request from the admin page (design D-42): one per tick, before the scheduled tasks. Busy and a request that
    # fails are left to TaskRun and Requests (recorded and logged); the scheduler goes on to its own tasks.
    def run_request
      Requests.run_next(logger: ->(_message) { beat })
    rescue StandardError => e
      # a failed run is recorded and logged by TaskRun; what else goes wrong (the database ...) is said here, and the next
      # request is taken at the next tick (M6 review 22)
      log :warn, "a request could not be run: #{e.class}: #{e.message}"
    end

    def beat(force: false)
      now = Time.current
      return if !force && @beat_at && now - @beat_at < BEAT_EVERY

      # create_or_find_by!: two schedulers beating for the first time at once do not fail on the unique index. Only when the
      # row is not there: it inserts first, so at each beat the database would log the unique violation as an error (O-47)
      heartbeat = SolrSearchHeartbeat.find_by(name: NAME) || SolrSearchHeartbeat.create_or_find_by!(name: NAME)
      heartbeat.update!(info: @info, started_at: @started_at, beat_at: now)
      @beat_at = now
    end

    def log(level, message)
      SolrSearch.log(level, message)
    end
  end
end
