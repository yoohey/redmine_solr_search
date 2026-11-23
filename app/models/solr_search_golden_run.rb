# frozen_string_literal: true

# One run of a golden query set (design D-45; SolrSearch::Golden). details is JSON text.
class SolrSearchGoldenRun < SolrSearchRecord
  KINDS = %w[coverage ranking].freeze

  scope :of_kind, ->(kind) { where(kind: kind) }

  def self.latest(kind)
    of_kind(kind).order(ran_at: :desc, id: :desc).first
  end

  def details_list
    JSON.parse(details.to_s)
  rescue JSON::ParserError
    []
  end
end
