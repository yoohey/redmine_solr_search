# frozen_string_literal: true

# The full-text search screen (design D-24). A page of its own, apart from Redmine's search (D-15).
class SolrSearchController < ApplicationController
  menu_item :solr_search
  helper :solr_search
  helper :queries # the filters of an issue query are drawn by Redmine's partial, which uses its helpers (D-49)
  before_action :find_project_for_search
  before_action :authorize_global_search

  # A click on a result of the list, sent by the screen's script when a link of the list is followed (design D-45).
  # Taken only for a search that this user made, in the last day, and only with the mark that the page of that search was given
  # (Clicks.accepted?). It always answers "no content": a click that is not taken is not told, there is nothing to learn from it.
  def click
    log = SolrSearchLog.find_by(id: params[:log_id].to_s.to_i)
    mine = User.current.logged? ? User.current.id : nil
    if SolrSearch::Clicks.accepted?(log, mine: mine, token: params[:token]) && params[:group].present?
      SolrSearch::Clicks.record(log, group: params[:group], rank: params[:rank], kind: params[:kind],
                                     title: params[:title], href: params[:href])
    end
    head :no_content
  end

  def index
    # not @question: Redmine's layout puts @question into the quick search box at the top right
    # [[:space:]] also removes the ideographic space (U+3000), which String#strip leaves
    @solr_question = params[:q].to_s.gsub(/\A[[:space:]]+|[[:space:]]+\z/, '')
    @all_words = params[:all_words] == '1'
    @sort = SolrSearch::Searcher::SORTS.include?(params[:sort]) ? params[:sort] : 'relevance'
    # one or more projects (Redmine's +/- toggle switches the select to multiple); blank means all.
    # When opened from a project menu, the project is fixed (design D-34).
    if @project
      @projects = [@project]
    else
      @projects = Project.visible.where(id: Array(params[:project_ids]).compact_blank).to_a
    end
    # the external sources this user may search in the chosen projects (design D-32, D-33); none: no external type
    @sources = SolrSearch::SourceAccess.collections(User.current, project_ids: selected_project_ids)
    # all of them, whatever projects are chosen: the facet counts the other projects' sources too (D-49)
    @all_sources = selected_project_ids ? SolrSearch::SourceAccess.collections(User.current) : @sources
    @type_choices = SolrSearch::Searcher::TYPE_FILTERS.keys
    @type_choices -= ['external'] if @sources.empty?
    @types = Array(params[:types]) & @type_choices
    @types = @type_choices if @types.empty? # nothing ticked: every type
    # only these sources ('redmine' is Redmine's own data), from the facet links (D-49); nothing: all
    @source_filter = Array(params[:source]).map(&:to_s) & [SolrSearch.collection, *@sources]
    # more choices, from the bar left of the result (D-49): the update range and the ids of trackers, authors, assignees
    @filters = {updated: (params[:updated].to_s if SolrSearch::Searcher::UPDATED_RANGES.key?(params[:updated].to_s))}
    SolrSearch::Searcher::ID_FILTERS.each_key do |key|
      @filters[key] = Array(params[key]).filter_map {|v| Integer(v.to_s, exception: false)}.select(&:positive?).uniq
    end
    @filters[:file_exts] = Array(params[:file_exts]).map {|v| v.to_s.downcase}.grep(SolrSearch::Searcher::STRING_VALUE).uniq
    @filters[:folder] = params[:folder].to_s if SolrSearch::Searcher.folder_depth(params[:folder].to_s)
    # the issue custom fields used as a filter, that the user may see; what is chosen of them: a list's values (cfv[id][]) and a
    # number's or date's range (cfr[id][min|max|from|to])
    @custom_facets = SolrSearch::CustomFieldQuery.facets_for(User.current)
    @custom_filters = @custom_facets.to_h {|custom| [custom.id, custom_choice(custom)] }.compact_blank
    build_attribute_filters
    @exact = params[:exact] == '1'
    @attributes = params[:attributes] == '1' # R10: the issue custom fields too (D-31); off by default
    if @solr_question.empty?
      # the form refuses an empty or blank word; this is for a request that comes some other way (a hand-made URL)
      @error = l(:error_solr_search_no_words) if params.key?(:q)
      return
    end
    # D-24: past the most words, Solr is not asked
    max_words = SolrSearch::Settings.max_words
    if SolrSearch::Searcher.words(@solr_question).size > max_words
      @error = l(:error_solr_search_too_many_words, max: max_words)
      return
    end

    per_page = SolrSearch::Settings.per_page
    # to_s: a page given as an array or a hash is not an error; at most max_page (M1 review A1)
    page = params[:page].to_s.to_i.clamp(1, SolrSearch::Searcher.max_page(per_page))
    # from here Solr is asked: the search is written in the log (design D-45), whether it goes well or not
    @search_page = page
    @search_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # how long a user waits for Solr is a plugin setting: a huge index may be worth a minute
    client = SolrSearch::Client.from_env(SolrSearch.collection,
                                         read_timeout: SolrSearch::Settings.seconds('search_timeout'))
    # admins also see the request sent to Solr when the setting is on, for checking the query while it is tuned
    @result = SolrSearch::Searcher.new(user: User.current, client: client,
                                       debug: User.current.admin? && SolrSearch::Settings['show_solr_request'] == '1',
                                       expand_vu: SolrSearch::Settings['expand_spelling_variants'] == '1',
                                       tuning: SolrSearchTuning.current, dictionary: SolrSearchSynonym.dictionary,
                                       reranker: SolrSearch::Reranker.from_settings(SolrSearch::Settings))
                                  .search(@solr_question, page: page, per_page: per_page, all_words: @all_words, sort: @sort, types: @types,
                                          project_ids: selected_project_ids, exact: @exact,
                                          # the Searcher asks them only when their type is wanted (design D-33)
                                          sources: @sources, source_filter: @source_filter, filters: @filters, facets: true,
                                          facet_sources: @all_sources, custom_facets: @custom_facets, custom_filters: @custom_filters, attribute_filters: @attribute_filters,
                                          custom_fields: @attributes ? SolrSearch::CustomFieldQuery.for(User.current) : nil)
    return unless @result

    note_missing_sources(@result.missing_sources)
    load_facet_names(@result.facets)
    load_custom_labels(@result.facets) if @result.facets
    # An external document has no record in Redmine: its group is not looked up there (see ExternalHits for which hits
    # count as external; design D-33; the filter already lets nothing else through, this is a second guard)
    @external_group_ids = SolrSearch::ExternalHits.sort_out(@result.groups, @sources)
    @source_records = @external_group_ids.any? ? SolrSearchSource.where(collection: @sources).index_by(&:collection) : {}
    @containers = load_containers(@result.groups.map(&:group_id).reject {|gid| @external_group_ids.include?(gid)})
    drop_hidden_journals(@result.groups)
    @attachments = drop_hidden_attachments(@result.groups, @containers)
    # not visible after all, or deleted since it was indexed; or every hit was a note the user may not see. Decided
    # here, so that a page with nothing left says so (Gemini review 2026-10-05, item 9)
    @groups = @result.groups.select do |group|
      group.hits.any? && (@external_group_ids.include?(group.group_id) || @containers[group.group_id])
    end
    record_search(result: @result, shown: @groups.size)
    @notes = notes_as_in_history(@groups)
    @custom_fields = drop_hidden_custom_field_snippets(@groups)
    # the pages offered stop at max_page, even when Solr counts more
    @paginator = Redmine::Pagination::Paginator.new(
      [@result.group_count, SolrSearch::Searcher.max_page(per_page) * per_page].min, per_page, page
    )
  rescue SolrSearch::Client::Error => e
    logger.error "solr_search: #{e.message}"
    record_search(error: e.message) if @search_started
    @error = l(:error_solr_search_failed)
  end

  private

  # One row in the search log (design D-45): who searched what, the counts, the groups that Redmine's own checks did not
  # show, how long it took, why it failed. Never fails the search (SearchLog.record).
  def record_search(result: nil, shown: nil, error: nil)
    took_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @search_started) * 1000).round
    @search_log = SolrSearch::SearchLog.record(user: User.current, query: @solr_question, request_path: request.fullpath,
                                 project_id: @project&.id, page: @search_page, took_ms: took_ms, result: result,
                                 shown: shown, shown_of: result&.groups&.size, error: error,
                                 collection: SolrSearch.collection, sources: (@types.include?('external') ? @sources : []))
  end

  # Collections of sources that Solr did not have (design D-33): the search went on without them. Said in Redmine's
  # log and kept on the source, for the admin page to show. The mark changes nothing in what is searched; no history
  # row (update_all): nobody changed the source.
  # Written at most once in MISSING_MARK_INTERVAL for a source, with the log line: a search is a GET, and while the
  # collection is missing every search finds it so (a write and a line in the log each time would be too much).
  MISSING_MARK_INTERVAL = 5.minutes

  def note_missing_sources(names)
    return if names.blank?

    @sources -= names
    marked = SolrSearchSource.where(collection: names)
                             .where('missing_collection_at IS NULL OR missing_collection_at < ?', MISSING_MARK_INTERVAL.ago)
    names = marked.pluck(:collection)
    return if names.empty?

    SolrSearch.log(:warn, "no collection in Solr for the source(s) #{names.join(', ')}: searched without them")
    marked.update_all(missing_collection_at: Time.current)
  end

  # The names for the facets (D-49): the sources by collection, the projects the user may see (a count of a project that
  # Redmine does not let the user see is dropped, though the filter query lets nothing else through)
  def load_facet_names(facets)
    return unless facets

    # the chosen ones too: one without a hit is not counted, and its chip still has to name it (O-57). Only sources
    # this user may search get into @source_filter.
    @facet_sources = SolrSearchSource.where(collection: facets[:sources].keys | @source_filter).index_by(&:collection)
    @project_sources = SolrSearch::SourceAccess.by_project(User.current)
    project_ids = facets[:projects].map(&:first) | @project_sources.keys
    @facet_projects = Project.visible.where(id: project_ids).index_by(&:id)
    chosen_or_counted = ->(kind) { facets[kind].map(&:first) | @filters[SolrSearch::Searcher::FACET_FILTERS.fetch(kind)] }
    @facet_names = {
      trackers: Tracker.where(id: chosen_or_counted.(:trackers)),
      statuses: IssueStatus.where(id: chosen_or_counted.(:statuses)),
      priorities: IssuePriority.where(id: chosen_or_counted.(:priorities)),
      # a version and a category belong to a project: only those of the projects the user may see
      versions: Version.visible.where(id: chosen_or_counted.(:versions)).includes(:project),
      categories: IssueCategory.where(id: chosen_or_counted.(:categories), project_id: Project.visible.select(:id)).includes(:project)
    }.transform_values {|scope| scope.index_by(&:id) }
    # people as Redmine shows them to this user (the users that the user may not see are not named, nor counted)
    people = facets[:authors].map(&:first) | facets[:assignees].map(&:first) | @filters[:author_ids] | @filters[:assigned_to_ids]
    @facet_people = Principal.visible.where(id: people).index_by(&:id)
  end

  # The "Filters" of the screen (D-49): Redmine's issue query, narrowed to what the index can do, read from f[], op[] and v[] and
  # written for Solr. It starts with no filter (an issue query starts with the open issues). @query is what Redmine's
  # partial for the filters draws. With a filter, only issues (and what belongs to them) are searched.
  def build_attribute_filters
    @query = SolrSearchIssueQuery.new(name: '_')
    @query.project = @project
    @query.filters = {}
    @query.build_from_params(params.slice(:f, :op, :v))
    context = SolrSearch::FilterTranslator::Context.new(
      today: User.current.today, zone: User.current.time_zone || Time.zone, first_day_of_week: l(:general_first_day_of_week).to_i,
      open_status_ids: IssueStatus.where(is_closed: false).ids, closed_status_ids: IssueStatus.where(is_closed: true).ids,
      my_ids: {'author_id' => [User.current.id], 'assigned_to_id' => [User.current.id, *User.current.group_ids]},
      custom: @custom_facets
    )
    @attribute_filters = SolrSearch::FilterTranslator.call(@query.filters, context).expressions
  end

  # What the request chose of a custom field (D-49), as the Searcher takes it; nil when nothing. Whatever the parameters look
  # like, a string or a hash or an array: only strings are kept.
  def custom_choice(custom)
    if custom.kind == :values
      raw = params[:cfv].respond_to?(:key?) ? params[:cfv][custom.id.to_s] : nil
      values = Array(raw).select {|v| v.is_a?(String) }
      {values: values} if values.any?
    else
      raw = params[:cfr].respond_to?(:key?) && params[:cfr][custom.id.to_s].respond_to?(:key?) ? params[:cfr][custom.id.to_s] : nil
      keys = custom.kind == :number ? %w[min max] : %w[from to]
      range = keys.to_h {|key| [key.to_sym, raw && raw[key].is_a?(String) ? raw[key] : nil] }.compact_blank
      range if range.any?
    end
  end

  # The names of the values of the custom fields that are lists of ids or of coded values (D-49): what Redmine shows for them to
  # this user. {custom field id => {value => name}}; a value without a name (a user the user may not see) is not shown, nor counted.
  def load_custom_labels(facets)
    @custom_labels = @custom_facets.select {|custom| custom.kind == :values }.to_h do |custom|
      values = (facets.dig(:custom, custom.id, :values) || []).map(&:first) | (@custom_filters.dig(custom.id, :values) || [])
      [custom.id, custom_value_names(custom, values)]
    end
  end

  def custom_value_names(custom, values)
    case custom.field_format
    when 'bool' then {'1' => l(:general_text_Yes), '0' => l(:general_text_No)}
    when 'enumeration'
      CustomFieldEnumeration.where(custom_field_id: custom.id, id: values.grep(/\A\d+\z/)).to_h {|e| [e.id.to_s, e.name] }
    when 'user' then Principal.visible.where(id: values.grep(/\A\d+\z/)).to_h {|u| [u.id.to_s, u.name] }
    when 'version' then Version.visible.where(id: values.grep(/\A\d+\z/)).includes(:project).to_h {|v| [v.id.to_s, "#{v.name} (#{v.project.name})"] }
    else values.to_h {|v| [v, v] }
    end
  end

  # The chosen projects and their subprojects the user may see; nil when none is chosen (every visible project)
  def selected_project_ids
    return nil if @projects.empty?

    @selected_project_ids ||= @projects.flat_map {|p| p.self_and_descendants.visible.pluck(:id)}.uniq
  end

  # "issue-12" => the Issue, and so on, for what the list shows (display values come from Redmine, D-25). Checks the
  # user may see each one again, so that a mistake in the permission filter never shows a record. The check is
  # Redmine's alone (design D-30): visible? answers as the issue page does (private issues, the role's issues
  # visibility, trackers, the admin). The permission filter keeps Solr's counts and pages close to it (PermissionFilter).
  def load_containers(group_ids)
    ids = SolrSearch::GroupId.numbers_by_kind(group_ids)
    user = User.current
    found = {}
    # the projects' modules preloaded: visible? reads them (Project#allowed_permissions), one query per project
    # otherwise (docs/experiments/screen-perf, round 2)
    Issue.where(id: ids['issue'] || []).includes(:tracker, :status, project: :enabled_modules).each do |i|
      found[SolrSearch::GroupId.build('issue', i.id)] = i if i.visible?(user)
    end
    # with_updated_on: the time the list shows, without loading the text
    WikiPage.with_updated_on.where(id: ids['wiki_page'] || []).includes(wiki: {project: :enabled_modules}).each do |p|
      found[SolrSearch::GroupId.build('wiki_page', p.id)] = p if p.visible?(user)
    end
    Document.where(id: ids['document'] || []).includes(project: :enabled_modules).each do |d|
      found[SolrSearch::GroupId.build('document', d.id)] = d if d.visible?(user)
    end
    # the Files module (design D-36): a project's or a version's attachments, which have no record of their own in the
    # index; seen where Redmine shows them (attachments_visible?: view_files)
    Project.where(id: ids['project'] || []).includes(:enabled_modules).each do |p|
      found[SolrSearch::GroupId.build('project', p.id)] = p if p.attachments_visible?(user)
    end
    Version.where(id: ids['version'] || []).includes(project: :enabled_modules).each do |v|
      found[SolrSearch::GroupId.build('version', v.id)] = v if v.attachments_visible?(user)
    end
    found
  end

  # Checks each note hit on its own, not only its issue: a note made private (or emptied, or deleted) stays in the
  # index until the next crawl, and its visible issue would show its snippet (design D-30). A note is kept while Redmine
  # lets the user see it and it still has text (an emptied note's old text stays in the index until the next crawl).
  def drop_hidden_journals(groups)
    ids = groups.flat_map(&:hits).select {|hit| hit.type == 'journal'}.map(&:item_id)
    return if ids.empty?

    # Journal.visible, not Journal#visible?: the scope also checks private notes (view_private_notes, or one's own);
    # the method checks the issue only. It joins the issue, so a note of an issue the user may not see is dropped too.
    shown = Journal.visible(User.current).where(id: ids).where.not(notes: [nil, '']).pluck(:id).to_set
    groups.each {|group| group.hits = group.hits.reject {|hit| hit.type == 'journal' && !shown.include?(hit.item_id)}}
  end

  # Checks each attachment hit on its own, as Redmine does (Attachment#visible?: the container's attachments_visible?; design
  # D-36): the group's container may be seen while the attachment may not be (the permission filter keeps the counts close,
  # this is what decides). An attachment deleted since it was indexed is dropped too. Returns {attachment id => Attachment}
  # of those kept, for their names and links.
  # containers: what load_containers read, with their projects and modules: an attachment's container is the container
  # of its group, so it is given to the attachment rather than read again, one query per attachment (M4 review, #20).
  # An attachment whose container is not among them (its group is not shown anyway) reads its own.
  def drop_hidden_attachments(groups, containers)
    ids = groups.flat_map(&:hits).select {|hit| hit.type == 'attachment'}.map(&:item_id)
    return {} if ids.empty?

    user = User.current
    attachments = Attachment.where(id: ids).to_a
    attachments.each do |attachment|
      kind = SolrSearch::RedmineDocuments::ATTACHMENT_CONTAINERS[attachment.container_type]
      container = containers["#{kind}-#{attachment.container_id}"] if kind
      attachment.association(:container).target = container if container
    end
    shown = attachments.select {|attachment| attachment.visible?(user)}.index_by(&:id)
    groups.each {|group| group.hits = group.hits.reject {|hit| hit.type == 'attachment' && !shown.key?(hit.item_id)}}
    shown
  end

  # Solr returns a custom field's snippet for every issue that matched, also where the field is hidden (hl.fl is one
  # for the whole query; docs/experiments/cf-d31 round 1). Each one is kept only where Redmine shows the field on that
  # issue's page (IssueCustomField#visible_by?, design D-31). Returns {field id => IssueCustomField} of those shown,
  # in the order of the fields, for their names.
  def drop_hidden_custom_field_snippets(groups)
    hits = groups.flat_map(&:hits).select {|hit| hit.custom_field_snippets.present?}
    return {} if hits.empty?

    fields = IssueCustomField.where(id: hits.flat_map {|hit| hit.custom_field_snippets.keys}.uniq).preload(:roles).sorted.index_by(&:id)
    user = User.current
    hits.each do |hit|
      project = @containers["issue-#{hit.item_id}"]&.project if hit.type == 'issue'
      hit.custom_field_snippets = hit.custom_field_snippets.select do |id, _|
        project && fields[id]&.visible_by?(project, user)
      end
    end
    shown = hits.flat_map {|hit| hit.custom_field_snippets.keys}.to_set
    fields.select {|id, _| shown.include?(id)} # still in Redmine's order of the fields (sorted)
  end

  # The note hits as the issue's history shows them (M1 review C1): {journal id => Journal with its indice (the "#3" of
  # the history), author and time}. Issue#visible_journals_with_index numbers every journal of the issue by
  # created_on, id, whoever looks, so the number is the same here.
  def notes_as_in_history(groups)
    ids = groups.flat_map(&:hits).select {|hit| hit.type == 'journal'}.map(&:item_id)
    return {} if ids.empty?

    notes = Journal.where(id: ids).includes(:user).index_by(&:id)
    Journal.where(journalized_type: 'Issue', journalized_id: notes.values.map(&:journalized_id).uniq)
           .reorder(:created_on, :id).pluck(:id, :journalized_id)
           .group_by(&:last).each_value do |rows|
      rows.each_with_index {|(id, _), i| notes[id]&.indice = i + 1}
    end
    notes
  end

  # When opened from a project menu (design D-34), requires the permission :use_solr_search on the project.
  def find_project_for_search
    return unless params[:project_id].present?

    # to_s: a list or a hash in the URL is not an id (it finds nothing: 404), not a failure
    @project = Project.find(params[:project_id].to_s)
    if @project.archived?
      render_403(message: :notice_not_authorized_archived_project)
      return false
    end
    unless User.current.allowed_to?(:use_solr_search, @project)
      deny_access
      return false
    end
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # When opened outside any project, access may be restricted by the plugin setting global_search_access.
  def authorize_global_search
    return if params[:project_id].present?
    return if SolrSearch.global_search_allowed?(User.current)

    deny_access
  end
end
