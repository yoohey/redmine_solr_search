# frozen_string_literal: true

# A run of a crawl task (design D-22). Started and finished through SolrSearch::TaskRun.
class SolrSearchRun < SolrSearchRecord
  TASKS = %w[incremental resend reconcile attachments reindex].freeze
  STATUSES = %w[requested running succeeded failed].freeze
  TRIGGERS = %w[scheduler rake admin].freeze

  serialize_json :counts
  serialize_json :request_options # what a request from the admin page asks for (design D-42)

  validates :task, inclusion: {in: TASKS}
  validates :status, inclusion: {in: STATUSES}
  validates :triggered_by, inclusion: {in: TRIGGERS}

  # Not a partial reindex (design D-57): its options have no scope. In SQL, so that a long history is not read to find the
  # newest (request_options is JSON text; the key is written with its quotes).
  NOT_PARTIAL = "request_options IS NULL OR request_options NOT LIKE '%\"scope\":%'"

  scope :finished, -> { where(status: %w[succeeded failed]) }

  # Seconds; nil when unknown (never negative, even if the times were moved by hand)
  def duration
    return unless started_at && finished_at

    seconds = finished_at - started_at
    seconds if seconds >= 0
  end
end
