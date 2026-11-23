# frozen_string_literal: true

require_relative '../light_helper'

# The optional external reranker (design D-56): the request, the reading of the answer, the failures
class RerankerTest < Minitest::Test
  R = SolrSearch::Reranker

  def reranker(format: 'tei', answer: nil, **options)
    seen = []
    http = ->(uri, body, headers, timeout) { seen << [uri.to_s, JSON.parse(body), headers, timeout]; answer.respond_to?(:call) ? answer.call : answer }
    [R.new(url: 'http://rerank:8080', format: format, http: http, **options), seen]
  end

  def test_tei_asks_with_the_query_and_the_texts_and_reads_a_list
    r, seen = reranker(answer: '[{"index":1,"score":0.9},{"index":0,"score":0.1}]')
    assert_equal [0.1, 0.9], r.scores('議事録', %w[a b])
    uri, body, headers, timeout = seen.first
    assert_equal 'http://rerank:8080/rerank', uri
    assert_equal({'query' => '議事録', 'texts' => %w[a b], 'truncate' => true}, body)
    assert_equal 'application/json', headers['Content-Type']
    assert_equal 3, timeout
  end

  def test_a_long_list_goes_in_parts_that_the_service_takes_and_the_scores_come_back_in_order
    sizes = []
    http = lambda do |_uri, body, _h, _t|
      texts = JSON.parse(body)['texts']
      sizes << texts.size
      JSON.generate(texts.each_index.map {|i| {index: i, score: texts[i].to_f} })
    end
    r = R.new(url: 'http://x', http: http)
    assert_equal (1..70).map(&:to_f), r.scores('q', (1..70).map(&:to_s))
    assert_equal [32, 32, 6], sizes
    sizes.clear
    R.new(url: 'http://x', format: 'cohere', http: ->(_u, body, _h, _t) { sizes << JSON.parse(body)['documents'].size; JSON.generate(results: JSON.parse(body)['documents'].each_index.map {|i| {index: i, relevance_score: 1} }) }).scores('q', (1..70).map(&:to_s))
    assert_equal [70], sizes
  end

  def test_the_tei_address_may_already_end_with_rerank
    assert_equal 'http://x/rerank', R.new(url: 'http://x/rerank').endpoint
    assert_equal 'http://x/rerank', R.new(url: 'http://x/').endpoint
    assert_equal 'http://x/rerank', R.new(url: 'http://x/rerank/').endpoint # the slash at the end is not kept
    assert_equal 'http://x/v1/rerank', R.new(url: 'http://x/v1/rerank', format: 'cohere').endpoint
  end

  def test_cohere_asks_with_the_model_and_the_documents_and_reads_results
    r, seen = reranker(format: 'cohere', model: 'rerank-v3', answer: '{"results":[{"index":0,"relevance_score":0.2},{"index":1,"relevance_score":0.7}],"id":"x"}')
    assert_equal [0.2, 0.7], r.scores('q', %w[a b])
    assert_equal({'model' => 'rerank-v3', 'query' => 'q', 'documents' => %w[a b], 'top_n' => 2}, seen.first[1])
  end

  def test_the_key_is_sent_as_a_bearer_token_when_there_is_one
    seen = []
    http = ->(_uri, _body, headers, _t) { seen << headers; '[{"index":0,"score":1}]' }
    R.new(url: 'http://x', key: 'secret', http: http).scores('q', %w[a])
    assert_equal 'Bearer secret', seen.first['Authorization']
    seen.clear
    R.new(url: 'http://x', http: http).scores('q', %w[a])
    refute seen.first.key?('Authorization')
  end

  def test_nothing_to_score_makes_no_request
    r, seen = reranker(answer: '[]')
    assert_equal [], r.scores('q', [])
    assert_empty seen
  end

  def test_an_answer_that_is_not_an_answer_to_the_request_is_an_error
    [['not json', 'tei'], ['{"error":"x"}', 'tei'], ['[{"index":0}]', 'tei'], ['[{"index":5,"score":1}]', 'tei'],
     ['[{"index":0,"score":"a"}]', 'tei'], ['[{"index":0,"score":1}]', 'tei'], ['{"results":[]}', 'cohere'], ['[]', 'cohere']].each do |body, format|
      r, = reranker(format: format, answer: body)
      assert_raises(R::Error, body) { r.scores('q', %w[a b]) }
    end
  end

  def test_a_failed_call_is_an_error_of_this_class
    r = R.new(url: 'http://x', http: ->(*) { raise Errno::ECONNREFUSED })
    error = assert_raises(R::Error) { r.scores('q', %w[a]) }
    assert_match(/ECONNREFUSED/, error.message)
    r = R.new(url: 'http://x', http: ->(*) { raise Timeout::Error })
    assert_raises(R::Error) { r.scores('q', %w[a]) }
  end

  def test_from_settings_none_when_there_is_no_usable_address
    assert_nil R.from_settings({})
    assert_nil R.from_settings('reranker_url' => '  ')
    assert_nil R.from_settings('reranker_url' => 'ftp://x')
    assert_nil R.from_settings('reranker_url' => 'not a url')
  end

  def test_from_settings_defaults_and_ranges
    r = R.from_settings('reranker_url' => 'http://x:8080')
    assert_equal ['tei', 3, 40, 400, ''], [r.format, r.timeout, r.docs, r.chars, r.model]
    r = R.from_settings('reranker_url' => 'https://x', 'reranker_format' => 'cohere', 'reranker_model' => ' m ', 'reranker_timeout' => '999',
                        'reranker_docs' => '5', 'reranker_chars' => 'x')
    assert_equal ['cohere', 60, 20, 400, 'm'], [r.format, r.timeout, r.docs, r.chars, r.model]
    assert_equal 'tei', R.from_settings('reranker_url' => 'http://x', 'reranker_format' => 'other').format
  end

  def test_an_address_with_a_user_or_a_fragment_is_not_usable
    assert R.usable_url?('http://tei:8080')
    refute R.usable_url?('http://user:secret@tei:8080')
    refute R.usable_url?('http://tei:8080/#x')
  end
end
