# frozen_string_literal: true

# The fine tuning tab and the dictionary tab of Administration > Full-text search (design D-51, D-52, D-53, D-56): the weights of the order of
# the results, the options of the tab, the optional external reranker, the query expansion dictionary, and the trial searches of both.
# Their views are in app/views/solr_search_admin (the tabs share partials), and the URLs are those of the admin page (config/routes.rb).
class SolrSearchTuningController < SolrSearchAdminBaseController
  # The fine tuning of the order of the results (design D-51, Q-34): the weights that the search sends with the words. For
  # administrators who want to tune the order; the defaults are what the search always sent. The trial search shows the
  # order now and with the values of the form, side by side, without saving anything.
  def tuning
    @draft = SolrSearchTuning.current
    @options = current_options
    load_tuning_page
  end

  # Saves (do=save) or only tries (do=preview) the values of the form. A value that may not be saved is said and kept in the form.
  def update_tuning
    @draft, bad = SolrSearch::Tuning.parse(params[:tuning] || {})
    @errors = SolrSearch::Tuning.validate(@draft).merge(bad.transform_values { :number })
    @options = options_from(params[:options])
    @errors['options.highlight_style'] = :long if @options['highlight_style'].length > MAX_STYLE
    @errors.merge!(reranker_errors(@options))
    @preview_query = params[:preview_query].to_s.strip
    if @errors.empty? && params[:do] == 'save'
      SolrSearchTuning.record(@draft)
      save_options(@options)
      flash[:notice] = l(:notice_solr_search_tuning_saved)
      return redirect_to solr_search_admin_tuning_path
    end
    @preview = run_preview(@preview_query, @draft) if @errors.empty? && params[:do] == 'preview' && @preview_query.present?
    @preview_error = l(:error_solr_search_tuning_preview_empty) if params[:do] == 'preview' && @preview_query.blank?
    load_tuning_page
    render :tuning
  rescue SolrSearch::Client::Error => e
    @preview_error = e.message
    load_tuning_page
    render :tuning
  end

  # Back to what the search always sent: saved as a row of its own (so that it is in the history too)
  def reset_tuning
    SolrSearchTuning.record(SolrSearch::Tuning.normalize(nil))
    flash[:notice] = l(:notice_solr_search_tuning_reset)
    redirect_to solr_search_admin_tuning_path
  end

  # The query expansion dictionary (design D-53, Q-27): groups of terms that mean the same, written as text. For administrators
  # who look after the old and new names, the short forms and the spellings of a department. The trial search shows what the
  # words of a search become, and the results with the dictionary now and with the text of the form.
  def synonyms
    @draft_text = SolrSearchSynonym.current_text
    load_synonyms_page
  end

  # Saves (do=save) or only tries (do=preview) the text of the form. Text with a line that cannot be used is not saved: the
  # lines are named and the text kept in the form.
  def update_synonyms
    @draft_text = params[:synonyms_text].to_s.gsub("\r\n", "\n")
    @parsed = SolrSearch::QueryDictionary.parse(@draft_text)
    @preview_query = params[:preview_query].to_s.strip
    if params[:do] == 'save' && @parsed.problems.empty?
      SolrSearchSynonym.record(@draft_text)
      flash[:notice] = l(:notice_solr_search_synonyms_saved)
      return redirect_to solr_search_admin_synonyms_path
    end
    load_synonyms_page
    @warnings = SolrSearch::QueryDictionary.warnings(@draft_text) if params[:do] == 'validate'
    @validated = params[:do] == 'validate'
    if params[:do] == 'preview'
      if @preview_query.blank?
        @preview_error = l(:error_solr_search_tuning_preview_empty)
      else
        draft = SolrSearch::QueryDictionary::Dictionary.new(@parsed.groups)
        @places = draft.expand(SolrSearch::Searcher.words(@preview_query))
        @preview = run_preview(@preview_query, SolrSearchTuning.current, [SolrSearchSynonym.dictionary, draft])
      end
    end
    render :synonyms
  rescue SolrSearch::Client::Error => e
    @preview_error = e.message
    load_synonyms_page
    render :synonyms
  end

  # The dictionary in force as a text file, to keep it, to carry it to another Redmine or to edit it by hand (and read back by
  # the form's file box). UTF-8, one group per line, as it was saved.
  def export_synonyms
    send_data SolrSearchSynonym.current_text, type: 'text/plain; charset=utf-8', disposition: 'attachment',
                                              filename: "solr-search-synonyms-#{Time.current.strftime('%Y%m%d')}.txt"
  end

  # Back to no dictionary: saved as a row of its own (so that it is in the history too)
  def reset_synonyms
    SolrSearchSynonym.record('')
    flash[:notice] = l(:notice_solr_search_synonyms_reset)
    redirect_to solr_search_admin_synonyms_path
  end

  private

  MAX_STYLE = 300

  # The three settings of the tab that are not weights (they were on the plugin's settings page): as in force
  def current_options
    {'show_solr_request' => SolrSearch::Settings['show_solr_request'] == '1',
     'expand_spelling_variants' => SolrSearch::Settings['expand_spelling_variants'] == '1',
     'highlight_style' => SolrSearch::Settings.highlight_style}.merge(RERANKER_KEYS.to_h {|k| [k, SolrSearch::Settings[k].to_s] })
  end

  # The settings of the optional external reranker (design D-56), kept as text
  RERANKER_KEYS = %w[reranker_url reranker_format reranker_model reranker_timeout reranker_docs reranker_chars].freeze

  # What is wrong with the reranker's values of the form: {'options.reranker_url' => :url, ...}
  def reranker_errors(options)
    r = SolrSearch::Reranker
    errors = {}
    errors['options.reranker_url'] = :url if options['reranker_url'].present? && !r.usable_url?(options['reranker_url'])
    errors['options.reranker_format'] = :format unless r::FORMATS.include?(options['reranker_format'])
    errors['options.reranker_model'] = :long if options['reranker_model'].length > 100
    {'reranker_timeout' => r::TIMEOUT, 'reranker_docs' => r::DOCS, 'reranker_chars' => r::CHARS}.each do |key, range|
      value = Integer(options[key], 10, exception: false)
      errors["options.#{key}"] = :range unless value && range.cover?(value)
    end
    errors
  end

  def options_from(raw)
    raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
    {'show_solr_request' => raw['show_solr_request'] == '1', 'expand_spelling_variants' => raw['expand_spelling_variants'] == '1',
     'highlight_style' => raw['highlight_style'].to_s.tr('{}<>', '').strip}
      # a value of the reranker that the form did not send is the one in force (the form always sends them; a request that is not the form does not)
      .merge(RERANKER_KEYS.to_h {|k| [k, (raw.key?(k) ? raw[k] : SolrSearch::Settings[k]).to_s.strip] })
  end

  # Into the plugin's settings, beside the rest of them (SolrSearch::Settings.update merges: the settings screen keeps sending them back, D-51)
  def save_options(options)
    SolrSearch::Settings.update({'show_solr_request' => options['show_solr_request'] ? '1' : '0',
                                 'expand_spelling_variants' => options['expand_spelling_variants'] ? '1' : '0',
                                 'highlight_style' => options['highlight_style']}.merge(RERANKER_KEYS.to_h {|k| [k, options[k]] }),
                                by: User.current.login)
  end

  def load_tuning_page
    @options ||= current_options
    @current = SolrSearchTuning.current
    @history = SolrSearchTuning.history
    # the sources the search knows, to set a multiplier for each (and those set before whose source is gone)
    registered = SolrSearchSource.order(:name).pluck(:collection, :name).to_h
    @source_names = registered.merge(@draft['sources'].keys.index_with {|collection| registered[collection] || collection })
    @source_names = @source_names.sort_by {|collection, name| [name, collection] }.to_h
  end

  def load_synonyms_page
    @options = current_options
    @current = SolrSearchTuning.current
    @history = SolrSearchSynonym.history
    # the words that did not help, of the last days, to write the dictionary by (the log tab holds the rest)
    @log_days = SolrSearchLog::DEFAULT_DAYS
    @top_zero, @top_noclick = SolrSearchLog.tops(SolrSearchLog.where('created_at >= ?', @log_days.days.ago).where(page: 1))
  end

  # The order now and with the draft: [[tuning, rows], ...]; a row is {group_id, rank, kind, title, score, was (the rank in
  # the first list)}. As the administrator who is trying it (who sees everything; the words are searched as the screen does).
  # dictionaries: the one of each list (the dictionary in force for both unless the dictionary is what is tried)
  def run_preview(text, draft, dictionaries = [SolrSearchSynonym.dictionary] * 2)
    sources = SolrSearch::SourceAccess.collections(User.current)
    client = SolrSearch::Client.from_env(SolrSearch.collection)
    expand = [current_options['expand_spelling_variants'], @options['expand_spelling_variants']]
    lists = [SolrSearchTuning.current, draft].each_with_index.map do |tuning, i| # not @current: the trial of the form is made before the page is loaded
      result = SolrSearch::Searcher.new(user: User.current, client: client, tuning: tuning, expand_vu: expand[i],
                                           dictionary: dictionaries[i])
                                   .search(text, per_page: PREVIEW_ROWS, sources: sources, scores: true, detail: false)
      result ? result.groups : []
    end
    titles = preview_titles(lists.flatten)
    ranks = lists.first.each_with_index.to_h {|group, i| [group.group_id, i + 1] }
    lists.each_with_index.map do |groups, list_index|
      groups.each_with_index.map do |group, i|
        hit = group.hits.first
        {group_id: group.group_id, rank: i + 1, kind: preview_kind(group.group_id), title: titles[group.group_id] || hit.title || group.group_id,
         score: hit.score, was: (ranks[group.group_id] if list_index == 1)}
      end
    end
  end

  PREVIEW_ROWS = 20

  def preview_kind(group_id)
    {'issue' => l(:label_issue), 'wiki_page' => l(:label_wiki), 'document' => l(:label_document), 'project' => l(:label_project),
     'version' => l(:label_version)}[SolrSearch::GroupId.kind(group_id)] || l(:label_solr_search_type_external)
  end

  # The names of what the groups are (an external document has its own title)
  def preview_titles(groups)
    ids = groups.map(&:group_id).uniq
    numbers = SolrSearch::GroupId.numbers_by_kind(ids)
    names = {}
    Issue.where(id: numbers['issue'] || []).pluck(:id, :subject).each {|id, t| names[SolrSearch::GroupId.build('issue', id)] = "##{id} #{t}" }
    WikiPage.where(id: numbers['wiki_page'] || []).pluck(:id, :title).each {|id, t| names[SolrSearch::GroupId.build('wiki_page', id)] = t }
    Document.where(id: numbers['document'] || []).pluck(:id, :title).each {|id, t| names[SolrSearch::GroupId.build('document', id)] = t }
    # the files of a project and of a version (the attachments of the Files module)
    Project.where(id: numbers['project'] || []).pluck(:id, :name).each {|id, t| names[SolrSearch::GroupId.build('project', id)] = t }
    Version.where(id: numbers['version'] || []).pluck(:id, :name).each {|id, t| names[SolrSearch::GroupId.build('version', id)] = t }
    names
  end
end
