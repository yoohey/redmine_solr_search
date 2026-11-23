# frozen_string_literal: true

module SolrSearch
  # Builds the search screen's query and sends it (design D-21, D-24, D-27): each word quoted, sow=false, both field
  # pairs, one result per container (collapse and expand, D-48), snippets, and a permission filter that lets through
  # only what the user may see (design chapter 5, D-30).
  class Searcher
    include Facets    # the facets and the choices (lib/solr_search/searcher/facets.rb)
    include Filters   # the narrowing by what the user chose (searcher/filters.rb)
    include Reranking # the external reranker's part (searcher/reranking.rb)

    QF = 'title_ja^3 content_ja^2 title content' # the weights of a search that was never tuned (D-21); Tuning has them, and the tab of the admin page changes them (D-51)
    QF_EXACT = 'title content'                   # the "exact string" mode: the n-gram pair only (D-24 R9)
    GROUP_LIMIT = 3                              # items shown under a container (R1-a)
    # Containers on a page when nothing else is asked: the default of the setting (Settings::PER_PAGE: 10 to 100). 50, so that a
    # page whose hits are all dropped by the display check is rarer (the pages are not filled up again); Solr's time does not
    # depend on it, the display check and the page's size do (2026-10-27)
    PER_PAGE = 50
    # How many containers one can reach. Solr sorts start + rows documents, so an unbounded page number lets anyone make
    # Solr allocate for millions of them (M1 review A1); the last page is this over the page's size.
    MAX_REACH = 2000

    def self.max_page(per_page)
      [MAX_REACH / per_page, 1].max
    end
    # Snippet markers: control characters that cannot come from the text. The view escapes the snippet first and
    # only then turns them into tags, so the stored text is never output as HTML (design chapter 7).
    HL_PRE = "\u0002"
    HL_POST = "\u0003"
    # about three lines of the result (the screen cuts at three; Google-like layout, 2026-10-07)
    HL_FRAGSIZE = 240

    # The type of the documents in external sources (docs/schema.md, chapter 4)
    EXTERNAL_TYPE = 'file'

    # What the screen offers as "type" (R5) => the document types it stands for
    TYPE_FILTERS = {
      'issue' => %w[issue journal],
      'wiki_page' => %w[wiki_page],
      'document' => %w[document],
      'attachment' => %w[attachment], # of issues, wiki pages, documents and the Files module (design D-36)
      'external' => [EXTERNAL_TYPE]
    }.freeze

    # What Solr returns for each hit when external sources are searched (design D-33): an external document has no
    # record in Redmine, so what the list shows comes from Solr (D-25)
    FL = 'id,type,item_id'
    EXTERNAL_FL = "#{FL},source,title,url,path,updated_at"
    # what the grouping of the hits needs besides (D-48): the container
    GROUP_FL = 'group_id'

    # custom_field_snippets: {custom field id => snippet} (D-31); Solr's, before the screen drops the hidden fields
    # source, title, url, path, updated_at: only asked for, and only used, for an external document (see EXTERNAL_FL)
    Hit = Struct.new(:id, :type, :item_id, :title_snippet, :content_snippet, :custom_field_snippets,
                     :source, :title, :url, :path, :updated_at, :score, keyword_init: true) do
      def external?
        type == EXTERNAL_TYPE
      end
    end
    Group = Struct.new(:group_id, :hits, :hit_count, keyword_init: true)
    # debug: {url:, qtime:, parsed:} when the searcher was made with debug: true (shown to admins), else nil
    # missing_sources: collections of sources that Solr did not have, left out of the request (design D-33)
    # facets (D-49): nil, or {types: {key of TYPE_FILTERS => containers}, sources: {'redmine' or a collection => containers},
    # sources_by_project: like sources, without the choice of projects (for the counts of the projects), projects, trackers,
    # authors, assignees: [[id, containers], ...] (the most containers first), updated: {range => containers}};
    # each counted without its own choice
    # reranker: nil, or what the external reranker did for this search (D-56): {used: true, milliseconds:, window:} when the
    # first containers were put in its order, {used: false, error: 'why'} when it was asked and failed (the order is Solr's)
    # attributes_dropped: true when the search with the custom fields was refused by Solr for too many clauses (Q-49) and was
    # sent again without them
    Result = Struct.new(:groups, :group_count, :hit_count, :debug, :missing_sources, :facets, :reranker, :attributes_dropped,
                        keyword_init: true)
    # What Solr says when a query has more clauses than maxBooleanClauses (Lucene's TooManyClauses; the wording differs by version)
    TOO_MANY_CLAUSES = /too many (nested )?clauses|maxClauseCount/i
    # How many values of a facet are counted (the most containers first); the screen shows the first few and the rest on request
    FACET_LIMIT = 30
    # The ranges of the update date that the screen offers (D-49): the filter of each
    UPDATED_RANGES = {
      'week' => 'updated_at:[NOW/DAY-7DAYS TO *]', 'month' => 'updated_at:[NOW/DAY-1MONTH TO *]',
      'year' => 'updated_at:[NOW/DAY-1YEAR TO *]', 'older' => 'updated_at:[* TO NOW/DAY-1YEAR]'
    }.freeze
    # Choices of ids and the field they narrow: an issue's tracker, author, assignee, status, priority, target version and
    # category (a note or an attachment has its issue's). Documents without the field (Wiki pages, external documents)
    # do not pass them.
    ID_FILTERS = {tracker_ids: 'tracker_id', author_ids: 'author_id', assigned_to_ids: 'assigned_to_id', status_ids: 'status_id',
                  priority_ids: 'priority_id', fixed_version_ids: 'fixed_version_id', category_ids: 'category_id'}.freeze
    # Choices of words (the extensions of file names, written as the index has them) and the field they narrow. Only what
    # the field holds: letters and digits.
    STRING_FILTERS = {file_exts: 'file_extension'}.freeze
    STRING_VALUE = /\A[a-z0-9]{1,10}\z/
    # The folders of an external document, one level at a time (D-49): file_dir_1 .. file_dir_FOLDER_LEVELS hold the path up to
    # the K-th folder after the host. A chosen folder is a path of one of those levels.
    FOLDER_LEVELS = 6
    FOLDER_PATH = %r{\A[A-Za-z][A-Za-z0-9+.-]*:/{1,3}[^\s'"\\{}\u0000-\u001F]*\z}

    # How deep a folder path is (the number of folders after the host: file://host/a/b is 2), nil when it is not a folder
    # that the index has (not a path of this form, or deeper than FOLDER_LEVELS)
    def self.folder_depth(path)
      return unless path.is_a?(String) && path.match?(FOLDER_PATH)

      depth = path.chomp('/').count('/') - 2
      depth if depth.between?(1, FOLDER_LEVELS)
    end

    # The fields of the custom facets, by kind (D-49): values (chosen: cfs_), number and date (a range: cfn_, cfd_)
    CUSTOM_FIELD_PREFIX = {values: 'cfs', number: 'cfn', date: 'cfd'}.freeze
    MAX_CHOSEN_VALUES = 50
    # The facet of each of them (name => the key of the choice in ID_FILTERS or STRING_FILTERS), and of the projects
    FACET_FILTERS = {trackers: :tracker_ids, authors: :author_ids, assignees: :assigned_to_ids, statuses: :status_ids,
                     priorities: :priority_ids, versions: :fixed_version_ids, categories: :category_ids,
                     file_types: :file_exts}.freeze
    FACET_FIELDS = {trackers: 'tracker_id', authors: 'author_id', assignees: 'assigned_to_id', statuses: 'status_id',
                    priorities: 'priority_id', versions: 'fixed_version_id', categories: 'category_id',
                    file_types: 'file_extension', projects: 'project_id'}.freeze

    # Words as the user typed them, split on any whitespace (the ideographic space too).
    def self.words(text)
      text.to_s.split(/[[:space:]]+/).reject(&:empty?)
    end

    # A quoted word for the Lucene syntax: a word Kuromoji splits stays a phrase (D-21).
    def self.phrase(word)
      %("#{word.gsub(/[\\"]/) {|c| "\\#{c}"}}")
    end

    # debug: also return the request URL, Solr's QTime and the parsed query (debug=query)
    # expand_vu: send words in every ヴ / バ spelling (SpellingVariants; an optional feature, on by default, D-21)
    # tuning: the weights of the order (Tuning.normalize; SolrSearchTuning.current); the defaults are the query as it always was
    # dictionary: the query expansion dictionary (QueryDictionary; SolrSearchSynonym.dictionary), none by default (D-53)
    # extra_params: parameters added to the one request that returns the results (not to the counts, the facets and the snippets),
    # for trying a thing in an experiment (the re-ranking `rq` of Q-24, docs/experiments/m7-rerank); none in a search of the screen
    # reranker: an external reranker (Reranker.from_settings), or none (design D-56)
    def initialize(user:, client: Client.from_env(SolrSearch.collection), debug: false, expand_vu: true,
                   tuning: Tuning.normalize(nil), dictionary: QueryDictionary.empty, extra_params: {}, reranker: nil)
      @reranker = reranker
      @tuning = tuning
      @extra_params = extra_params
      @dictionary = dictionary
      @user = user
      @client = client
      @debug = debug
      @expand_vu = expand_vu
    end

    SORTS = %w[relevance updated].freeze
    NOTHING = PermissionFilter::NOTHING
    MAX_ALTERNATIVES = 32 # the spellings of one place of the query (the dictionary's terms, each in its ヴ / バ forms)

    # Returns a Result, or nil when there is nothing to search for.
    # all_words: every word must be in the same item (an issue's text, one note ...) (R4). sort: "relevance" or
    # "updated" (R3); by update, a container comes where its newest matching item puts it.
    # types: keys of TYPE_FILTERS to keep (nil or empty: all). project_ids: projects to keep (nil: all the user may
    # see). exact: the "exact string" mode (D-24 R9): the n-gram pair only, no ヴ / バ expansion.
    # custom_fields: a CustomFieldQuery to search the issue custom fields too ("include attributes", D-31 R10), or nil.
    # facets: true also counts the containers by type, source and project, each without its own choice (D-49).
    # facet_sources: every source the user may search, whatever projects are chosen (sources is narrowed to the chosen
    # projects): the facets count the external documents of the other projects too. Default: sources.
    # custom_facets: the issue custom fields that are facets for this user (CustomFieldQuery.facets_for): each is counted, and
    # custom_filters narrows by them: {id => {values: [...]} for a list, {min:, max:} for a number, {from:, to:} for a date}.
    # A filter for a field that is not among custom_facets is dropped: the user does not see that field.
    # scores: also return the score of each hit (Hit#score), for the fine tuning tab's trial search.
    # attribute_filters: filter queries for the issue's attributes (FilterTranslator): all must hold, and every one of the
    # facets counts within them.
    # filters: more choices (D-49): updated: a key of UPDATED_RANGES, and the keys of ID_FILTERS (tracker_ids ...): arrays of ids,
    # and of STRING_FILTERS (file_exts): arrays of extensions, and folder: the path of a folder (FOLDER_LEVELS).
    # source_filter: only these sources ('redmine' and collection names of sources), nil or empty: all.
    # detail: false asks for the containers only (their first hit, no snippets, no count of hits): what a caller that
    # only needs the order wants (the golden sets) and what spares the requests below for the hits.
    # sources: collections of the external sources the user may search (SourceAccess; design D-33), asked together
    # with Redmine's data in one request, and let through by the filter query alone. Empty: the request is the same
    # as ever, for Redmine's data only. project_ids narrow Redmine's data; the caller has narrowed sources as well.
    def search(text, page: 1, per_page: PER_PAGE, all_words: false, sort: 'relevance', types: nil, project_ids: nil,
               exact: false, custom_fields: nil, sources: [], detail: true, facets: false, source_filter: nil, filters: {}, facet_sources: nil,
               custom_facets: [], custom_filters: {}, attribute_filters: [], scores: false)
      words = self.class.words(text)
      return nil if words.empty?

      # the names go into the filter as they are: only what a source may be (D-35)
      sources = Array(sources).select {|name| SolrSearch.external_collection?(name)}.uniq.sort
      # a choice of types without the external ones can find nothing there: the sources are not asked (they would only
      # change the statistics that the scores of Redmine's data are made of, D-48)
      facet_sources = Array(facet_sources || sources).select {|name| SolrSearch.external_collection?(name)}.uniq.sort
      custom = custom_filter_expressions(custom_facets, custom_filters)
      Array(attribute_filters).each_with_index {|expression, i| custom[:"attribute_#{i}"] = expression.to_s }
      all_sources = sources # for the facets: they count what the choice of types or sources leaves out too
      sources = [] if types.present? && !types.include?('external')
      source_filter = Array(source_filter).uniq.select {|name| name == SolrSearch.collection || all_sources.include?(name)}
      sources &= source_filter if source_filter.any?
      build = lambda do |with_attributes|
        built = params(words, page.clamp(1, self.class.max_page(per_page)), per_page, all_words, sort, exact)
        add_custom_fields(built, custom_fields, exact) if with_attributes
        built[:debug] = 'query' if @debug
        built.reject! {|k, _| k.to_s.start_with?('hl')} unless detail
        built
      end
      with_attributes = custom_fields && !custom_fields.empty?
      attributes_dropped = false
      base = build.call(with_attributes)
      # Asked as it is. A collection Solr does not know fails the whole request (400); only then it is left out and the
      # request sent again, for each such collection (design D-33; the first is named, so one at a time). The caller
      # hears of them in missing_sources.
      missing = []
      filtered = nil
      begin
        request = base.dup
        add_sources(request, sources)
        request[:fq] = [request[:fq], *narrowing_filters(types, project_ids, sources, filters, custom), *source_filter_clause(source_filter)]
        filtered = request.dup
        request = collapse(request, sort, expand: detail)
        request = request.merge(@extra_params) unless @extra_params.empty?
        request[:fl] += ',score' if scores
        res, reranked = select_results(request, text, page, per_page, sort, detail)
      rescue Client::Error => e
        # words x (2 x fields + 4) clauses can pass Solr's limit when many custom fields may be seen (Q-49): the search goes
        # on without the custom fields, and the screen says so
        if with_attributes && e.message.match?(TOO_MANY_CLAUSES)
          with_attributes = false
          attributes_dropped = true
          base = build.call(false)
          retry
        end
        name = missing_collection(e, sources)
        raise unless name

        missing << name
        sources -= [name]
        retry
      end
      docs = res.dig('response', 'docs')
      expanded = res['expanded'] || {}
      highlighting = res['highlighting'] || {}
      highlighting = highlighting.merge(expanded_highlighting(filtered, expanded, highlighting)) if detail
      groups = docs.map do |d|
        others = expanded.dig(d['group_id'], 'docs') || []
        Group.new(group_id: d['group_id'],
                  hit_count: 1 + (expanded.dig(d['group_id'], 'numFound') || 0),
                  hits: best_hits(d, others).map {|h| hit(h, highlighting[h['id']] || {})})
      end
      group_count = res.dig('response', 'numFound')
      if detail && facets
        # the count of hits comes with the facets: one request for both
        hits, counted = facet_counts(base, types: types, project_ids: project_ids, sources: all_sources - missing,
                                           wide_sources: (facet_sources | all_sources) - missing,
                                           source_filter: source_filter, filters: filters, custom: custom, custom_facets: custom_facets)
      elsif detail
        hits = hit_count(filtered, group_count)
      end
      Result.new(groups: groups, group_count: group_count, hit_count: hits, facets: counted, reranker: reranked,
                 debug: @debug ? debug_info(request, res) : nil, missing_sources: missing, attributes_dropped: attributes_dropped)
    end

    # Only what this user may see, as one filter query (design D-30; PermissionFilter)
    def permission_filter
      PermissionFilter.for(@user).to_s
    end

    private

    # The query (design D-31): an outer lucene query of clauses, each an edismax query on the user's words. The words
    # are only in uq, never in q: inside uq a {!...} is text. The first clause is in parentheses: a q that starts with
    # {!...} is read as the local params of the whole query, and the rest is dropped (docs/experiments/cf-d31, round 1).
    # The nested edismax queries take q.op and sow from the request.
    def params(words, page, per_page, all_words, sort, exact)
      request = {
        q: '({!edismax qf=$mainqf v=$uq})',
        uq: places(words, exact).map {|alternatives| clause(alternatives, expand: @expand_vu && !exact)}.join(' '),
        mainqf: exact ? QF_EXACT : Tuning.qf(@tuning),
        'q.op': all_words ? 'AND' : 'OR', # R4: any of the words by default
        defType: 'lucene', sow: 'false',
        fq: permission_filter,
        fl: FL,
        rows: per_page, start: (page - 1) * per_page,
        hl: 'true', 'hl.method': 'unified', 'hl.fl': 'title,content', 'hl.fragsize': HL_FRAGSIZE,
        'hl.defaultSummary': 'true', 'hl.tag.pre': HL_PRE, 'hl.tag.post': HL_POST,
        # with weightMatches (the default), an AND whose words match in different fields (subject and description)
        # highlights nothing at all; term-based highlighting marks each word where it is (docs/solr-knowhow.md)
        'hl.weightMatches': 'false'
      }
      # containers follow their newest matching item (collapse picks that item, below); the best hits are chosen later
      request.merge!(sort: 'updated_at desc, id asc') if sort == 'updated'
      request.merge!(Tuning.params(@tuning, exact: exact)) # the weights of the order (the tab of the admin page): none if never tuned
      request
    end

    # One result per container (D-48): collapse keeps one document of each container, expand returns others of it.
    # The collapse is a post filter, so it works on what the other filters let through. By relevance the kept document is
    # the best one (the default); by update it is the newest, which puts the container where its newest item is. The
    # expanded documents are scored by the shard alone, without the merged statistics, so their scores cannot be compared
    # with the kept document's: the kept one is always the first hit, then the best of the others. expand: false: no
    # expanded documents (only the containers are wanted).
    def collapse(request, sort, expand: true)
      request = request.merge(fl: "#{request[:fl]},#{GROUP_FL}")
      request[:fq] = [*Array(request[:fq]),
                      sort == 'updated' ? "{!collapse field=group_id sort='updated_at desc'}" : '{!collapse field=group_id}']
      return request unless expand

      request.merge('expand': 'true', 'expand.rows': GROUP_LIMIT - 1, 'expand.sort': 'score desc')
    end

    # The hits of a container: the kept document, then the best of the others, GROUP_LIMIT in all
    def best_hits(kept, others)
      [kept, *others.first(GROUP_LIMIT - 1)]
    end

    # Solr highlights the kept documents only, not the expanded ones: the snippets of those come from one more request
    # for their ids, with the same query and filters (so the permission filter too).
    def expanded_highlighting(filtered, expanded, highlighting)
      ids = expanded.values.flat_map {|e| e['docs'].map {|d| d['id']}}.reject {|id| highlighting.key?(id)}
      return {} if ids.empty?

      request = filtered.merge(rows: ids.size, start: 0, fl: 'id')
      request.delete(:sort)
      request.delete(:debug)
      request.delete(:boost) # the order does not matter here
      request.delete(:pf2)
      request[:fq] = [*Array(request[:fq]), "id:(#{ids.map {|id| self.class.phrase(id)}.join(' OR ')})"]
      @client.select(request)['highlighting'] || {}
    end

    # The number of matching documents ("about N hits"), which a collapsed answer does not hold: numFound is the number
    # of containers. Asked without the collapse and without the snippets.
    def hit_count(filtered, group_count)
      return 0 if group_count.zero?

      request = filtered.reject {|k, _| k.to_s.start_with?('hl') || %i[sort start debug boost pf2].include?(k)}
      @client.select(request.merge(rows: 0, fl: 'id')).dig('response', 'numFound')
    end

    # The collection a 400 of Solr says it could not find, when it is one of the sources asked for (never Redmine's
    # own: then the search fails as any failure does)
    def missing_collection(error, sources)
      return unless error.status == 400

      name = error.message[/Could not find collection\s*:\s*(\S+)/, 1]
      name if sources.include?(name)
    end

    # D-33: the sources' collections beside Redmine's, and their documents let through by their source value
    def add_sources(request, sources)
      return if sources.empty?

      request[:collection] = [SolrSearch.collection, *sources].join(',')
      request[:fl] = EXTERNAL_FL
      request[:fq] = or_sources(request[:fq], sources, only_files: true)
    end

    # The clause, or a document of one of the sources. A clause that lets nothing through leaves only the sources.
    # only_files: the filter that lets documents through also holds their type: a document of a source that says it is
    # an issue (or has a group id of one) is not let through to be taken for a record of Redmine (security review
    # 2026-10-06, 1)
    def or_sources(clause, sources, only_files: false)
      return clause if sources.empty?

      terms = "{!terms f=source v='#{sources.join(',')}'}"
      terms = "(#{terms} AND type:#{EXTERNAL_TYPE})" if only_files
      clause == NOTHING ? terms : "(#{terms}) OR (#{clause})"
    end

    # D-31: the fields for all users join the main clause; the others come as clauses of their own, beside it. Every
    # field the user may see somewhere gives snippets.
    def add_custom_fields(request, custom_fields, exact)
      request[:mainqf] = [request[:mainqf], *custom_fields.main_fields(exact: exact)].join(' ')
      custom_fields.clauses(exact: exact).each do |clause, qf|
        request[:q] = "#{request[:q]} OR #{clause}"
        request.merge!(qf)
      end
      request[:'hl.fl'] = [request[:'hl.fl'], *custom_fields.highlight_fields].join(',')
    end

    # The places of the query: a word, or the words that stand for a term of the dictionary, with the alternatives to look for
    # in its place. The "exact string" mode takes no dictionary (D-53).
    def places(words, exact)
      exact ? words.map {|w| [w] } : @dictionary.expand(words)
    end

    # One place of the query: a quoted phrase, or an OR group of its alternatives, each in its spellings (round 3c checked it
    # with AND too). The alternatives are those of the dictionary (the typed one first); at most MAX_ALTERNATIVES in all, and
    # the typed spelling is always kept.
    def clause(alternatives, expand:)
      variants = alternatives.flat_map {|a| expand ? SpellingVariants.expand(a) : [a] }.uniq.first(MAX_ALTERNATIVES)
      return self.class.phrase(variants.first) if variants.size == 1

      "(#{variants.map {|v| self.class.phrase(v)}.join(' OR ')})"
    end

    def debug_info(request, res)
      {url: @client.select_url(request), qtime: res.dig('responseHeader', 'QTime'),
       parsed: res.dig('debug', 'parsedquery_toString')}
    end

    def hit(doc, hl)
      # only the fields that matched: hl.defaultSummary gives the start of every other one too
      custom = hl.filter_map do |field, s|
        snippet = Array(s).first
        [Regexp.last_match(1).to_i, snippet] if field =~ /\Acft_(\d+)\z/ && snippet.to_s.include?(HL_PRE)
      end.to_h
      Hit.new(id: doc['id'], type: doc['type'], item_id: doc['item_id'],
              title_snippet: Array(hl['title']).first, content_snippet: Array(hl['content']).first,
              custom_field_snippets: custom,
              source: doc['source'], title: doc['title'], url: doc['url'], path: doc['path'],
              updated_at: doc['updated_at'], score: doc['score'])
    end
  end
end
