# frozen_string_literal: true

module SolrSearchHelper
  # A snippet from Solr as HTML: escaped first, then the markers become highlight tags. The stored text is never
  # output as it is (design chapter 7: the Unified Highlighter does not escape by default).
  def solr_search_snippet(text)
    return '' if text.blank?

    h(SolrSearch::Snippet.from_first_mark(text.gsub(/\s+/, ' ')))
      .gsub(SolrSearch::Searcher::HL_PRE, '<span class="highlight token-0">')
      .gsub(SolrSearch::Searcher::HL_POST, '</span>')
      .html_safe
  end

  def solr_search_highlighted?(text)
    text.to_s.include?(SolrSearch::Searcher::HL_PRE)
  end

  # What to show under a container for one hit: [label, snippet, field]. A field without a match is left out; when no field
  # has one (a one-character word matches only the unstored copies, D-21), the start of the text (or the title when there
  # is no text, e.g. an attachment without text; M4 review, #27) is shown. An external document's title is highlighted in
  # its title line above, not repeated here (M4 review, #26).
  # custom_fields: {field id => IssueCustomField} whose snippets the controller kept (D-31), labelled with their names.
  def solr_search_hit_lines(hit, custom_fields = {})
    lines = []
    if !hit.external? && solr_search_highlighted?(hit.title_snippet)
      lines << [solr_search_field_label(hit, :title), hit.title_snippet, :title]
    end
    if solr_search_highlighted?(hit.content_snippet)
      lines << [solr_search_field_label(hit, :content), hit.content_snippet, :content]
    end
    (custom_fields || {}).each do |id, field|
      snippet = hit.custom_field_snippets.to_h[id]
      lines << [field.name, snippet, :custom] if solr_search_highlighted?(snippet)
    end
    if lines.empty?
      if hit.content_snippet.present?
        lines << [solr_search_field_label(hit, :content), hit.content_snippet, :content]
      elsif !hit.external? && hit.title_snippet.present?
        lines << [solr_search_field_label(hit, :title), hit.title_snippet, :title]
      end
    end
    lines
  end

  # The line above a hit's snippet (the snippet is indented under it): the name of the field it matched in; for a note,
  # its label and its link in the history. An attachment: its file's name as a link, above its first snippet only,
  # wherever it matched (the text, or the file name and description: M4 review, #8). nil for an external document's
  # text whose file name is the title shown above, and under an attachment's first snippet.
  def solr_search_hit_head(hit, field, label, container, notes, attachments, source = nil, first: true)
    if hit.type == 'attachment'
      solr_search_attachment_link(attachments[hit.item_id]) || label if first
    elsif hit.external? && field == :content
      name = solr_search_external_file_name(hit, source)
      name unless name == solr_search_external_title_text(hit)
    else
      link = solr_search_hit_link(hit, container, notes)
      link ? safe_join([label, link], ' ') : label
    end
  end

  def solr_search_external_file_name(hit, source)
    path = source ? source.display_path(hit.path) : hit.path
    path.to_s.split(%r{[\\/]}).last.presence
  end

  def solr_search_external_title_text(hit)
    hit.title.presence || hit.id.to_s
  end

  def solr_search_field_label(hit, field)
    case [hit.type, field]
    when ['issue', :title] then l(:field_subject)
    when ['issue', :content] then l(:field_description)
    when ['journal', :content] then l(:label_solr_search_note)
    when ['wiki_page', :title], ['document', :title] then l(:field_title)
    when ['wiki_page', :content], ['file', :content] then l(:label_solr_search_text)
    when ['attachment', :title] then l(:label_solr_search_file_name)
    when ['attachment', :content] then l(:label_solr_search_text)
    when ['file', :title] then l(:field_title)
    else l(:field_description)
    end
  end

  def solr_search_type_filter_label(type)
    {'issue' => l(:label_issue_plural), 'wiki_page' => l(:label_wiki), 'document' => l(:label_document_plural),
     'attachment' => l(:label_attachment_plural), 'external' => l(:label_solr_search_type_external)}[type]
  end

  # The title (tooltip) of a type's label: the number of containers that ticking it would give (D-49, "about"). The counts
  # are not written beside the choices (the screen is quieter without them); they are there for whoever points at one.
  def solr_search_type_filter_title(type)
    count = @result&.facets&.dig(:types, type)
    l(:label_solr_search_group_count, count: number_with_delimiter(SolrSearch::CountRounding.round(count))) if count
  end

  def solr_search_type_filter_text(type)
    solr_search_type_filter_label(type)
  end

  # The address of this search with some choices replaced or taken off (the facet links); the page starts again at 1
  def solr_search_facet_path(set = {}, remove = [])
    query = request.query_parameters.except('page', 'utf8', 'commit', *remove.map(&:to_s)).merge(set.stringify_keys)
    @project ? project_solr_search_path(@project, query) : solr_search_path(query)
  end

  # The projects of the facet, each [project, containers, chosen]: the most containers first, and the chosen ones that this
  # search finds nothing in (so that they can be taken off). A project's count is its own documents and those of the
  # external sources linked to it: what choosing it gives (the documents of its subprojects come with it as well).
  # Only projects the user may see. Empty before a search.
  def solr_search_project_facet
    return [] unless (facets = @result&.facets)

    counts = facets[:projects].to_h
    (@project_sources || {}).each do |project_id, collections|
      external = collections.sum {|collection| facets[:sources_by_project][collection].to_i }
      counts[project_id] = counts.fetch(project_id, 0) + external if external.positive?
    end
    rows = counts.sort_by {|id, count| [-count, id] }.filter_map do |id, count|
      project = @facet_projects[id] or next
      [project, count, @projects.include?(project)]
    end.first(SolrSearch::Searcher::FACET_LIMIT)
    rows + @projects.reject {|project| rows.any? {|row| row.first == project }}.map {|project| [project, 0, true]}
  end

  # The sources of the facet, each [collection, name, containers, chosen]. They belong to projects: only once a project
  # is chosen (or the search is in a project), and when there is more than Redmine's own data to choose between.
  def solr_search_source_facet
    return [] unless (@project || @projects.any?) && (counts = @result&.facets&.dig(:sources)) && counts.size > 1

    counts.map do |collection, count|
      name = collection == SolrSearch.collection ? l(:label_solr_search_facet_redmine) : (@facet_sources[collection]&.name || collection)
      [collection, name, count, @source_filter.include?(collection)]
    end
  end

  # What each facet of ids is called on the screen (and in the tag of the choice), with the people's ones named by Redmine
  FACET_LABELS = {trackers: :label_solr_search_facet_tracker, authors: :label_solr_search_facet_author,
                  assignees: :label_solr_search_facet_assignee, statuses: :label_solr_search_facet_status,
                  priorities: :label_solr_search_facet_priority, versions: :label_solr_search_facet_version,
                  categories: :label_solr_search_facet_category, file_types: :label_solr_search_facet_file_type}.freeze

  def solr_search_facet_names(kind)
    %i[authors assignees].include?(kind) ? @facet_people : @facet_names[kind]
  end

  # The file types are named by the extension, in capitals
  def solr_search_file_type_names
    extensions = (@result&.facets&.dig(:file_types)&.map(&:first) || []) | @filters[:file_exts]
    extensions.to_h {|ext| [ext, ext.upcase] }
  end

  # A name for a value of a facet; a version or a category of the same name in several projects is told apart by its project
  def solr_search_facet_item_names(kind)
    return solr_search_file_type_names if kind == :file_types

    names = solr_search_facet_names(kind) || {}
    return names.transform_values(&:name) unless %i[versions categories].include?(kind)

    tally = names.values.map(&:name).tally
    names.transform_values {|item| tally[item.name] > 1 ? "#{item.name} (#{item.project.name})" : item.name }
  end

  # The rows of a facet of ids, each [id, name, containers, chosen]: the most first, and the chosen ones that this search
  # finds nothing in (to take them off). kind: a key of FACET_LABELS. Only what Redmine names for this user.
  def solr_search_id_facet(kind)
    return [] unless (counts = @result&.facets&.dig(kind))

    names = solr_search_facet_item_names(kind)
    chosen_ids = @filters[SolrSearch::Searcher::FACET_FILTERS.fetch(kind)]
    rows = counts.filter_map {|id, count| (name = names[id]) && [id, name, count, chosen_ids.include?(id)] }
    rows + (chosen_ids - rows.map(&:first)).filter_map {|id| (name = names[id]) && [id, name, 0, true] }
  end

  # The ranges of the update date, each [key, text, containers, chosen]; the ones with nothing in them are left out
  def solr_search_updated_facet
    return [] unless (counts = @result&.facets&.dig(:updated))

    SolrSearch::Searcher::UPDATED_RANGES.keys.filter_map do |key|
      [key, l("label_solr_search_updated_#{key}"), counts[key], @filters[:updated] == key] if counts[key].positive? || @filters[:updated] == key
    end
  end

  # A folder as the screen shows it: the path after the host (file://host/a/b: "a/b")
  def solr_search_folder_text(path)
    path.to_s.chomp('/').sub(%r{\A[^/]*/+[^/]*/}, '')
  end

  # The folders of the facet (D-49), one level at a time: {crumbs: [[name, path], ...] from the first folder to the chosen
  # one, rows: [[path, name, containers], ...] the folders one level below it}. nil when there is nothing to show.
  def solr_search_folder_facet
    return unless (rows = @result&.facets&.dig(:folders))

    chosen = @filters[:folder]
    crumbs = []
    if chosen
      parts = solr_search_folder_text(chosen).split('/')
      root = chosen.chomp('/')[%r{\A[^/]*/+[^/]*/}]
      crumbs = parts.each_index.map {|i| [parts[i], root + parts.first(i + 1).join('/')] }
    end
    return if rows.empty? && crumbs.empty?

    {crumbs: crumbs, rows: rows.map {|path, count| [path, solr_search_folder_text(path).split('/').last, count] }}
  end

  # The custom fields of the facets that have something to show (D-49), each {custom:, rows: [[value, name, containers, chosen]],
  # range: {min:, max:}}: a list of values (rows), or a range (the smallest and the largest that this search finds). The ones
  # chosen are shown whether or not the search finds anything in them.
  def solr_search_custom_facets
    return [] unless (found = @result&.facets&.dig(:custom))

    @custom_facets.filter_map do |custom|
      chosen = @custom_filters[custom.id]
      if custom.kind == :values
        names = @custom_labels[custom.id] || {}
        chosen_values = chosen ? chosen[:values] : []
        rows = (found.dig(custom.id, :values) || []).filter_map {|value, count| (name = names[value]) && [value, name, count, chosen_values.include?(value)] }
        rows += (chosen_values - rows.map(&:first)).filter_map {|value| (name = names[value]) && [value, name, 0, true] }
        {custom: custom, rows: rows} if rows.any?
      else
        range = found[custom.id] || {}
        {custom: custom, range: range, chosen: chosen || {}} if range[:min] || chosen
      end
    end
  end

  # The address of this search with one custom field's choice changed: value: the value to take off a list (or nil: the whole
  # choice of the field is taken off)
  def solr_search_custom_path(custom, value: nil)
    query = request.query_parameters.deep_dup.except('page', 'utf8', 'commit')
    id = custom.id.to_s
    if custom.kind == :values && value
      rest = Array((query['cfv'] || {})[id]) - [value]
      query['cfv'] = (query['cfv'] || {}).merge(id => rest)
      query['cfv'].delete(id) if rest.empty?
    else
      query['cfv']&.delete(id)
      query['cfr']&.delete(id)
    end
    query.delete('cfv') if query['cfv'].blank?
    query.delete('cfr') if query['cfr'].blank?
    @project ? project_solr_search_path(@project, query) : solr_search_path(query)
  end

  # What narrows the search, [text, address that takes it off]: types (when not all), projects, sources, and the more choices
  def solr_search_chosen_tags
    tags = []
    if @types.size < @type_choices.size
      tags << ["#{l(:label_solr_search_types)}: #{@types.map {|t| solr_search_type_filter_label(t)}.join(', ')}", solr_search_facet_path({}, [:types])]
    end
    unless @project
      @projects.each do |project|
        rest = @projects.map(&:id) - [project.id]
        tags << ["#{l(:label_project)}: #{project.name}", solr_search_facet_path(rest.empty? ? {} : {'project_ids' => rest}, [:project_ids])]
      end
    end
    @source_filter.each do |collection|
      name = collection == SolrSearch.collection ? l(:label_solr_search_facet_redmine) : (@facet_sources&.dig(collection)&.name || collection)
      rest = @source_filter - [collection]
      tags << ["#{l(:label_solr_search_facet_source)}: #{name}", solr_search_facet_path(rest.empty? ? {} : {'source' => rest}, [:source])]
    end
    if @filters[:updated]
      tags << ["#{l(:label_solr_search_facet_updated)}: #{l("label_solr_search_updated_#{@filters[:updated]}")}", solr_search_facet_path({}, [:updated])]
    end
    @custom_facets.each do |custom|
      next unless (chosen = @custom_filters[custom.id])

      if custom.kind == :values
        names = @custom_labels&.dig(custom.id) || {}
        chosen[:values].each {|value| tags << ["#{custom.name}: #{names[value] || value}", solr_search_custom_path(custom, value: value)] }
      else
        text = chosen.values_at(*(custom.kind == :number ? %i[min max] : %i[from to])).map(&:to_s).join(' – ')
        tags << ["#{custom.name}: #{text}", solr_search_custom_path(custom)]
      end
    end
    if @filters[:folder]
      tags << ["#{l(:label_solr_search_facet_folder)}: #{solr_search_folder_text(@filters[:folder])}", solr_search_facet_path({}, [:folder])]
    end
    FACET_LABELS.each do |kind, label|
      key = SolrSearch::Searcher::FACET_FILTERS.fetch(kind)
      names = solr_search_facet_item_names(kind)
      @filters[key].each do |id|
        rest = @filters[key] - [id]
        tags << ["#{l(label)}: #{names[id] || id}", solr_search_facet_path(rest.empty? ? {} : {key.to_s => rest}, [key])]
      end
    end
    tags
  end

  def solr_search_type_label(container)
    case container
    when Issue then l(:label_issue)
    when WikiPage then l(:label_wiki)
    when Document then l(:label_document)
    when Project, Version then l(:label_file_plural) # the Files module: a project's and its versions' files
    end
  end

  # A closed issue looks as it does in Redmine's own lists (grey, struck through: a.issue.closed; M1 review, ui 6)
  def solr_search_container_link(container)
    case container
    when Issue then link_to("#{container.tracker} ##{container.id}: #{container.subject}", issue_path(container),
                            class: ['issue', ('closed' if container.closed?)].compact.join(' '))
    when WikiPage then link_to(container.pretty_title, solr_search_container_path(container))
    when Document then link_to(container.title, solr_search_container_path(container))
    # the Files module's page: a version's files are listed there too, not on the version's page (M4 review, #9)
    when Project then link_to(l(:label_solr_search_files_of, name: container.name), project_files_path(container))
    when Version then link_to(l(:label_solr_search_files_of, name: container.name), project_files_path(container.project))
    end
  end

  # The project a container belongs to (its name is shown beside the link): a project's attachments are its own
  def solr_search_container_project(container)
    container.is_a?(Project) ? container : container.project
  end

  def solr_search_container_path(container)
    case container
    when Issue then issue_path(container)
    when WikiPage then project_wiki_page_path(container.project, container.title)
    when Document then document_path(container)
    when Project then project_files_path(container)
    when Version then project_files_path(container.project)
    end
  end

  # When nothing matched: the choices on the form that, undone, would search more widely (M1 review, ui 4)
  def solr_search_widen_hints
    [
      (l(:text_solr_search_hint_any_words) if @all_words),
      (l(:text_solr_search_hint_exact) if @exact),
      (l(:text_solr_search_hint_types) if @types.size < @type_choices.size),
      (l(:text_solr_search_hint_projects) if @projects.any?),
      (l(:text_solr_search_hint_attributes) unless @attributes)
    ].compact
  end

  # A link to the hit itself when it is not the container: a note links to its place in the issue's history, named as
  # the history names it ("#3", its author and date; notes: SolrSearchController#notes_as_in_history).
  def solr_search_hit_link(hit, container, notes)
    return unless hit.type == 'journal' && container.is_a?(Issue)

    note = notes[hit.item_id]
    link = link_to("##{note&.indice || hit.item_id}", issue_path(container, anchor: "change-#{hit.item_id}"))
    return link unless note

    safe_join([link, note.user.to_s, format_date(note.created_on), (solr_search_private_badge if note.private_notes?)]
                .compact, ' ')
  end

  # The mark Redmine puts on a private issue and a private note (issues/show, JournalsHelper), with Redmine's style.
  # Whether it is private is Redmine's value, not the index's (D-25).
  def solr_search_private_badge
    content_tag('span', l(:field_is_private), class: 'badge badge-private private')
  end

  # The time shown at the end of a result: of the container, or for the Files module's (which has no time of its own) of
  # the newest attachment the result shows
  def solr_search_container_time(container, group = nil, attachments = {})
    case container
    when Issue then container.updated_on
    when WikiPage then container.updated_on # loaded with the page (WikiPage.with_updated_on), not the text
    when Document then container.created_on
    when Project, Version then group&.hits&.filter_map {|hit| attachments[hit.item_id]&.created_on }&.max
    end
  end

  # What the time at the end of a result is: an issue's and a page's is their last change; a document's, and the Files
  # module's (the newest attachment), when it was made
  def solr_search_time_label(container)
    "#{container.is_a?(Issue) || container.is_a?(WikiPage) ? l(:field_updated_on) : l(:field_created_on)}:"
  end

  # An external document's hit (design D-33): what Solr returned, shown as the source says (D-35)
  # The element carries the values for those who make the link in their own way (a View Customize script, say)
  def solr_search_external_data(hit, source, group_id: nil, rank: nil)
    {class: 'solr-search-external-hit',
     data: {solr_group: group_id, solr_rank: rank, solr_source: hit.source, solr_source_name: source&.name || hit.source, solr_id: hit.id,
            solr_title: hit.title, solr_url: hit.url, solr_path: source ? source.display_path(hit.path) : hit.path,
            # as the crawler saw it, whatever the source shows
            solr_indexed_path: hit.path}}
  end

  # The title, highlighted when matched (M4 review, #26), and as a link when the source makes one from its pattern.
  # It opens in a new tab: the document is outside Redmine, and the results stay where they are (noopener: the page
  # opened gets no handle on this one).
  def solr_search_external_title(hit, source)
    plain = solr_search_external_title_text(hit)
    label = solr_search_highlighted?(hit.title_snippet) ? solr_search_snippet(hit.title_snippet) : plain
    url = source&.link_for(hit)
    return label unless url

    link_to(label, url, class: 'solr-search-external-link', target: '_blank', rel: 'noopener noreferrer',
                        title: l(:text_solr_search_opens_in_new_tab),
                        'aria-label': "#{plain} (#{l(:text_solr_search_opens_in_new_tab)})")
  end

  # Solr's time as the screen shows a time; nil when there is none or it is not one
  def solr_search_external_time(hit)
    format_time(Time.iso8601(hit.updated_at.to_s)) if hit.updated_at.present?
  rescue ArgumentError
    nil
  end

  # The file an attachment hit is about: its name (linked to Redmine's preview page, with the clip icon), its size and
  # a direct download icon beside it, as in Redmine's own attachment lists (design D-36; M4 review, #39)
  def solr_search_attachment_link(attachment)
    return unless attachment

    safe_join([link_to_attachment(attachment, class: 'icon icon-attachment', icon: 'attachment'),
               content_tag('span', "(#{number_to_human_size(attachment.filesize)})",
                           class: 'size solr-search-attachment-size'),
               link_to_attachment(attachment, class: 'icon-only icon-download', title: l(:button_download),
                                              download: true, icon: 'download')], ' ')
  end

  # The global search page with the current form's choices kept (for widening a project search to all projects; M4 review, #14)
  def solr_search_all_projects_path
    solr_search_path(
      q: @solr_question.presence,
      all_words: ('1' if @all_words),
      exact: ('1' if @exact),
      attributes: ('1' if @attributes),
      types: (@types if @type_choices && @types && @types.size < @type_choices.size),
      sort: (@sort unless @sort == 'relevance')
    )
  end
end
