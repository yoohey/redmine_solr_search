# frozen_string_literal: true

# The last sign of life of a long-running process (the crawl scheduler; design D-22)
class SolrSearchHeartbeat < SolrSearchRecord
  # No beat for this long: the admin page warns
  SILENT_AFTER = 5.minutes

  def silent?
    beat_at.nil? || beat_at < SILENT_AFTER.ago
  end
end
