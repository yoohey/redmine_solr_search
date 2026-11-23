# frozen_string_literal: true

# The tuning of the order of the results as it was saved (design D-51, Q-34). Rows are only added: the last is in force, the
# rest are the history. The values and what they mean are SolrSearch::Tuning's.
class SolrSearchTuning < SolrSearchRecord
  belongs_to :user, optional: true
  serialize_json :settings

  # The tuning in force: the last saved, with the defaults for what it lacks (a row of an older version of the tab, or none)
  def self.current
    SolrSearch::Tuning.normalize(order(:id).last&.settings)
  end

  def self.record(tuning, user: User.current)
    create!(user_id: (user.id if user&.logged?), user_login: user&.login.to_s, settings: tuning, created_at: Time.current)
  end

  # The newest first, each with what it changed from the one before: [[row, [[path, before, after], ...]], ...]
  def self.history(limit = 10)
    rows = order(id: :desc).limit(limit + 1).to_a
    rows.first(limit).each_with_index.map do |row, i|
      before = SolrSearch::Tuning.normalize(rows[i + 1]&.settings)
      [row, SolrSearch::Tuning.changes(before, SolrSearch::Tuning.normalize(row.settings))]
    end
  end
end
