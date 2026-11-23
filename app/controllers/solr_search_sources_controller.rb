# frozen_string_literal: true

# Administration > Full-text search > External sources (design D-34, D-35): registering a source by choosing one of
# Solr's collections (made from the configset src, never Redmine's own) and labelling it; changing its label and the
# projects that may link it; deleting it. The collections themselves are made and deleted outside Redmine (Q-12 (b)).
class SolrSearchSourcesController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :solr_search

  helper :solr_search_admin
  before_action :require_admin
  before_action :find_source, only: [:edit, :update, :destroy]
  before_action :load_candidates, only: [:new, :create]

  def new
    @source = SolrSearchSource.new(collection: params[:collection])
  end

  def create
    @source = SolrSearchSource.new(source_params.merge(collection: params.dig(:solr_search_source, :collection)))
    refusal = @source.collection.present? && @status.refusal(@source.collection)
    # chosen among the collections Solr has now, made from the configset src (design D-35)
    @source.errors.add(:collection, l(:"error_solr_search_source_collection_#{refusal}")) if refusal
    if !refusal && @source.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to solr_search_admin_sources_path
    else
      @source.validate unless refusal # the model's own errors too, when Solr had none
      render :new, status: :unprocessable_content
    end
  end

  def edit
    load_edit_sample_path
  end

  def update
    @source.assign_attributes(source_params)
    if @source.save
      flash[:notice] = l(:notice_successful_update)
      warn_about_collection
      redirect_to solr_search_admin_sources_path
    else
      load_edit_sample_path
      render :edit, status: :unprocessable_content
    end
  end

  # The first of the steps of design D-19: the source and its links go (searches stop asking its collection at once);
  # the collection stays in Solr until an administrator deletes it (the sources tab says how; no reminder here)
  def destroy
    @source.destroy!
    flash[:notice] = l(:notice_successful_delete)
    redirect_to solr_search_admin_sources_path
  end

  private

  def find_source
    @source = SolrSearchSource.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # the collection is set on creation only (attr_readonly)
  def source_params
    params.require(:solr_search_source).permit(:name, :description, :all_projects, :link_format, :link_pattern, :path_from, :path_to, linkable_project_ids: [])
  end

  def load_candidates
    @status = SolrSearch::SourceStatus.new(client: SolrSearch::Status.admin_client)
    @candidates = @status.candidates(SolrSearchSource.all.to_a)
    @sample_paths = @candidates.select(&:selectable).to_h {|c| [c.name, @status.sample_path(c.name)] }.compact
  rescue SolrSearch::Client::Error => e # SOLR_URL not set
    @config_error = e.message
    render 'solr_search_sources/no_solr'
  end

  def load_edit_sample_path
    status = SolrSearch::SourceStatus.new(client: SolrSearch::Status.admin_client)
    path = status.sample_path(@source.collection)
    @sample_paths = path ? {@source.collection => path} : {}
  rescue SolrSearch::Client::Error
    @sample_paths = {}
  end

  # The collection may have gone since it was chosen: saving is not refused, the list marks it too (design D-33)
  def warn_about_collection
    status = SolrSearch::SourceStatus.new(client: SolrSearch::Status.admin_client)
    check = status.check([@source])[@source.id]
    key = {missing: :warning_solr_search_source_missing, wrong_configset: :warning_solr_search_source_wrong_configset,
           unknown: :warning_solr_search_source_unknown}[check.state]
    flash[:warning] = l(key, collection: @source.collection, configset: check.configset, error: check.error) if key
  rescue SolrSearch::Client::Error => e # SOLR_URL not set
    flash[:warning] = l(:warning_solr_search_source_unknown, error: e.message)
  end
end
