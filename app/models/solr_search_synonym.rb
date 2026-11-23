# frozen_string_literal: true

# The query expansion dictionary as it was saved (design D-53, Q-27). Rows are only added: the last is in force, the rest are
# the history. The text and what it means are SolrSearch::QueryDictionary's.
class SolrSearchSynonym < SolrSearchRecord
  belongs_to :user, optional: true

  # id of the row => its Dictionary: a row is never changed, so what was read from it stays right
  @cache = {}
  class << self
    attr_reader :cache
  end

  # The text in force ('' when none was saved)
  def self.current_text
    order(:id).last&.body.to_s
  end

  # The dictionary in force, for a search: an empty one when nothing was saved
  def self.dictionary
    row = order(:id).select(:id, :body).last
    return SolrSearch::QueryDictionary.empty unless row

    cache.clear if cache.size > 5
    cache[row.id] ||= SolrSearch::QueryDictionary.build(row.body)
  end

  def self.record(body, user: User.current)
    create!(user_id: (user.id if user&.logged?), user_login: user&.login.to_s, body: body.to_s, created_at: Time.current)
  end

  # The newest first, each with what changed from the row before: [[row, added lines, removed lines], ...]. Lines as written
  # (comments and blank lines left out), compared as sets.
  def self.history(limit = 10)
    rows = order(id: :desc).limit(limit + 1).to_a
    rows.first(limit).each_with_index.map do |row, i|
      now = lines_of(row.body)
      before = lines_of(rows[i + 1]&.body)
      [row, now - before, before - now]
    end
  end

  def self.lines_of(body)
    body.to_s.lines.map(&:strip).reject {|l| l.empty? || l.start_with?('#') }
  end
end
