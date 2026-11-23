# frozen_string_literal: true

# The search log tab of Administration > Full-text search (design D-45): the list with the tops, the zip of CSV files, and the deletion.
# Its view is in app/views/solr_search_admin.
class SolrSearchLogController < SolrSearchAdminBaseController
  LOG_PER_PAGE = 50

  LOG_PERIODS = [7, 30, 90].freeze

  # The search log (design D-45): who searched what, newest first, and what was opened from the result list. Only an
  # administrator sees it. The tops and the totals are of the first pages of the searches (a page 2 is the same search
  # again), in the chosen period. A search that found something and had no click is the sign of a search that did not help.
  def search_log
    in_period, scope = log_filters
    @log_count = scope.count
    @log_pages = Redmine::Pagination::Paginator.new(@log_count, LOG_PER_PAGE, params[:page])
    @logs = scope.offset(@log_pages.offset).limit(@log_pages.per_page).to_a
    @clicks = SolrSearchClick.where(log_id: @logs.map(&:id)).order(:id).group_by(&:log_id)
    # a page link used in the background: the list alone (the tops and the totals do not change with the page)
    # the same address answers a page and (to a script) the list alone: a cache must keep the two apart
    response.headers['Vary'] = 'X-Requested-With'
    return render(partial: 'log_list', layout: false) if request.xhr?

    first_pages = in_period.where(page: 1)
    # the five totals in one pass over the rows of the period (they were five), and no subquery over the clicks: a search that
    # was clicked has its clicked_at (M6 review 10)
    searches, zero, failed, found_count, clicked_count = first_pages.pick(
      Arel.sql('COUNT(*)'), Arel.sql('SUM(CASE WHEN hit_count = 0 AND error IS NULL THEN 1 ELSE 0 END)'),
      Arel.sql('SUM(CASE WHEN error IS NOT NULL THEN 1 ELSE 0 END)'), Arel.sql('SUM(CASE WHEN hit_count > 0 THEN 1 ELSE 0 END)'),
      Arel.sql('SUM(CASE WHEN hit_count > 0 AND clicked_at IS NOT NULL THEN 1 ELSE 0 END)')
    )
    @totals = {searches: searches.to_i, zero: zero.to_i, failed: failed.to_i, found: found_count.to_i, clicked: clicked_count.to_i}
    @top_zero, @top_noclick = SolrSearchLog.tops(first_pages)
    @top_queries = SolrSearchLog.top(first_pages.where(error: nil))
    opened = SolrSearchClick.where(log_id: in_period.select(:id))
    @top_opened = opened.group(:group_id).order(Arel.sql('COUNT(*) DESC')).limit(SolrSearchLog::TOP).count
    # what the item was called when it was opened (its latest click's title): the latest click of each, not every click of it
    latest = SolrSearchClick.where(group_id: @top_opened.keys).group(:group_id).maximum(:id).values
    @opened_titles = SolrSearchClick.where(id: latest).pluck(:group_id, :title).to_h
  end

  # The log as a zip of CSV files for work by hand (design D-45): the searches, the clicks, how the collections are, and a
  # README. What the list shows is filtered by the same conditions, but all of it is written, not a page. Written to
  # files while it is read in batches, so that a log of years is not held in memory.
  def export_search_log
    _in_period, scope = log_filters
    counts = {logs: 0, clicks: 0}
    files = %w[search_log search_clicks collections].index_with {|name| Tempfile.new(["solr-search-#{name}", '.csv'], binmode: true) }
    x = SolrSearch::LogExport
    ids = scope.unscope(:order)
    log_rows = Enumerator.new do |out|
      ids.find_in_batches(batch_size: 1000) do |batch|
        clicks = SolrSearchClick.where(log_id: batch.map(&:id)).order(:id).group_by(&:log_id)
        batch.each {|log| counts[:logs] += 1; out << x.log_row(log, clicks[log.id] || []) }
      end
    end
    click_rows = Enumerator.new do |out|
      SolrSearchClick.where(log_id: ids.select(:id)).find_in_batches(batch_size: 1000) do |batch|
        logs = SolrSearchLog.where(id: batch.map(&:log_id)).index_by(&:id)
        batch.each {|click| counts[:clicks] += 1; out << x.click_row(click, logs[click.log_id]) }
      end
    end
    x.write_csv(files['search_log'], x::LOG_COLUMNS, log_rows)
    x.write_csv(files['search_clicks'], x::CLICK_COLUMNS, click_rows)
    x.write_csv(files['collections'], x::COLLECTION_COLUMNS, SolrSearch::CollectionInfo.rows(SolrSearch::CollectionInfo.gather).each)
    now = Time.current
    readme = x.readme(exported_at: now, filters: log_filters_text, counts: counts)
    # the zip is written to a file, not built in memory, and sent from it in pieces; the body removes it at the end
    zip_file = Tempfile.new(['solr-search-log', '.zip'], binmode: true)
    x.zip_to(zip_file.path, 'search_log.csv' => files['search_log'], 'search_clicks.csv' => files['search_clicks'],
                            'collections.csv' => files['collections'], 'README.txt' => readme)
    body = x::TempfileBody.new(zip_file)
    zip_file = nil # the body owns it now
    response.headers['Content-Type'] = 'application/zip'
    response.headers['Content-Length'] = body.size.to_s
    response.headers['Content-Disposition'] =
      ActionDispatch::Http::ContentDisposition.format(disposition: 'attachment', filename: "solr-search-log-#{now.strftime('%Y%m%d-%H%M%S')}.zip")
    self.response_body = body
  ensure
    files&.each_value(&:close!)
    zip_file&.close!
  end

  # Deletes the log, by an administrator's own act (design D-45): what is older than a day, or all of it, with the clicks
  # that belong to it. It is not deleted by itself. The counts that Prometheus reads are separate, and stay.
  def delete_search_log
    if params[:all].present?
      # one transaction: a click that comes between the two deletes would be left without its search (M6 review 22)
      deleted = SolrSearchLog.transaction do
        SolrSearchClick.delete_all
        SolrSearchLog.delete_all
      end
      flash[:notice] = l(:notice_solr_search_log_deleted, count: deleted)
    elsif (day = (Date.iso8601(params[:before].to_s) rescue nil))
      older = SolrSearchLog.where('created_at < ?', day.in_time_zone.beginning_of_day)
      deleted = SolrSearchLog.transaction do
        SolrSearchClick.where(log_id: older.select(:id)).delete_all
        older.delete_all
      end
      flash[:notice] = l(:notice_solr_search_log_deleted, count: deleted)
    else
      flash[:error] = l(:error_solr_search_log_no_day)
    end
    redirect_to solr_search_admin_log_path
  end

  private

  # The conditions of the search log's list, from the request: [the searches of the period, the list's scope]. The list and the
  # export both use it (design D-45). No period given: SolrSearchLog::DEFAULT_DAYS; days=0: all of it.
  def log_filters
    @days = params.key?(:days) ? (LOG_PERIODS.include?(params[:days].to_i) ? params[:days].to_i : 0) : SolrSearchLog::DEFAULT_DAYS # 0: all of it
    @only_zero = params[:zero] == '1'
    @only_noclick = params[:noclick] == '1'
    @query_filter = params[:q].to_s.strip
    in_period = @days.positive? ? SolrSearchLog.where('created_at >= ?', @days.days.ago) : SolrSearchLog.all
    scope = in_period.order(id: :desc)
    scope = scope.where(hit_count: 0, error: nil) if @only_zero
    scope = scope.where(page: 1).where('hit_count > 0').where(clicked_at: nil) if @only_noclick
    if @query_filter.present?
      scope = scope.where('LOWER(query) LIKE ?', "%#{SolrSearchLog.sanitize_sql_like(@query_filter.downcase)}%")
    end
    [in_period, scope]
  end

  # The conditions in words, for the README of the export
  def log_filters_text
    [(@days.positive? ? l(:label_solr_search_log_period_days, days: @days) : l(:label_solr_search_log_period_all)),
     (l(:label_solr_search_log_only_zero) if @only_zero), (l(:label_solr_search_log_only_noclick) if @only_noclick),
     (%(#{l(:label_solr_search_log_query)}: "#{@query_filter}") if @query_filter.present?)].compact.join(' / ')
  end
end
