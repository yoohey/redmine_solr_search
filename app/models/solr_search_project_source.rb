# frozen_string_literal: true

# A link between a project and an external index source (design D-4): with it, those who may search external documents
# in the project (design D-32) search the source. Every link made or removed is kept as history.
class SolrSearchProjectSource < SolrSearchRecord
  belongs_to :project
  belongs_to :source, class_name: 'SolrSearchSource', inverse_of: :project_sources

  validates :source_id, uniqueness: {scope: :project_id}
  # only a source the administrator allowed this project (design D-34)
  validate :allowed, on: :create

  # why the link goes, when it goes because of another change (the allowance taken back)
  attr_accessor :removal_reason

  after_create { SolrSearchSourceChange.record('linked', source: source, project: project) }
  after_destroy do
    # removed with its project or its source rather than on its own: said so in the history
    owner = destroyed_by_association&.active_record
    reason = {Project => 'project_deleted', SolrSearchSource => 'source_deleted'}[owner] || removal_reason
    SolrSearchSourceChange.record('unlinked', source: source, project: project, details: reason && {'reason' => reason})
  end

  private

  def allowed
    errors.add(:source_id, :inclusion) if source && project && !source.linkable_by?(project)
  end
end
