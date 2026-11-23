# frozen_string_literal: true

# A project an administrator allowed to link an external index source (design D-34). Taking the allowance back also
# removes the project's link to the source, if it has one: nothing stays linked without being allowed.
class SolrSearchSourceAllowedProject < SolrSearchRecord
  belongs_to :source, class_name: 'SolrSearchSource', inverse_of: :allowed_projects
  belongs_to :project

  validates :project_id, uniqueness: {scope: :source_id}

  after_create { SolrSearchSourceChange.record('allowed', source: source, project: project) }
  after_destroy do
    owner = destroyed_by_association&.active_record
    # with the source, the links go by themselves; with the project too
    next if owner == SolrSearchSource

    reason = owner == Project ? 'project_deleted' : nil
    SolrSearchSourceChange.record('disallowed', source: source, project: project,
                                                details: reason && {'reason' => reason})
    source.unlink_unallowed if owner.nil?
  end
end
