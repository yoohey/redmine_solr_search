# frozen_string_literal: true

# An external index source (design D-35): a collection of crawled documents chosen among Solr's, with a label and a
# description kept in Redmine. The collection name is kept as chosen and never changes. Who may search it comes from the projects it is linked to (design D-32, D-33).
# Every change is kept in SolrSearchSourceChange; a change of missing_collection_at alone is not one (update_all).
class SolrSearchSource < SolrSearchRecord
  # the links go first, each kept as history, then the source (design D-19, step 1)
  has_many :project_sources, class_name: 'SolrSearchProjectSource', foreign_key: :source_id, inverse_of: :source,
                             dependent: :destroy
  has_many :projects, through: :project_sources
  # which projects may link it, when not all of them (design D-34)
  has_many :allowed_projects, class_name: 'SolrSearchSourceAllowedProject', foreign_key: :source_id,
                              inverse_of: :source, dependent: :destroy

  validates :name, presence: true, length: {maximum: 255}, uniqueness: {case_sensitive: false}
  validates :collection, presence: true, length: {maximum: 255}, uniqueness: true
  # never "redmine", whose documents would pass without the permission conditions (design D-35)
  validate { errors.add(:collection, :invalid) if collection.present? && !SolrSearch.external_collection?(collection) }
  attr_readonly :collection

  # How the documents of the source are shown (design D-35): their path as text, or as a link by link_pattern
  LINK_FORMATS = %w[text link].freeze
  validates :link_format, inclusion: {in: LINK_FORMATS}
  validates :link_pattern, length: {maximum: SolrSearch::LinkPattern::MAX_LENGTH}
  validate do
    if link_format == 'link' && !SolrSearch::LinkPattern.valid?(link_pattern)
      errors.add(:link_pattern, I18n.t(:error_solr_search_link_pattern))
    end
  end

  # Where the documents are shown to be (design D-35): a path starting with path_from is shown with path_to instead
  validates :path_from, :path_to, length: {maximum: SolrSearch::PathMapping::MAX_LENGTH}
  validate { errors.add(:path_to, :blank) if path_from.present? && path_to.blank? }
  validate { errors.add(:path_from, :blank) if path_to.present? && path_from.blank? }
  validate { errors.add(:path_from, :invalid) if path_from.present? && !SolrSearch::PathMapping.valid_from?(path_from) }

  # What a change is recorded with
  DETAILS = %w[name description all_projects link_format link_pattern path_from path_to].freeze

  after_create { record('source_created', attributes.slice('collection', *DETAILS)) }
  after_update do
    changed = saved_changes.slice(*DETAILS)
    record('source_updated', changed) if changed.any?
  end
  after_destroy { record('source_deleted', attributes.slice('collection', *DETAILS)) }

  # Sources a project may link (design D-34): for all projects, or allowed to this one (not through a parent)
  def self.linkable_by(project)
    allowed = SolrSearchSourceAllowedProject.where(project_id: project.id).select(:source_id)
    where(all_projects: true).or(where(id: allowed))
  end

  def linkable_by?(project)
    all_projects? || allowed_projects.exists?(project_id: project.id)
  end

  # The projects allowed to link it (when not all), set from the admin form: rows added and removed one by one, so that
  # each change is kept as history and a link that is no longer allowed goes with it
  def linkable_project_ids=(ids)
    @pending_linkable_project_ids = Array(ids).compact_blank.map(&:to_i).uniq
  end

  def linkable_project_ids
    @pending_linkable_project_ids || allowed_projects.pluck(:project_id)
  end

  # the allowances first, then the links that are no longer allowed (all projects turned off, a project taken out)
  after_save :save_allowed_projects
  after_save :unlink_unallowed, if: -> { saved_change_to_all_projects?(from: true, to: false) }

  # Removes the links of projects that may not link it any more, each kept as history with the reason
  def unlink_unallowed
    project_sources.includes(:project).reject {|link| linkable_by?(link.project) }.each do |link|
      link.removal_reason = 'disallowed'
      link.destroy!
    end
  end

  # The path of a document as this source shows it (SolrSearch::PathMapping); the one in the index when it maps none
  def display_path(path)
    SolrSearch::PathMapping.map(path, path_from, path_to)
  end

  # The link of a hit of this source, or nil when the source shows the path as text (or its pattern is not valid).
  # %path% is the path as shown (display_path).
  def link_for(hit)
    return unless link_format == 'link' && SolrSearch::LinkPattern.valid?(link_pattern)

    SolrSearch::LinkPattern.expand(link_pattern, url: hit.url, path: display_path(hit.path), title: hit.title, id: hit.id)
  end

  def to_s
    name
  end

  private

  def save_allowed_projects
    return unless @pending_linkable_project_ids

    ids = @pending_linkable_project_ids
    @pending_linkable_project_ids = nil
    current = allowed_projects.pluck(:project_id)
    Project.where(id: ids - current).find_each {|project| allowed_projects.create!(project: project) }
    allowed_projects.where(project_id: current - ids).includes(:project).find_each(&:destroy!)
  end

  def record(action, details)
    SolrSearchSourceChange.record(action, source: self, details: details)
  end
end
