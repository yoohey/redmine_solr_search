# frozen_string_literal: true

require_relative '../light_helper'

# How the search screen's query is built and its answer read (design D-21, D-24, D-27). The permission filter reads
# Redmine's permissions and is replaced here by a fixed string; it is checked on the seed data (docs/experiments).
class SearcherTest < Minitest::Test
  PERMISSION = 'PERMISSION'

  # Stands in for SolrSearch::Client: keeps the request, returns a fixed answer
  class FakeClient
    attr_reader :request

    def initialize(answer)
      @answer = answer
    end

    def select(params)
      @request = params
      @answer
    end

    def select_url(_params)
      'http://solr/select?...'
    end
  end

  EMPTY = {'response' => {'numFound' => 0, 'docs' => []}}.freeze
  COLLAPSE = '{!collapse field=group_id}'
  FL_EXTRA = ',group_id'

  def searcher(answer = EMPTY, **options)
    client = FakeClient.new(answer)
    searcher = SolrSearch::Searcher.new(user: nil, client: client, **options)
    searcher.define_singleton_method(:permission_filter) { PERMISSION }
    [searcher, client]
  end

  # The request that was sent, as the filters narrow: without the collapse (that has tests of its own)
  def request_for(text, searcher_options: {}, **search_options)
    r = raw_request_for(text, searcher_options: searcher_options, **search_options)
    r.merge(fq: r[:fq].reject {|f| f.start_with?('{!collapse')}, fl: r[:fl].delete_suffix(FL_EXTRA))
  end

  def raw_request_for(text, searcher_options: {}, **search_options)
    s, client = searcher(**searcher_options)
    s.search(text, **search_options)
    client.request
  end

  def test_words_split_on_any_whitespace
    assert_equal %w[議事録 会議], SolrSearch::Searcher.words(" 議事録　会議 ")
    assert_empty SolrSearch::Searcher.words("　 ")
  end

  def test_phrase_escapes_quotes_and_backslashes
    assert_equal '"議事録"', SolrSearch::Searcher.phrase('議事録')
    assert_equal '"a\\"b\\\\c"', SolrSearch::Searcher.phrase('a"b\\c')
  end

  def test_nothing_to_search_for
    s, client = searcher
    assert_nil s.search(" 　")
    assert_nil client.request
  end

  def test_each_word_quoted_any_of_them_by_default
    r = request_for('議事録 会議')
    assert_equal '"議事録" "会議"', r[:uq]
    assert_equal 'OR', r[:'q.op']
    assert_equal 'false', r[:sow]
    assert_equal SolrSearch::Searcher::QF, r[:mainqf]
    assert_equal [PERMISSION], r[:fq]
  end

  # Q-24 (an experiment): the extra parameters go to the request of the results, and none are sent when none are given
  def test_extra_params_are_added_to_the_request_of_the_results_only_when_given
    rq = '{!rerank reRankQuery=$rqq reRankDocs=100 reRankWeight=2}'
    r = request_for('議事録', searcher_options: {extra_params: {rq: rq, rqq: '"議事録"'}})
    assert_equal rq, r[:rq]
    assert_equal '"議事録"', r[:rqq]
    refute request_for('議事録').key?(:rq)
  end

  # D-56: the external reranker puts the first containers in its order
  def doc(n)
    {'id' => "issue##{n}", 'type' => 'issue', 'item_id' => n, 'group_id' => "issue-#{n}"}
  end

  def answer(docs, found: docs.size, highlighting: {})
    {'response' => {'numFound' => found, 'docs' => docs}, 'highlighting' => highlighting}
  end

  COUNT = {'response' => {'numFound' => 7}}.freeze # the answer to the request for the number of hits

  def reranked_searcher(client, scores: nil, error: nil, docs: 20)
    seen = []
    http = lambda do |_uri, body, _headers, _timeout|
      seen << JSON.parse(body)
      raise Errno::ECONNREFUSED if error

      JSON.generate(scores.each_with_index.map {|score, i| {index: i, score: score}})
    end
    reranker = SolrSearch::Reranker.new(url: 'http://r', http: http, docs: docs, chars: 50)
    s = SolrSearch::Searcher.new(user: nil, client: client, reranker: reranker)
    s.define_singleton_method(:permission_filter) { PERMISSION }
    [s, seen]
  end

  def test_the_reranker_puts_the_window_in_its_order_and_the_page_is_asked_for_by_group
    window = answer([doc(1), doc(2), doc(3)], found: 3000, highlighting: {'issue#1' => {'title' => ["\u0002agenda\u0003 one"], 'content' => ['first text']}})
    client = SequenceClient.new(window, answer([doc(1), doc(2), doc(3)], found: 3), COUNT)
    s, seen = reranked_searcher(client, scores: [0.1, 0.3, 0.9])
    result = s.search('agenda')
    assert_equal %w[issue-3 issue-2 issue-1], result.groups.map(&:group_id)
    assert_equal 3000, result.group_count, 'the count is that of the first request'
    assert_equal true, result.reranker[:used]
    assert_equal 3, result.reranker[:window]
    assert_equal 'agenda', seen.first['query']
    assert_equal "agenda one\nfirst text", seen.first['texts'].first, 'the title and the snippet, the markers taken off'
    first, second = client.requests.first(2)
    assert_equal SolrSearch::Searcher::PER_PAGE, first[:rows] # the window: the setting (20) rounded up to whole pages
    assert_equal 0, first[:start]
    refute first.keys.any? {|k| k.to_s.start_with?('expand') }, 'no other hits in the first request'
    assert_equal 50, first[:'hl.fragsize']
    assert_equal 3, second[:rows]
    assert_includes second[:fq], 'group_id:("issue-3" OR "issue-2" OR "issue-1")'
    assert second.key?(:expand), 'the page itself is asked for as ever, with the other hits'
  end

  def test_the_second_page_of_the_window_is_cut_from_the_same_order
    docs = (1..30).map {|n| doc(n) }
    client = SequenceClient.new(answer(docs, found: 30), answer(docs.first(10).reverse, found: 30), COUNT)
    s, = reranked_searcher(client, scores: (1..30).to_a, docs: 40) # 40 rounds up to two pages of 20
    result = s.search('x', page: 2, per_page: 20)
    assert_equal (1..10).to_a.reverse.map {|n| "issue-#{n}"}, result.groups.map(&:group_id), 'the 21st to the 30th by score: the ten lowest, best first'
    assert_equal 40, client.requests.first[:rows]
    assert_equal 10, client.requests[1][:rows]
  end

  def test_a_failing_reranker_leaves_the_order_to_solr_and_says_so
    client = SequenceClient.new(answer([doc(1), doc(2)]), answer([doc(1), doc(2)]), COUNT)
    s, = reranked_searcher(client, error: true)
    result = s.search('x')
    assert_equal %w[issue-1 issue-2], result.groups.map(&:group_id)
    assert_equal false, result.reranker[:used]
    assert_match(/ECONNREFUSED/, result.reranker[:error])
  end

  def test_the_reranker_is_not_asked_by_update_outside_the_window_without_details_or_for_one_container
    two = answer([doc(1), doc(2)])
    {'by update' => {sort: 'updated'}, 'page 3' => {page: 3}, 'no details' => {detail: false}}.each do |label, options|
      client = SequenceClient.new(two, two, COUNT)
      s, seen = reranked_searcher(client, scores: [0.1, 0.2])
      result = s.search('x', **options)
      assert_nil result.reranker, label
      assert_empty seen, label
      assert_equal 1, client.requests.count {|r| r[:rows] == SolrSearch::Searcher::PER_PAGE }, label if label == 'by update'
    end
    client = SequenceClient.new(answer([doc(1)]), answer([doc(1)]), COUNT)
    s, seen = reranked_searcher(client, scores: [0.5])
    assert_nil s.search('x').reranker, 'one container: nothing to put in order'
    assert_empty seen
  end

  def test_without_a_reranker_the_result_says_nothing_of_one_and_one_request_is_made_for_the_results
    s, client = sequence(answer([doc(1)]), COUNT)
    result = s.search('x', detail: false)
    assert_nil result.reranker
    assert_equal 1, client.requests.size
  end

  # D-53: a word of the dictionary becomes the OR of its group; the exact string mode takes no dictionary
  def test_the_dictionary_expands_a_word_into_its_group
    dictionary = SolrSearch::QueryDictionary.build("SSO,シングルサインオン\nシングル サインオン,SSO\n")
    options = {searcher_options: {dictionary: dictionary}}
    assert_equal '"障害" ("SSO" OR "シングルサインオン" OR "シングル サインオン")', request_for('障害 SSO', **options)[:uq]
    assert_equal '("シングル サインオン" OR "SSO") "設定"', request_for('シングル サインオン 設定', **options)[:uq]
    assert_equal '"SSO"', request_for('SSO', searcher_options: {dictionary: dictionary}, exact: true)[:uq]
    assert_equal '"SSO"', request_for('SSO')[:uq]
  end

  def test_the_dictionary_terms_are_also_given_their_spellings_and_the_typed_one_stays_first
    dictionary = SolrSearch::QueryDictionary.build("バイオリン,弦楽器\n")
    assert_equal '("バイオリン" OR "ヴァイオリン" OR "弦楽器")', request_for('バイオリン', searcher_options: {dictionary: dictionary})[:uq]
    assert_equal '("バイオリン" OR "弦楽器")', request_for('バイオリン', searcher_options: {dictionary: dictionary, expand_vu: false})[:uq]
  end

  def test_the_alternatives_of_one_place_are_at_most_thirty_two_and_the_typed_one_is_kept
    terms = (1..8).map {|i| "ビビビビ#{i}" } # each has 16 spellings with the ヴ forms
    dictionary = SolrSearch::QueryDictionary.build("#{terms.join(',')}\n")
    uq = request_for('ビビビビ5', searcher_options: {dictionary: dictionary})[:uq]
    assert uq.start_with?('("ビビビビ5"')
    assert_equal SolrSearch::Searcher::MAX_ALTERNATIVES, uq.scan(' OR ').size + 1
  end

  # D-31: the words only in uq; a q that starts with {!...} would drop every clause after the first (cf-d31 round 1)
  def test_query_shape
    r = request_for('議事録 {!lucene}*:*')
    assert_equal 'lucene', r[:defType]
    assert_equal '({!edismax qf=$mainqf v=$uq})', r[:q]
    refute r[:q].start_with?('{!')
    refute_includes r[:q], '議事録'
    assert_nil r[:qf]
  end

  def test_all_words
    assert_equal 'AND', request_for('議事録 会議', all_words: true)[:'q.op']
  end

  def test_vu_ba_expansion_and_the_exact_mode
    assert_equal '("バイオリン" OR "ヴァイオリン")', request_for('バイオリン')[:uq]
    assert_equal '"バイオリン"', request_for('バイオリン', searcher_options: {expand_vu: false})[:uq]
    exact = request_for('バイオリン', exact: true)
    assert_equal '"バイオリン"', exact[:uq]
    assert_equal SolrSearch::Searcher::QF_EXACT, exact[:mainqf]
  end

  # D-48: one result per container by collapse and expand, no Result Grouping
  def test_collapse_and_expand
    r = raw_request_for('議事録')
    assert_equal [PERMISSION, COLLAPSE], r[:fq] # a post filter: after the others
    assert_equal 'true', r[:expand]
    assert_equal SolrSearch::Searcher::GROUP_LIMIT - 1, r[:'expand.rows'] # the kept one and these
    assert_equal 'score desc', r[:'expand.sort']
    assert_empty(r.keys.select {|k| k.to_s.start_with?('group.') || k == :group })
    assert_equal "id,type,item_id#{FL_EXTRA}", r[:fl]
    assert_equal 'id,type,item_id,source,title,url,path,updated_at' + FL_EXTRA,
                 raw_request_for('議事録', sources: %w[src_901])[:fl]
  end

  def test_the_collapse_comes_after_the_narrowing
    r = raw_request_for('議事録', types: %w[issue], project_ids: [3])
    assert_equal COLLAPSE, r[:fq].last
    assert_equal 4, r[:fq].size # permission, type, project, collapse
  end

  def test_snippets
    r = request_for('議事録')
    assert_equal 'unified', r[:'hl.method']
    assert_equal SolrSearch::Searcher::HL_PRE, r[:'hl.tag.pre']
    assert_equal 'false', r[:'hl.weightMatches']
    assert_equal 'id,type,item_id', r[:fl] # no field values: what the screen shows comes from Redmine (D-25)
  end

  # by update the kept document is the newest of the container, and the best hits are chosen among more (D-48)
  def test_sort_by_update_collapses_to_the_newest
    r = raw_request_for('議事録', sort: 'updated')
    assert_equal "{!collapse field=group_id sort='updated_at desc'}", r[:fq].last
    assert_equal SolrSearch::Searcher::GROUP_LIMIT - 1, r[:'expand.rows']
  end

  def test_pages
    assert_equal 0, request_for('議事録')[:start]
    assert_equal 2 * SolrSearch::Searcher::PER_PAGE, request_for('議事録', page: 3)[:start]
    max = SolrSearch::Searcher.max_page(SolrSearch::Searcher::PER_PAGE)
    assert_equal 40, max
    assert_equal (max - 1) * SolrSearch::Searcher::PER_PAGE, request_for('議事録', page: 1_000_000_000)[:start]
    assert_equal 19 * 100, request_for('議事録', page: 1_000_000_000, per_page: 100)[:start], 'the reach is the same, whatever the size'
    assert_equal 1, SolrSearch::Searcher.max_page(5_000), 'a page larger than the reach is the only page'
    assert_equal 0, request_for('議事録', page: -5)[:start]
  end

  def test_sort_by_update
    r = request_for('議事録', sort: 'updated')
    assert_equal 'updated_at desc, id asc', r[:sort]
    assert_nil r[:'group.sort']
    assert_nil request_for('議事録')[:sort]
  end

  def test_narrowing_on_top_of_the_permission_filter
    r = request_for('議事録', types: %w[issue document], project_ids: [3, 5])
    assert_equal [PERMISSION, 'type:(issue OR journal OR document)', "{!terms f=project_id v='3,5'}"], r[:fq]
    assert_equal [PERMISSION, '-*:*'], request_for('議事録', project_ids: [])[:fq]
    assert_equal [PERMISSION], request_for('議事録', types: [], project_ids: nil)[:fq]
  end

  # External sources (design D-33)

  def test_no_sources_no_change
    r = request_for('議事録')
    assert_nil r[:collection]
    assert_equal 'id,type,item_id', r[:fl]
    assert_equal [PERMISSION], r[:fq]
    assert_equal r, request_for('議事録', sources: [])
  end

  def test_sources_are_asked_with_redmine_and_let_through_by_the_first_filter
    r = request_for('議事録', sources: %w[src_902 src_901 src_901])
    assert_equal 'redmine,src_901,src_902', r[:collection]
    assert_equal ["(({!terms f=source v='src_901,src_902'} AND type:file)) OR (#{PERMISSION})"], r[:fq]
    assert_equal 'id,type,item_id,source,title,url,path,updated_at', r[:fl]
  end

  def test_a_name_that_may_not_be_a_source_is_dropped
    odd = "src_x'} OR *:* OR {!terms f=source v='"
    r = request_for('議事録', sources: [odd, 'redmine', 'src_901'])
    assert_equal 'redmine,src_901', r[:collection]
    assert_equal ["(({!terms f=source v='src_901'} AND type:file)) OR (#{PERMISSION})"], r[:fq]
    assert_nil request_for('議事録', sources: [odd, 'redmine'])[:collection] # nothing left: as ever
  end

  def test_the_project_filter_does_not_drop_the_sources
    r = request_for('議事録', project_ids: [3, 5], sources: %w[src_901])
    assert_equal "({!terms f=source v='src_901'}) OR ({!terms f=project_id v='3,5'})", r[:fq].last
    # no project of Redmine's data left, but a source still passes
    assert_equal "{!terms f=source v='src_901'}", request_for('議事録', project_ids: [], sources: %w[src_901])[:fq].last
    assert_equal '-*:*', request_for('議事録', project_ids: [], sources: [])[:fq].last
  end

  def test_types_without_the_external_ones_do_not_ask_the_sources
    r = request_for('議事録', types: %w[issue], sources: %w[src_901])
    assert_nil r[:collection]
    assert_equal [PERMISSION, 'type:(issue OR journal)'], r[:fq]
    assert_equal 'redmine,src_901', request_for('議事録', types: %w[issue external], sources: %w[src_901])[:collection]
    assert_equal 'redmine,src_901', request_for('議事録', types: [], sources: %w[src_901])[:collection]
  end

  def test_a_source_filter_narrows_the_sources_asked_and_the_documents
    r = raw_request_for('議事録', sources: %w[src_901 src_902], source_filter: %w[src_902 src_other])
    assert_equal 'redmine,src_902', r[:collection]
    assert_equal "{!terms f=source v='src_902'}", r[:fq].last(2).first
    # 'redmine' is the value of Redmine's own data
    r = raw_request_for('議事録', sources: %w[src_901], source_filter: %w[redmine])
    assert_nil r[:collection]
    assert_equal "{!terms f=source v='redmine'}", r[:fq].last(2).first
    assert_equal 'redmine,src_901', raw_request_for('議事録', sources: %w[src_901], source_filter: [])[:collection]
  end

  def test_the_external_type
    r = request_for('議事録', types: %w[external], sources: %w[src_901])
    assert_equal 'type:(file)', r[:fq][1]
    r = request_for('議事録', types: %w[issue external], sources: %w[src_901])
    assert_equal 'type:(issue OR journal OR file)', r[:fq][1]
  end

  def test_an_external_document_is_read_with_what_solr_returns
    answer = {
      'response' => {'numFound' => 1, 'docs' => [
        {'id' => 'file://fs/a.docx', 'group_id' => 'file://fs/a.docx', 'type' => 'file', 'source' => 'src_901',
         'title' => 'a.docx', 'url' => 'file://fs/a.docx', 'path' => '\\\\fs\\a.docx', 'updated_at' => '2026-09-04T01:00:00Z'}
      ]},
      'highlighting' => {'file://fs/a.docx' => {'content' => ["\u0002議事録\u0003"]}}
    }
    s, = searcher(answer)
    hit = s.search('議事録', sources: %w[src_901]).groups.first.hits.first
    assert hit.external?
    assert_equal ['src_901', 'a.docx', 'file://fs/a.docx', '\\\\fs\\a.docx', '2026-09-04T01:00:00Z', nil],
                 [hit.source, hit.title, hit.url, hit.path, hit.updated_at, hit.item_id]
    refute SolrSearch::Searcher::Hit.new(type: 'issue').external?
  end

  # The answers come one after the other, an Error among them; keeps every request
  class SequenceClient < FakeClient
    attr_reader :requests

    def initialize(*answers)
      super(nil)
      @answers = answers
      @requests = []
    end

    def select(params)
      @requests << params
      answer = @answers.shift
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  def not_found(name, status = 400)
    SolrSearch::Client::Error.new("Solr POST /solr/redmine/select failed (#{status}): Could not find collection : #{name}", status)
  end

  def sequence(*answers)
    client = SequenceClient.new(*answers)
    s = SolrSearch::Searcher.new(user: nil, client: client)
    s.define_singleton_method(:permission_filter) { PERMISSION }
    [s, client]
  end

  def test_a_collection_solr_does_not_have_is_left_out_and_the_request_sent_again
    s, client = sequence(not_found('src_999'), EMPTY)
    result = s.search('議事録', sources: %w[src_901 src_999])
    assert_equal ['src_999'], result.missing_sources
    assert_equal 2, client.requests.size
    first, second = client.requests
    assert_equal 'redmine,src_901,src_999', first[:collection]
    assert_equal 'redmine,src_901', second[:collection]
    assert_equal ["(({!terms f=source v='src_901'} AND type:file)) OR (#{PERMISSION})", COLLAPSE], second[:fq]
  end

  def test_each_missing_collection_is_left_out_in_turn
    s, client = sequence(not_found('src_998'), not_found('src_999'), EMPTY)
    result = s.search('議事録', sources: %w[src_998 src_999])
    assert_equal %w[src_998 src_999], result.missing_sources
    assert_equal 3, client.requests.size
    assert_nil client.requests.last[:collection] # none left: Redmine's data alone, as ever
    assert_equal [PERMISSION, COLLAPSE], client.requests.last[:fq]
  end

  def test_nothing_missing_nothing_reported
    s, client = sequence(EMPTY)
    assert_equal [], s.search('議事録', sources: %w[src_901]).missing_sources
    assert_equal 1, client.requests.size
  end

  def test_other_failures_are_not_retried
    [not_found('redmine'), not_found('src_999', 500), SolrSearch::Client::Error.new('Solr unreachable', nil),
     SolrSearch::Client::Error.new('Solr failed (400): undefined field foo', 400)].each do |error|
      s, client = sequence(error, EMPTY)
      assert_raises(SolrSearch::Client::Error) { s.search('議事録', sources: %w[src_999]) }
      assert_equal 1, client.requests.size
    end
  end

  def test_a_missing_collection_that_was_not_asked_for_is_not_retried
    s, client = sequence(not_found('src_other'), EMPTY)
    assert_raises(SolrSearch::Client::Error) { s.search('議事録', sources: %w[src_901]) }
    assert_equal 1, client.requests.size
  end

  CF = SolrSearch::CustomFieldQuery::Field

  def test_custom_fields_beside_the_main_clause
    fields = SolrSearch::CustomFieldQuery.new([CF.new(id: 6, project_ids: nil), CF.new(id: 5, project_ids: [1])])
    r = request_for('議事録', custom_fields: fields)
    assert_equal "#{SolrSearch::Searcher::QF} cfj_6 cft_6", r[:mainqf]
    assert_equal "({!edismax qf=$mainqf v=$uq}) OR ({!edismax qf=$cfqf0 v=$uq} AND {!terms f=project_id v='1'})", r[:q]
    assert_equal 'cfj_5 cft_5', r[:cfqf0]
    assert_equal 'title,content,cft_6,cft_5', r[:'hl.fl'] # in the order of the fields
    exact = request_for('議事録', exact: true, custom_fields: fields)
    assert_equal "#{SolrSearch::Searcher::QF_EXACT} cft_6", exact[:mainqf]
    assert_equal 'cft_5', exact[:cfqf0]
  end

  def too_many_clauses
    SolrSearch::Client::Error.new('Solr POST /solr/redmine/select failed (500): too many nested clauses (max 1024)', 500)
  end

  def test_too_many_clauses_with_the_custom_fields_sends_the_search_again_without_them
    fields = SolrSearch::CustomFieldQuery.new([CF.new(id: 6, project_ids: nil), CF.new(id: 5, project_ids: [1])])
    s, client = sequence(too_many_clauses, EMPTY)
    result = s.search('議事録', custom_fields: fields)
    assert result.attributes_dropped
    first, second = client.requests
    assert_includes first[:q], 'cfqf0'
    refute_includes second[:q], 'cfqf0'
    refute_includes second[:mainqf], 'cft_6'
  end

  def test_too_many_clauses_without_the_custom_fields_is_an_error
    s, = sequence(too_many_clauses, EMPTY)
    assert_raises(SolrSearch::Client::Error) { s.search('議事録') }
  end

  def test_the_custom_fields_kept_when_solr_accepts_them
    fields = SolrSearch::CustomFieldQuery.new([CF.new(id: 6, project_ids: nil)])
    s, = sequence(EMPTY)
    refute s.search('議事録', custom_fields: fields).attributes_dropped
  end

  def test_no_custom_fields_no_change
    plain = request_for('議事録')
    assert_equal plain, request_for('議事録', custom_fields: SolrSearch::CustomFieldQuery.new([]))
    assert_nil plain[:cfqf0]
  end

  def test_custom_field_snippets_only_where_they_matched
    answer = {'response' => {'numFound' => 1, 'docs' => [{'id' => 'issue-1', 'group_id' => 'issue-1', 'type' => 'issue', 'item_id' => 1}]},
              'highlighting' => {'issue-1' => {'title' => ['件名'], 'cft_5' => ["\u0002議事録\u0003"], 'cft_6' => ['頭の部分'],
                                          'cft_7' => []}}}
    s, = searcher(answer)
    assert_equal({5 => "\u0002議事録\u0003"}, s.search('議事録').groups.first.hits.first.custom_field_snippets)
  end

  def issue(id, score, **more)
    {'id' => id, 'group_id' => more.delete(:group) || id, 'type' => id.split('-').first, 'item_id' => id.split('-').last.to_i,
     'score' => score}.merge(more.transform_keys(&:to_s))
  end

  def test_answer_read_into_groups_and_hits
    main = {
      'response' => {'numFound' => 2, 'docs' => [issue('issue-12', 3.0), issue('wiki_page-3', 2.0)]},
      'expanded' => {'issue-12' => {'numFound' => 3, 'docs' => [issue('journal-7', 1.0, group: 'issue-12')]}},
      'highlighting' => {'issue-12' => {'title' => ["\u0002議事録\u0003の件"], 'content' => ['説明']}}
    }
    # Solr highlights the kept documents only: the expanded one comes from the second request, the count from the third
    s, client = sequence(main, {'highlighting' => {'journal-7' => {'content' => ["\u0002議事録\u0003を直した"]}}},
                         {'response' => {'numFound' => 5, 'docs' => []}})
    result = s.search('議事録')
    assert_equal [2, 5], [result.group_count, result.hit_count]
    assert_equal %w[issue-12 wiki_page-3], result.groups.map(&:group_id)
    assert_equal [4, 1], result.groups.map(&:hit_count) # the kept one and the 3 others; the kept one alone
    issue, note = result.groups.first.hits
    assert_equal ['issue-12', 'issue', 12, "\u0002議事録\u0003の件", '説明'],
                 [issue.id, issue.type, issue.item_id, issue.title_snippet, issue.content_snippet]
    assert_equal ['journal', 7, nil, "\u0002議事録\u0003を直した"],
                 [note.type, note.item_id, note.title_snippet, note.content_snippet]
    assert_nil result.groups.last.hits.first.content_snippet # no highlighting for it
    assert_nil result.debug
    assert_equal 3, client.requests.size
    _, highlight, count = client.requests
    assert_equal [PERMISSION, 'id:("journal-7")'], highlight[:fq] # the permission filter stays; no collapse
    assert_equal 1, highlight[:rows]
    assert_equal 'true', highlight[:hl]
    assert_equal 0, count[:rows]
    assert_equal [PERMISSION], count[:fq]
    assert_empty(count.keys.select {|k| k.to_s.start_with?('hl') || k.to_s.start_with?('expand')})
  end

  # The expanded documents are scored by the shard alone, the kept one with the merged statistics: no comparing them.
  # The kept document (the newest by update) comes first whatever the scores say, then the expanded ones in Solr's order.
  def test_the_kept_document_is_the_first_hit_whatever_the_scores
    main = {'response' => {'numFound' => 1, 'docs' => [issue('journal-9', 1.0, group: 'issue-1')]},
            'expanded' => {'issue-1' => {'numFound' => 5, 'docs' => [issue('issue-1', 4.0), issue('journal-2', 3.0), issue('journal-3', 2.0)]}}}
    s, = sequence(main, {'highlighting' => {}}, {'response' => {'numFound' => 6}})
    group = s.search('議事録', sort: 'updated').groups.first
    assert_equal %w[journal-9 issue-1 journal-2], group.hits.map(&:id)
    assert_equal 6, group.hit_count
  end

  def test_no_second_request_for_the_snippets_without_expanded_documents
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, {'response' => {'numFound' => 1}})
    s.search('議事録')
    assert_equal 2, client.requests.size # the answer and the count only
  end

  def test_the_ids_of_the_snippets_request_are_quoted
    # an id of an external document can hold commas, spaces and quotes
    odd = 'file://fs/a, "b" (c).docx'
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]},
            'expanded' => {'issue-1' => {'numFound' => 1, 'docs' => [issue(odd, 1.0, group: 'issue-1')]}}}
    s, client = sequence(main, {'highlighting' => {}}, {'response' => {'numFound' => 2}})
    s.search('議事録')
    assert_equal "id:(\"file://fs/a, \\\"b\\\" (c).docx\")", client.requests[1][:fq].last
  end

  def test_nothing_found_no_request_for_the_count
    s, client = sequence(EMPTY)
    result = s.search('議事録')
    assert_equal [0, 0], [result.group_count, result.hit_count]
    assert_equal 1, client.requests.size
  end

  # detail: false is for a caller that wants the order only (the golden sets)
  def test_without_detail_only_the_containers_are_asked_for
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}}
    s, client = sequence(main)
    result = s.search('議事録', per_page: 100_000, detail: false)
    assert_equal ['issue-1'], result.groups.map(&:group_id)
    assert_nil result.hit_count
    assert_equal 1, client.requests.size
    r = client.requests.first
    assert_equal 100_000, r[:rows]
    assert_nil r[:expand]
    assert_empty(r.keys.select {|k| k.to_s.start_with?('hl')})
  end

  # Facets (D-49): the count of hits and the facets come in one request, with the filters tagged

  FACETS = {
    'response' => {'numFound' => 7},
    'facets' => {
      'type_issue' => {'count' => 5, 'containers' => 3}, 'type_wiki_page' => {'count' => 1, 'containers' => 1},
      'type_document' => {'count' => 0}, 'type_attachment' => {'count' => 0}, 'type_external' => {'count' => 1, 'containers' => 1},
      'updated_week' => {'count' => 2, 'containers' => 2}, 'updated_month' => {'count' => 3, 'containers' => 3},
      'updated_year' => {'count' => 5, 'containers' => 4}, 'updated_older' => {'count' => 0},
      'source' => {'buckets' => [{'val' => 'redmine', 'containers' => 4}, {'val' => 'src_901', 'containers' => 1}]},
      'sources_by_project' => {'buckets' => [{'val' => 'redmine', 'containers' => 4}, {'val' => 'src_901', 'containers' => 1},
                                             {'val' => 'src_902', 'containers' => 6}]},
      'projects' => {'buckets' => [{'val' => 3, 'containers' => 2}, {'val' => 5, 'containers' => 1}]},
      'trackers' => {'buckets' => [{'val' => 1, 'containers' => 3}]},
      'authors' => {'buckets' => [{'val' => 7, 'containers' => 2}, {'val' => 8, 'containers' => 1}]},
      'assignees' => {'buckets' => []},
      'statuses' => {'buckets' => [{'val' => 1, 'containers' => 3}, {'val' => 5, 'containers' => 1}]},
      'file_types' => {'buckets' => [{'val' => 'pdf', 'containers' => 4}, {'val' => 'docx', 'containers' => 1}]},
      'folders' => {'buckets' => [{'val' => 'file://fs/a', 'containers' => 5}]},
      'priorities' => {'buckets' => []}, 'versions' => {'buckets' => [{'val' => 12, 'containers' => 2}]}, 'categories' => {'buckets' => []}
    }
  }.freeze

  def test_facets_are_read_and_the_count_of_hits_comes_with_them
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, FACETS)
    result = s.search('議事録', sources: %w[src_901], facets: true)
    assert_equal 7, result.hit_count
    assert_equal({'issue' => 3, 'wiki_page' => 1, 'document' => 0, 'attachment' => 0, 'external' => 1}, result.facets[:types])
    assert_equal({'redmine' => 4, 'src_901' => 1}, result.facets[:sources])
    assert_equal({'redmine' => 4, 'src_901' => 1, 'src_902' => 6}, result.facets[:sources_by_project])
    assert_equal [[3, 2], [5, 1]], result.facets[:projects]
    assert_equal [[1, 3]], result.facets[:trackers]
    assert_equal [[7, 2], [8, 1]], result.facets[:authors]
    assert_equal [], result.facets[:assignees]
    assert_equal [[1, 3], [5, 1]], result.facets[:statuses]
    assert_equal [[12, 2]], result.facets[:versions]
    assert_equal [['pdf', 4], ['docx', 1]], result.facets[:file_types]
    assert_equal [['file://fs/a', 5]], result.facets[:folders]
    assert_equal({'week' => 2, 'month' => 3, 'year' => 4, 'older' => 0}, result.facets[:updated])
    assert_equal 2, client.requests.size # the answer, and the count with the facets
  end

  def test_the_facet_request_leaves_out_each_facets_own_choice
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, FACETS)
    s.search('議事録', types: %w[issue], project_ids: [3], sources: %w[src_901 src_902], source_filter: %w[redmine], facets: true)
    request = client.requests.last
    assert_equal 0, request[:rows]
    assert_nil request[:expand]
    assert_empty(request.keys.select {|k| k.to_s.start_with?('hl')})
    # all the sources are asked, though the types and the source filter leave them out: the facets count them
    assert_equal 'redmine,src_901,src_902', request[:collection]
    tags = request[:fq].select {|f| f.start_with?('{!lucene tag=')}.map {|f| f[/tag=(\w+)/, 1]}
    assert_equal %w[type project source], tags
    assert_includes request[:fq], '{!lucene tag=type}(type:(issue OR journal))'
    definition = JSON.parse(request[:json])['facet']
    assert_equal %w[type_issue type_wiki_page type_document type_attachment type_external updated_week updated_month updated_year
                    updated_older folders source sources_by_project trackers authors assignees statuses priorities versions categories file_types projects], definition.keys
    assert_equal 'type', definition['type_issue']['domain']['excludeTags']
    assert_equal 'source', definition['source']['domain']['excludeTags']
    assert_equal 'project', definition['sources_by_project']['domain']['excludeTags'] # the sources without the choice of projects
    assert_equal 'project', definition['projects']['domain']['excludeTags']
    assert_equal 'tracker_ids', definition['trackers']['domain']['excludeTags'] # the tag of the choice of trackers
    assert_equal 'author_ids', definition['authors']['domain']['excludeTags']
    assert_equal 'assigned_to_ids', definition['assignees']['domain']['excludeTags']
    assert_equal 'updated', definition['updated_week']['domain']['excludeTags']
    assert_equal 'unique(group_id)', definition['projects']['facet']['containers']
    assert_equal SolrSearch::Searcher::FACET_LIMIT, definition['projects']['limit']
    assert_equal 'tracker_id', definition['trackers']['field']
    assert_equal 'status_ids', definition['statuses']['domain']['excludeTags']
    assert_equal 'fixed_version_id', definition['versions']['field']
    assert_equal 'fixed_version_ids', definition['versions']['domain']['excludeTags']
    assert_equal 'file_extension', definition['file_types']['field']
    assert_equal 'file_exts', definition['file_types']['domain']['excludeTags']
    assert_equal 'type:(issue OR journal)', definition['type_issue']['q']
  end

  def test_more_choices_narrow_the_search
    r = request_for('議事録', filters: {updated: 'month', tracker_ids: %w[2 1 x], author_ids: [7], assigned_to_ids: [], status_ids: [3], fixed_version_ids: %w[8 9]})
    assert_includes r[:fq], 'updated_at:[NOW/DAY-1MONTH TO *]'
    assert_includes r[:fq], "{!terms f=tracker_id v='1,2'}"
    assert_includes r[:fq], "{!terms f=author_id v='7'}"
    assert_includes r[:fq], "{!terms f=status_id v='3'}"
    assert_includes r[:fq], "{!terms f=fixed_version_id v='8,9'}"
    ext = request_for('議事録', filters: {file_exts: ['pdf', 'docx', 'DOCX', 'a b', "x'}", 'pdf']})
    assert_includes ext[:fq], "{!terms f=file_extension v='docx,DOCX,Docx,pdf,PDF,Pdf'}" # lower-case letters and digits only; their usual spellings
    refute(r[:fq].any? {|f| f.include?('assigned_to_id')})
    assert_equal [PERMISSION], request_for('議事録', filters: {updated: "x'] OR *:*", tracker_ids: ['1;drop']})[:fq] # nothing else gets in
  end

  def test_the_facet_request_tags_the_more_choices
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, FACETS)
    s.search('議事録', filters: {updated: 'week', tracker_ids: [1]}, facets: true)
    tags = client.requests.last[:fq].select {|f| f.start_with?('{!lucene tag=')}.map {|f| f[/tag=(\w+)/, 1]}
    assert_equal %w[updated tracker_ids], tags
  end

  # D-49: the counts of the projects hold the documents of their sources, whatever projects are chosen
  def test_the_facets_count_the_sources_of_the_other_projects
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, FACETS)
    # a project is chosen: its sources are src_901; the user may search src_902 too
    s.search('議事録', project_ids: [3], sources: %w[src_901], facet_sources: %w[src_901 src_902], facets: true)
    main_request, facet_request = client.requests
    assert_equal 'redmine,src_901', main_request[:collection]
    assert_equal 'redmine,src_901,src_902', facet_request[:collection]
    # the permission filter lets all the sources through; the choice of projects, tagged, only those of the chosen projects
    assert_equal "(({!terms f=source v='src_901,src_902'} AND type:file)) OR (#{PERMISSION})", facet_request[:fq].first
    assert_includes facet_request[:fq], "{!lucene tag=project}(({!terms f=source v='src_901'}) OR ({!terms f=project_id v='3'}))"
  end

  def test_a_folder_is_a_path_that_the_index_has
    depth = SolrSearch::Searcher.method(:folder_depth)
    assert_equal 1, depth.('file://fs/a')
    assert_equal 2, depth.('file://fs/a/b/') # a slash at the end is the same folder
    assert_equal 3, depth.('file:///share/a/b') # a path with no host
    assert_equal 6, depth.('https://h/a/b/c/d/e/f')
    [nil, '', 'file://fs', 'file://fs/', 'file://fs/a/b/c/d/e/f/g', "file://fs/a'b", 'file://fs/a}b', 'file://fs/a b', '/a/b', 5].each do |bad|
      assert_nil depth.(bad), bad.inspect
    end
  end

  def test_a_chosen_folder_narrows_and_the_facet_goes_one_level_down
    r = request_for('議事録', filters: {folder: 'file://fs/部門1/東京/'})
    assert_includes r[:fq], "{!term f=file_dir_2 v='file://fs/部門1/東京'}"
    assert_empty r[:fq].grep(/file_dir_1/)
    assert_equal [PERMISSION], request_for('議事録', filters: {folder: "file://fs/a'b"})[:fq] # nothing else gets in
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    {nil => 'file_dir_1', 'file://fs/a' => 'file_dir_2', 'file://fs/a/b/c/d/e' => 'file_dir_6'}.each do |folder, field|
      s, client = sequence(main, FACETS)
      s.search('議事録', filters: {folder: folder}, facets: true)
      folders = JSON.parse(client.requests.last[:json])['facet']['folders']
      assert_equal field, folders['field'], folder.inspect
      refute folders.key?('domain'), 'the chosen folder stays: the folders below it are counted within it'
    end
    s, client = sequence(main, FACETS)
    s.search('議事録', filters: {folder: 'file://fs/a/b/c/d/e/f'}, facets: true) # the deepest level: nothing below
    refute JSON.parse(client.requests.last[:json])['facet'].key?('folders')
  end

  # Custom fields used as a filter (D-49)
  CustomFacet = Struct.new(:id, :name, :kind, :project_ids, keyword_init: true)
  LIST = CustomFacet.new(id: 4, name: '障害区分', kind: :values, project_ids: nil)
  HIDDEN_LIST = CustomFacet.new(id: 5, name: '社内', kind: :values, project_ids: [2, 9])
  NUMBER = CustomFacet.new(id: 7, name: '工数', kind: :number, project_ids: nil)
  DATE = CustomFacet.new(id: 9, name: '期限', kind: :date, project_ids: nil)

  def test_custom_field_facets_are_counted_without_their_own_choice_and_only_where_they_are_seen
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    answer = FACETS.merge('facets' => FACETS['facets'].merge(
      'cf_4' => {'buckets' => [{'val' => 'A', 'containers' => 3}, {'val' => 'B, C', 'containers' => 1}]},
      'cf_5' => {'buckets' => []},
      'cf_7' => {'count' => 2, 'min' => 1.5, 'max' => 40.0}, 'cf_9' => {'count' => 0}
    ))
    s, client = sequence(main, answer)
    result = s.search('議事録', facets: true, custom_facets: [LIST, HIDDEN_LIST, NUMBER, DATE])
    definition = JSON.parse(client.requests.last[:json])['facet']
    assert_equal({'type' => 'terms', 'field' => 'cfs_4', 'limit' => SolrSearch::Searcher::FACET_LIMIT, 'sort' => {'containers' => 'desc'},
                  'domain' => {'excludeTags' => 'cf_4'}, 'facet' => {'containers' => 'unique(group_id)'}}, definition['cf_4'])
    assert_equal({'excludeTags' => 'cf_5', 'filter' => "{!terms f=project_id v='2,9'}"}, definition['cf_5']['domain']) # only where seen
    assert_equal 'cfn_7:[* TO *]', definition['cf_7']['q']
    assert_equal({'min' => 'min(cfn_7)', 'max' => 'max(cfn_7)'}, definition['cf_7']['facet'])
    assert_equal 'min(cfd_9)', definition['cf_9']['facet']['min']
    assert_equal({4 => {values: [['A', 3], ['B, C', 1]]}, 5 => {values: []}, 7 => {min: 1.5, max: 40.0}, 9 => {min: nil, max: nil}},
                 result.facets[:custom])
  end

  def test_the_choices_of_custom_fields_narrow_the_search
    r = request_for('議事録', custom_facets: [LIST, HIDDEN_LIST, NUMBER, DATE],
                              custom_filters: {4 => {values: ['A', "it's", 'a\\b']}, 5 => {values: ['x']}, 7 => {min: '1.5', max: ''},
                                               9 => {from: '2026-10-01', to: '2026-10-31'}})
    assert_includes r[:fq], "({!term f=cfs_4 v='A'} OR {!term f=cfs_4 v='it\\'s'} OR {!term f=cfs_4 v='a\\\\b'})" # quotes and backslashes escaped
    assert_includes r[:fq], "(({!term f=cfs_5 v='x'}) AND {!terms f=project_id v='2,9'})" # a hidden field: only where it is seen
    assert_includes r[:fq], 'cfn_7:[1.5 TO *]'
    assert_includes r[:fq], 'cfd_9:[2026-10-01T00:00:00Z TO 2026-10-31T23:59:59Z]'
  end

  def test_a_choice_for_a_custom_field_the_user_does_not_see_is_dropped_and_bad_numbers_and_dates_too
    r = request_for('議事録', custom_facets: [NUMBER, DATE], custom_filters: {4 => {values: ['A']}, 7 => {min: 'x', max: 'Infinity'},
                                                                           9 => {from: 'tomorrow', to: '2026-13-45'}})
    assert_equal [PERMISSION], r[:fq]
  end

  def test_the_facet_request_tags_the_choice_of_a_custom_field
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, FACETS)
    s.search('議事録', facets: true, custom_facets: [LIST], custom_filters: {4 => {values: ['A']}})
    assert_includes client.requests.last[:fq], "{!lucene tag=cf_4}(({!term f=cfs_4 v='A'}))"
  end

  # The tuning of the order (D-51)
  def tuned(changes)
    SolrSearch::Tuning.normalize(changes)
  end

  def test_a_search_never_tuned_sends_the_query_it_always_sent
    r = request_for('議事録')
    assert_equal SolrSearch::Searcher::QF, r[:mainqf]
    refute r.key?(:boost)
    refute r.key?(:pf2)
  end

  def test_the_tuning_changes_the_weights_the_bonus_and_the_boost
    r = request_for('議事録', searcher_options: {tuning: tuned('qf' => {'title_ja' => 5}, 'pf2' => 2, 'types' => {'external' => 0.5})})
    assert_equal 'title_ja^5 content_ja^2 title content', r[:mainqf]
    assert_equal 'title_ja^2 content_ja^2', r[:pf2]
    assert_equal "if(query({!v='type:(file)'}),0.5,1)", r[:boost]
    exact = request_for('議事録', exact: true, searcher_options: {tuning: tuned('qf' => {'title_ja' => 5}, 'pf2' => 2, 'types' => {'external' => 0.5})})
    assert_equal SolrSearch::Searcher::QF_EXACT, exact[:mainqf] # the exact string search has its own fields
    refute exact.key?(:pf2)
    assert_equal "if(query({!v='type:(file)'}),0.5,1)", exact[:boost] # but what a type or a source weighs it keeps
  end

  def test_the_count_and_the_facets_do_not_carry_the_weights
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s = SolrSearch::Searcher.new(user: nil, client: (client = SequenceClient.new(main, FACETS)),
                                 tuning: tuned('pf2' => 1, 'recency' => {'strength' => 1}))
    s.define_singleton_method(:permission_filter) { PERMISSION }
    s.search('議事録', facets: true)
    main_request, facet_request = client.requests
    assert main_request.key?(:boost)
    assert main_request.key?(:pf2)
    refute facet_request.key?(:boost)
    refute facet_request.key?(:pf2)
  end

  def test_the_scores_when_asked_for
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.5)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, {'response' => {'numFound' => 1}})
    assert_equal 2.5, s.search('議事録', scores: true).groups.first.hits.first.score
    assert client.requests.first[:fl].end_with?(',score')
    s, client = sequence(main, {'response' => {'numFound' => 1}})
    s.search('議事録')
    refute client.requests.first[:fl].end_with?(',score')
  end

  def test_no_facets_unless_asked_for
    main = {'response' => {'numFound' => 1, 'docs' => [issue('issue-1', 2.0)]}, 'highlighting' => {'issue-1' => {}}}
    s, client = sequence(main, {'response' => {'numFound' => 1}})
    assert_nil s.search('議事録').facets
    assert_nil client.requests.last[:json]
  end

  def test_facets_even_when_nothing_is_found
    s, client = sequence(EMPTY, FACETS)
    result = s.search('議事録', facets: true) # what the other choices would give is worth showing
    assert_equal 0, result.group_count
    assert_equal 7, result.hit_count
    assert_equal 2, client.requests.size
  end

  def test_debug_for_admins
    s, client = searcher(EMPTY.merge('responseHeader' => {'QTime' => 3}, 'debug' => {'parsedquery_toString' => 'P'}),
                         debug: true)
    result = s.search('議事録')
    assert_equal 'query', client.request[:debug]
    assert_equal({url: 'http://solr/select?...', qtime: 3, parsed: 'P'}, result.debug)
  end
end
