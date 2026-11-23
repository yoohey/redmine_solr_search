# frozen_string_literal: true

# Project settings > Full-text search (design D-34): links external index sources to a project.
class SolrSearchProjectSourcesController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def update
    linkable_sources = SolrSearchSource.linkable_by(@project)
    linkable_ids = linkable_sources.pluck(:id)
    # the form sends a list (with an empty value, so that unchecking all is sent); anything else is no list of ids: it
    # is refused, not taken as "none" (that would unlink everything)
    raw = params[:source_ids]
    return head(:bad_request) unless raw.nil? || (raw.is_a?(Array) && raw.all?(String))

    submitted_ids = Array(raw).grep(/\A\d+\z/).map(&:to_i).uniq

    # Unallowed sources cannot be linked (design D-34)
    unallowed = submitted_ids - linkable_ids
    if unallowed.any?
      flash[:error] = l(:error_solr_search_source_not_allowed)
      redirect_to settings_project_path(@project, tab: 'solr_search')
      return
    end

    # Disallow newly linking invalid sources if Solr answers (design D-34)
    begin
      status = SolrSearch::SourceStatus.new(client: SolrSearch::Status.admin_client)
      if status.answered?
        current_ids = @project.solr_search_project_sources.pluck(:source_id)
        to_add = submitted_ids - current_ids
        checks = status.check(linkable_sources.where(id: to_add), count_wrong_source: false)
        invalid = checks.select {|_id, check| check.state.in?(%i[missing wrong_configset]) }
        if invalid.any?
          flash[:error] = l(:error_solr_search_source_invalid)
          redirect_to settings_project_path(@project, tab: 'solr_search')
          return
        end
      end
    rescue SolrSearch::Client::Error
      # Solr unreachable: do not block unless required
    end

    current_ids = @project.solr_search_project_sources.pluck(:source_id)
    to_add = submitted_ids - current_ids
    to_remove = current_ids - submitted_ids

    begin
      ActiveRecord::Base.transaction do
        to_remove.each do |source_id|
          @project.solr_search_project_sources.where(source_id: source_id).destroy_all
        end
        to_add.each do |source_id|
          @project.solr_search_project_sources.create!(source_id: source_id)
        end
      end
      flash[:notice] = l(:notice_solr_search_project_sources_updated, count: @project.solr_search_project_sources.count)
    rescue ActiveRecord::RecordInvalid
      # the allowance was taken back between the check above and the save: nothing was changed
      flash[:error] = l(:error_solr_search_source_not_allowed)
    end
    redirect_to settings_project_path(@project, tab: 'solr_search')
  end
end
