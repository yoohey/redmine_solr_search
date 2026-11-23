# frozen_string_literal: true

# Administration > Full-text search (design D-28): the status tab (the state of Solr and of the crawl, the address of Solr, the requests for a
# reindex), the external sources and the history of their changes. The fine tuning and the dictionary are in SolrSearchTuningController, the search
# log in SolrSearchLogController; what the three share is in SolrSearchAdminBaseController (Q-40).
class SolrSearchAdminController < SolrSearchAdminBaseController
  RECENT_RUNS = 20

  # A collection name that the page does not save: reason is :format or :taken (the screen has a text for each)
  class InvalidCollection < StandardError
    attr_reader :reason

    def initialize(reason)
      super(reason.to_s)
      @reason = reason
    end
  end

  def index
    # what saving the address left for this page: shown in the box of the address, not at the top (design D-43)
    @solr_url_result = session.delete(:solr_search_solr_url_result)
    # the Tika box under it (design D-61): what its save left, and whether Tika answers now. Asked before Solr, which may
    # not be set (the rescue below)
    @tika_url_result = session.delete(:solr_search_tika_url_result)
    # not asked when the attachments run is off: Tika is not used, and the box says only that (Gemini review 2026-11-09, Q1).
    # 2 seconds at most each to connect and to answer, so that a Tika that is down holds the page back little (Q2)
    if SolrSearch::Settings['schedule_attachments_enabled'] == '1'
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @tika_alive = SolrSearch::TikaClient.configured(open_timeout: 2).alive?(read_timeout: 2)
      # how long it took to answer, shown like Solr's QTime ("connected (n ms)")
      @tika_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
    # the crawl runs come from Redmine's database, so they are shown even when Solr is not reachable (design D-22)
    load_runs
    @heartbeat = SolrSearchHeartbeat.find_by(name: SolrSearch::Scheduler::NAME)
    @next_runs = SolrSearch::Scheduler::TASKS.index_with {|task| SolrSearch::Scheduler.next_run(task)}
    @status = SolrSearch::Status.new
    # custom fields whose values only the index has (deleted ones): a line on this tab, when Solr answers (D-57)
    @deleted_fields = begin
      SolrSearch::ReindexTargets.deleted_fields(admin_client) if @status.ready?
    rescue SolrSearch::Client::Error
      nil
    end
  rescue SolrSearch::Client::Error => e # SOLR_URL not set
    @config_error = e.message
  end

  # The reindexes asked for, and the lists of those waiting, running and done (design D-42)
  def reindex
    load_runs
    request_rows = SolrSearch::Requests.admin_rows
    @requests = SolrSearch::Requests.recent(rows: request_rows)
    @attachment_requests = SolrSearch::Requests.recent(attachments: true, rows: request_rows)
    @heartbeat = SolrSearchHeartbeat.find_by(name: SolrSearch::Scheduler::NAME)
    @next_runs = SolrSearch::Scheduler::TASKS.index_with {|task| SolrSearch::Scheduler.next_run(task)}
    @trackers = Tracker.sorted.to_a
    @fields = IssueCustomField.sorted.to_a
    # the custom fields only the index has (deleted ones): looked for when the button is pressed, not at each visit (D-57)
    if params[:inspect].present?
      begin
        @deleted_fields = SolrSearch::ReindexTargets.deleted_fields(admin_client)
      rescue SolrSearch::Client::Error => e
        @inspect_error = e.message
      end
    end
  end

  # The custom fields only the index has (deleted ones), as JSON for the index tab's button (no reload of the page)
  def reindex_inspect
    render json: {fields: SolrSearch::ReindexTargets.deleted_fields(admin_client)}
  rescue SolrSearch::Client::Error => e
    render json: {error: e.message}
  end

  # About how many issues a partial reindex of the trackers or the fields in the query would send (JSON, for the index tab)
  def reindex_estimate
    scope = SolrSearch::ReindexScope.normalize(trackers: params[:trackers], fields: params[:fields])
    return render(json: {count: nil}) unless scope

    render json: {count: SolrSearch::ReindexTargets.estimate(scope, admin_client)}
  rescue SolrSearch::ReindexScope::Invalid
    render json: {count: nil}
  rescue SolrSearch::Client::Error => e
    render json: {count: nil, error: e.message}
  end

  # External index sources (design D-34): the list, with what the admin page finds wrong in Solr (design D-33)
  def sources
    @sources = SolrSearchSource.includes(:projects, allowed_projects: :project).order(:name).to_a
    status = SolrSearch::SourceStatus.new(client: admin_client)
    @solr_error = status.error
    @checks = status.check(@sources)
    # Solr's collections that are no source yet: a source is chosen among them (design D-35)
    @candidates = status.candidates(@sources)
  rescue SolrSearch::Client::Error => e # SOLR_URL not set
    @config_error = e.message
  end

  # The Solr address and the collection of Redmine's data, set on the status tab (design D-43, D-44). Saved whether or not
  # Solr answers there. The outcome goes into the box of the address on the page that follows (not into a message at the
  # top), where the state that was found is shown too. The address box holds the address in use, so an address that is the
  # environment variable SOLR_URL's own value is not kept as a setting made here (the variable stays in charge); an empty
  # address means the variable too. An empty collection name: redmine.
  def update_solr_url
    address = address_from(params[:solr_url])
    address = '' if address == (address_from(ENV['SOLR_URL']) rescue nil)
    # the collection is changed only when the form sent it: a request without it (another client, an old page) must not put
    # the default back (M6 review 17)
    changes = {'solr_url' => address}
    changes['redmine_collection'] = collection_from(params[:collection]) if params.key?(:collection)
    before = solr_connection
    store_settings(changes)
    record_solr_connection(before)
    solr_url_result(:notice, l(address.empty? ? :notice_solr_search_solr_url_env : :notice_solr_search_solr_url_saved))
  rescue SolrSearch::SolrUrl::Invalid => e
    solr_url_result(:error, l(:"error_solr_search_solr_url_#{e.reason}"))
  rescue InvalidCollection => e
    solr_url_result(:error, l(:"error_solr_search_collection_#{e.reason}"))
  ensure
    redirect_to solr_search_admin_path
  end

  # The Tika address, set on the status tab under Solr's (design D-61). Like the Solr address: checked for its writing only
  # and saved whether or not Tika answers there; the environment variable TIKA_URL's own value, or an empty box, is not kept
  # as a setting made here. The outcome goes into the box of Tika on the page that follows.
  def update_tika_url
    address = address_from(params[:tika_url])
    address = '' if address == (address_from(ENV['TIKA_URL']) rescue nil)
    before = SolrSearch::Settings.tika_address.first
    store_settings('tika_url' => address)
    after = SolrSearch::Settings.tika_address.first
    SolrSearchSourceChange.record('tika_connection', details: {'tika_url' => [before, after]}) if before != after
    tika_url_result(:notice, l(address.empty? ? :notice_solr_search_tika_url_env : :notice_solr_search_tika_url_saved))
  rescue SolrSearch::SolrUrl::Invalid => e
    # the same rules as Solr's address, and the same texts but the one that names Solr
    tika_url_result(:error, l(e.reason == :userinfo ? :error_solr_search_tika_url_userinfo : :"error_solr_search_solr_url_#{e.reason}"))
  ensure
    redirect_to solr_search_admin_path
  end

  # A full reindex asked for (design D-42, Q-20): only written down here; the scheduler (or rake ...:requests) runs it
  def create_request
    begin
      scope = partial_scope
      SolrSearch::Requests.request_reindex(params[:types], scope: scope)
      flash[:notice] = l(:notice_solr_search_request_created)
      count = scope && partial_estimate(scope)
      flash[:notice] += " #{l(:text_solr_search_partial_count, count: count)}" if count
    rescue SolrSearch::Requests::Invalid, SolrSearch::ReindexScope::Invalid => e
      flash[:error] = l(:"error_solr_search_request_#{e.reason}")
    end
    redirect_to solr_search_admin_reindex_path
  end

  # Takes a waiting request back
  def cancel_request
    if SolrSearch::Requests.cancel(params[:id])
      flash[:notice] = l(:notice_solr_search_request_cancelled)
    else
      flash[:error] = l(:error_solr_search_request_not_waiting)
    end
    redirect_to solr_search_admin_reindex_path
  end

  # The last run of each task, and the latest runs (the status tab and the index tab show them)
  def load_runs
    @last_runs = SolrSearchRun::TASKS.index_with do |task|
      SolrSearchRun.where(task: task).where.not(status: 'requested').order(id: :desc).first
    end
    @recent_runs = SolrSearchRun.order(id: :desc).limit(RECENT_RUNS).to_a
  end
  private :load_runs

  CHANGES_PER_PAGE = 50

  # The history of the sources and their links (design D-32), newest first; one source's when source_id is given
  def changes
    scope = SolrSearchSourceChange.includes(:user).order(id: :desc)
    if params[:source_id].present?
      @source_id = params[:source_id].to_i
      scope = scope.where(source_id: @source_id)
    end
    @change_count = scope.count
    @change_pages = Redmine::Pagination::Paginator.new(@change_count, CHANGES_PER_PAGE, params[:page])
    @changes = scope.offset(@change_pages.offset).limit(@change_pages.per_page).to_a
  end

  private

  # The scope of a partial reindex that the form asks for (design D-57): the trackers or the custom fields it chose; nil when
  # it is not a partial one. Nothing chosen is refused.
  def partial_scope
    kind = params[:scope_kind].presence or return
    raise SolrSearch::ReindexScope::Invalid.new("unknown kind: #{kind.to_s[0, 20]}", :bad_id) unless SolrSearch::ReindexScope::KINDS.include?(kind)

    SolrSearch::ReindexScope.normalize(kind.to_sym => params[kind]) or
      raise SolrSearch::ReindexScope::Invalid.new('nothing chosen', :no_scope)
  end

  # About how many issues; nil when Solr does not answer (the notice then has no number)
  def partial_estimate(scope)
    SolrSearch::ReindexTargets.estimate(scope, admin_client)
  rescue SolrSearch::Client::Error
    nil
  end

  # What the admin page saves goes into the plugin settings (SolrSearch::Settings.update: the change is logged)
  # What is in use (a value of the environment variable or the default included), as a history row compares them
  def solr_connection
    {'solr_url' => SolrSearch::Settings.solr_address.first, 'collection' => SolrSearch::Settings.redmine_collection}
  end

  def record_solr_connection(before)
    details = solr_connection.each_with_object({}) do |(field, value), changed|
      changed[field] = [before[field], value] if before[field] != value
    end
    SolrSearchSourceChange.record('solr_connection', details: details) if details.any?
  end

  def store_settings(changes)
    SolrSearch::Settings.update(changes, by: User.current.login)
  end

  # The address as it is kept: '' for none (the environment variable); Invalid when it is badly written
  def address_from(text)
    text.to_s.strip.empty? ? '' : SolrSearch::SolrUrl.normalize(text)
  end

  # The collection's name as it is kept: '' for the default. A name that Solr refuses, or that an external source uses
  # (its documents would be mixed up with Redmine's in the filter of D-33), raises InvalidCollection.
  def collection_from(text)
    name = text.to_s.strip
    return '' if name.empty?
    raise InvalidCollection, :format unless SolrSearch::COLLECTION_NAME.match?(name)
    raise InvalidCollection, :taken if SolrSearchSource.exists?(collection: name)

    name
  end

  # What the page after a save says in the box of the address: level is :notice or :error
  def solr_url_result(level, text)
    session[:solr_search_solr_url_result] = {'level' => level.to_s, 'text' => text}
  end

  # The same for the box of Tika
  def tika_url_result(level, text)
    session[:solr_search_tika_url_result] = {'level' => level.to_s, 'text' => text}
  end
end
