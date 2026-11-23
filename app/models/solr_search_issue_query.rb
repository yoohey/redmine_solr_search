# frozen_string_literal: true

# The "Filters" of the search screen (design D-49): Redmine's own issue query, narrowed to the filters that the index can do.
# It is never saved. Redmine draws the filters (queries/_filters) and reads them from the parameters (build_from_params); the
# search writes them for Solr (SolrSearch::FilterTranslator). The list below is what the index holds of an issue; the custom
# fields are those that are used as a filter and that the user may see (SolrSearch::CustomFieldQuery.facets_for).
class SolrSearchIssueQuery < IssueQuery
  FILTERS = %w[status_id tracker_id priority_id author_id assigned_to_id fixed_version_id category_id
               updated_on created_on closed_on start_date due_date].freeze

  # The operators of Redmine that the translation knows; the history ones (has been, was changed from) are not among them
  OPERATORS = (SolrSearch::FilterTranslator::STATUS_OPERATORS + SolrSearch::FilterTranslator::NUMBER_OPERATORS +
               SolrSearch::FilterTranslator::DATE_OPERATORS).uniq.freeze
  self.operators_by_filter_type = ::Query.operators_by_filter_type.transform_values {|operators| operators & OPERATORS }

  # The ids of the custom fields that can be filters for this user
  def self.custom_field_filters(user)
    SolrSearch::CustomFieldQuery.facets_for(user).map {|custom| "cf_#{custom.id}" }
  end

  def initialize_available_filters
    super
    allowed = FILTERS + self.class.custom_field_filters(User.current)
    @available_filters = @available_filters.slice(*allowed)
  end
end
