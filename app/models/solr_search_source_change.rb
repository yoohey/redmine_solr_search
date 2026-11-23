# frozen_string_literal: true

# The history of the external index sources and their links (design D-32): the links are the only thing that guards
# external documents, so a mistake must be traceable. The names are kept as they were, so a row stays readable after
# its source or project is gone. Rows are only added. The Solr address and collection, and the Tika address, are kept here too (no source).
class SolrSearchSourceChange < SolrSearchRecord
  ACTIONS = %w[source_created source_updated source_deleted allowed disallowed linked unlinked solr_connection tika_connection].freeze

  belongs_to :user, optional: true
  serialize_json :details

  validates :action, inclusion: {in: ACTIONS}

  # user: who made the change; nobody (nil) when no one is logged in (a rake task, rails runner)
  def self.record(action, source: nil, project: nil, details: nil, user: User.current)
    create!(action: action, user_id: (user.id if user&.logged?),
            source_id: source&.id, source_name: source&.name,
            project_id: project&.id, project_name: project&.name, details: details)
  end

  def readonly?
    persisted?
  end
end
