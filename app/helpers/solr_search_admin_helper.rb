# frozen_string_literal: true

module SolrSearchAdminHelper
  # {source id => Check} from Solr's side, or {} when Solr does not answer (the page then shows no marks and still
  # opens: it waits for Solr at most the admin timeout, and for a connection SolrSearch::Status::CONNECT_TIMEOUT).
  # For a project's settings tab, which Redmine draws with every other tab: one request to Solr, not one for each
  # source (the documents with a wrong source value are counted on the admin page only)
  def solr_search_source_checks(sources)
    SolrSearch::SourceStatus.new(client: SolrSearch::Status.admin_client).check(sources, count_wrong_source: false)
  rescue SolrSearch::Client::Error
    {}
  end

  # A document type in the words of the search screen (M1 review C4)
  def solr_search_doc_type_label(type)
    {'issue' => l(:label_issue), 'journal' => l(:label_solr_search_note), 'wiki_page' => l(:label_wiki_page),
     'document' => l(:label_document), 'attachment' => l(:label_solr_search_doc_attachment)}.fetch(type, type)
  end

  # What a partial reindex is limited to, in words: "トラッカー：バグ、機能" / "カスタムフィールド：顧客名、(削除済み) フィールド ID 12"
  def solr_search_scope_label(scope)
    ids = SolrSearch::ReindexScope.ids_of(scope)
    if SolrSearch::ReindexScope.kind(scope) == 'trackers'
      names = Tracker.where(id: ids).index_by(&:id)
      "#{l(:label_tracker)}：#{ids.map {|id| names[id]&.name || "##{id}" }.join('、')}"
    else
      names = IssueCustomField.where(id: ids).index_by(&:id)
      "#{l(:label_custom_field_plural)}：#{ids.map {|id| names[id]&.name || l(:label_solr_search_partial_deleted_field, id: id) }.join('、')}"
    end
  end

  # The question before a source is deleted: how many projects stop searching it, and which
  def solr_search_source_delete_confirm(source)
    projects = source.projects.sort_by(&:name)
    return l(:text_solr_search_source_delete_confirm, name: source.name) if projects.empty?

    l(:text_solr_search_source_delete_confirm_linked, name: source.name, count: projects.size,
                                                        projects: projects.first(10).map(&:name).join('、') +
                                                                  (projects.size > 10 ? '…' : ''))
  end

  # A block of code as an editor shows it (UI review; the colours follow View Customize's editor): monospaced, with a button that
  # copies it. With script: true the JavaScript is coloured (comments, strings, keywords, names after a dot and function names);
  # without it the text is shown as it is. Everything is escaped.
  JS_TOKENS = %r{
    (?<comment>(?<![:\w])//[^\n]*)|
    (?<string>'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")|
    (?<keyword>\b(?:function|var|let|const|if|else|return|while|for|new|typeof|this)\b)|
    (?<method>(?<=\.)[A-Za-z_$][\w$]*)|
    (?<function>(?<=function[ ])[A-Za-z_$][\w$]*)|
    (?<number>\b\d+\b)
  }x

  def solr_search_code_block(source, script: false)
    html = script ? solr_search_highlight_js(source) : h(source)
    content_tag(:div, class: 'solr-search-code-box') do
      button_tag(l(:button_solr_search_code_copy), type: 'button', class: 'solr-search-code-copy') +
        content_tag(:pre, content_tag(:code, html), class: 'solr-search-code')
    end
  end

  def solr_search_highlight_js(source)
    parts = []
    pos = 0
    source.scan(JS_TOKENS) do
      m = Regexp.last_match
      kind = %w[comment string keyword method function number].find {|k| m[k] }
      parts << h(source[pos...m.begin(0)]) << content_tag(:span, m[0], class: "solr-search-code-#{kind}")
      pos = m.end(0)
    end
    safe_join(parts << h(source[pos..]))
  end

  # A warning icon with its text, for what the admin page asks to look at
  def solr_search_admin_warning(text)
    content_tag('span', solr_search_icon('warning', text), class: 'icon icon-warning')
  end

  # A note under a table: its first line always shown, the rest folded (M1 review, ui 26). The locale has
  # KEY_summary (the line) and KEY (the rest).
  def solr_search_admin_note(key)
    safe_join([
      content_tag('p', l(:"#{key}_summary"), class: 'info'),
      content_tag('details', class: 'solr-search-admin-more') do
        content_tag('summary', l(:label_solr_search_admin_more)) + content_tag('p', l(key), class: 'info')
      end
    ])
  end

  # An error of Solr as one short plain line: a web server's HTML page of an error (a wrong path) is stripped of its tags
  # and cut, so that it does not stretch the box
  def solr_search_short_error(message)
    truncate(strip_tags(message.to_s).squish, length: 240)
  end

  # A hint for what a failure of the connection usually is, or nil: the answer is a 404 (the path of the address is wrong)
  def solr_search_connection_hint(message)
    l(:text_solr_search_state_unreachable_404) if message.to_s.include?('(404)')
  end

  def solr_search_run_task_label(task)
    l(:"label_solr_search_run_task_#{task}")
  end

  def solr_search_run_status(run)
    text = l(:"label_solr_search_run_status_#{run.status}")
    case run.status
    when 'succeeded' then content_tag('span', solr_search_icon('checked', text), class: 'icon icon-ok')
    when 'failed' then content_tag('span', solr_search_icon('alert-circle', text), class: 'icon icon-error')
    else text
    end
  end

  # "チケット 3,120 · 注記 12,469 (-2)": documents sent, and removed in brackets
  def solr_search_run_counts(run)
    return '' if run.counts.blank?

    run.counts.map do |type, c|
      text = "#{solr_search_doc_type_label(type)} #{number_with_delimiter(c['sent'].to_i)}"
      text += " (-#{number_with_delimiter(c['deleted'])})" if c['deleted'].to_i.positive?
      text
    end.join(' · ')
  end

  # When the scheduler runs the task next (design D-22): a time, "at the next check" when it is due, or why it does not
  def solr_search_run_next(task, next_runs)
    return l(:label_solr_search_run_next_manual) unless next_runs.key?(task) # the full reindex: started by hand
    return l(:label_solr_search_run_next_disabled) unless (time = next_runs[task])

    time <= Time.current ? l(:label_solr_search_run_next_due) : format_time(time)
  end

  # "5.8秒", "12分3秒", "1時間2分" (M1 review, ui 22)
  def solr_search_run_duration(run)
    return '' unless (seconds = run.duration)
    # 59.96 s is "1分0秒", not "60.0秒"
    return l(:label_solr_search_duration_seconds, s: seconds.round(1)) if seconds.round(1) < 60

    minutes, s = seconds.round.divmod(60)
    return l(:label_solr_search_duration_minutes, m: minutes, s: s) if minutes < 60

    l(:label_solr_search_duration_hours, h: minutes / 60, m: minutes % 60)
  end

  # Which projects may link the source (design D-34)
  def solr_search_source_linkable(source)
    return l(:label_solr_search_source_all_projects) if source.all_projects?

    projects = source.allowed_projects.map(&:project).compact.sort_by(&:name)
    return content_tag('span', l(:label_solr_search_source_linkable_none), class: 'info') if projects.empty?

    safe_join(projects.map {|p| link_to_project(p) }, ', ')
  end

  # What the admin page finds about the source's collection (design D-33): marks only, searches do not use them
  def solr_search_source_check(check, source)
    marks = []
    case check&.state
    when :ok then marks << content_tag('span', solr_search_icon('checked', l(:label_solr_search_source_state_ok)), class: 'icon icon-ok')
    when :missing
      marks << content_tag('span', solr_search_icon('alert-circle', l(:label_solr_search_source_state_missing)),
                           class: 'icon icon-error')
    when :wrong_configset
      marks << content_tag('span', solr_search_icon('alert-circle', l(:label_solr_search_source_state_wrong_configset,
                                                                       configset: check.configset)), class: 'icon icon-error')
    when :unknown
      marks << solr_search_admin_warning(l(:label_solr_search_source_state_unknown))
    end
    if check&.wrong_source.to_i.positive?
      marks << solr_search_admin_warning(l(:label_solr_search_source_wrong_source, count: check.wrong_source))
    end
    if source.missing_collection_at
      marks << content_tag('em', l(:label_solr_search_source_missing_at, time: format_time(source.missing_collection_at)),
                           class: 'info')
    end
    safe_join(marks, tag.br)
  end

  # The values a history row keeps: before and after for a change, the reason a link went
  def solr_search_change_details(change)
    details = change.details
    return '' if details.blank?
    return l(:"label_solr_search_change_reason_#{details['reason']}") if details['reason']

    safe_join(details.map do |field, value|
      label = l(:"label_solr_search_change_field_#{field}")
      # the link pattern is shown whole: a change in its tail (the host) is the kind to look for
      limit = field == 'link_pattern' ? nil : 100
      text = value.is_a?(Array) ? value.map {|v| solr_search_change_value(v, limit) }.join(' → ') : solr_search_change_value(value, limit)
      "#{label}: #{text}"
    end, tag.br)
  end

  def solr_search_change_value(value, limit = 100)
    case value
    when true then l(:general_text_Yes)
    when false then l(:general_text_No)
    when nil, '' then '-'
    else limit ? value.to_s.truncate(limit) : value.to_s
    end
  end

  # What is wrong with a value of the fine tuning tab (reason from SolrSearch::Tuning.validate)
  def tuning_error_text(reason, range)
    case reason
    when :number then l(:error_solr_search_tuning_number)
    when :none_positive then l(:error_solr_search_tuning_none_positive)
    else l(:error_solr_search_tuning_range, min: range.min, max: range.max)
    end
  end

  # What is wrong with a line of the dictionary's text (a SolrSearch::QueryDictionary::Problem)
  def synonym_problem_text(problem)
    d = SolrSearch::QueryDictionary
    max = {too_many_terms: d::MAX_GROUP_TERMS, term_too_many_words: d::MAX_TERM_WORDS, term_too_long: d::MAX_TERM_LENGTH,
           too_many_lines: d::MAX_LINES, too_big: d::MAX_BYTES / 1024}[problem.reason]
    text = l("error_solr_search_synonyms_#{problem.reason}", max: max)
    problem.line.zero? ? text : l(:label_solr_search_synonyms_line, line: problem.line) + text
  end

  # What is wrong with a value of the reranker's fields (the reason from SolrSearchTuningController#reranker_errors)
  def reranker_error_text(reason)
    case reason
    when :url then l(:error_solr_search_reranker_url)
    when :format then l(:error_solr_search_reranker_format)
    when :long then l(:error_solr_search_tuning_long, max: 100)
    else l(:error_solr_search_reranker_range)
    end
  end

  # What only looks wrong in a line of the dictionary's text (a SolrSearch::QueryDictionary::Problem from warnings)
  def synonym_warning_text(warning)
    l(:label_solr_search_synonyms_line, line: warning.line) + l("warning_solr_search_synonyms_#{warning.reason}", detail: warning.detail)
  end

  # A place of the query with its alternatives: "SSO → SSO / シングルサインオン"
  def synonym_place_text(alternatives)
    "#{alternatives.first} → #{alternatives.join(' / ')}"
  end

  # How far a result moved from the order now (the rank it had; nil: it was not in the first)
  def tuning_move_text(rank, was)
    return l(:label_solr_search_tuning_new) unless was
    return '–' if was == rank

    was > rank ? "↑ #{was - rank}" : "↓ #{rank - was}"
  end

  # "qf.title_ja" as the tab names it
  def tuning_path_label(path)
    kind, name = path.split('.', 2)
    case kind
    when 'qf' then l("label_solr_search_tuning_field_#{name}")
    when 'pf2' then l(:label_solr_search_tuning_phrase)
    when 'types' then l("label_solr_search_tuning_type_#{name}")
    when 'sources' then "#{l(:label_solr_search_tuning_sources)} #{name}"
    else name == 'strength' ? l(:label_solr_search_tuning_recency_strength) : l(:label_solr_search_tuning_recency_half_life)
    end
  end
end
