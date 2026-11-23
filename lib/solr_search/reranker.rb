# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module SolrSearch
  # The optional external reranker (design D-56, Q-24 case C): a service that is given the query and the texts of the first
  # containers and answers a score for each. Two ways of calling it, both checked against the services' own descriptions:
  #   tei     POST <url>/rerank  {"query": q, "texts": [...], "truncate": true}  =>  [{"index": 0, "score": 0.9}, ...]
  #           (Hugging Face Text Embeddings Inference; the address may already end with /rerank)
  #   cohere  POST <url>  {"model": m, "query": q, "documents": [...], "top_n": n}  =>  {"results": [{"index": 2, "relevance_score": 0.8}, ...]}
  #           (Cohere's /v2/rerank; Jina, Infinity, vLLM and others answer in the same form; the address is the whole one)
  # What this class holds is the building of the request and the reading of the answer (no database, no Rails: test/unit) and
  # the call. The key, if the service wants one, is the environment variable RERANKER_API_KEY, never a saved setting.
  class Reranker
    class Error < StandardError; end

    FORMATS = %w[tei cohere].freeze
    KEY_ENV = 'RERANKER_API_KEY'
    # How many texts one request holds: TEI refuses more than 32 by default (422, "batch size 33 > maximum allowed batch size 32"); Cohere
    # recommends 1,000 at most. A cross-encoder scores each text with the query by itself, so the scores of the parts are comparable.
    BATCH = {'tei' => 32, 'cohere' => 1_000}.freeze
    DOCS = (20..100)
    CHARS = (100..2000)
    TIMEOUT = (1..60)

    attr_reader :url, :format, :model, :timeout, :docs, :chars

    # The reranker that the settings describe, or nil when there is none (no address, or one that is not http(s)).
    # settings: anything that answers [] for the names of the plugin's settings (SolrSearch::Settings)
    def self.from_settings(settings)
      url = settings['reranker_url'].to_s.strip
      return nil unless usable_url?(url)

      format = settings['reranker_format'].to_s
      new(url: url, format: FORMATS.include?(format) ? format : FORMATS.first, model: settings['reranker_model'].to_s.strip,
          timeout: clamp(settings['reranker_timeout'], TIMEOUT, 3), docs: clamp(settings['reranker_docs'], DOCS, 40),
          chars: clamp(settings['reranker_chars'], CHARS, 400), key: ENV[KEY_ENV].presence)
    end

    def self.usable_url?(url)
      uri = URI.parse(url)
      # no user and password in the address (the key goes by RERANKER_API_KEY, not into the database: D-56), no fragment
      uri.is_a?(URI::HTTP) && uri.host.to_s != '' && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    # A number outside the range is its nearest end; one that is no number (or blank) is the default
    def self.clamp(value, range, default)
      (Integer(value.to_s, 10, exception: false) || default).clamp(range)
    end

    def initialize(url:, format: 'tei', model: '', timeout: 3, docs: 40, chars: 400, key: nil, http: nil)
      @url = url
      @format = format
      @model = model
      @timeout = timeout
      @docs = docs
      @chars = chars
      @key = key
      @http = http # for the tests: anything that answers call(uri, body, headers, timeout) => the text of the answer
    end

    # The address that is called
    def endpoint
      return url unless format == 'tei'

      stripped = url.sub(%r{/+\z}, '')
      stripped.end_with?('/rerank') ? stripped : "#{stripped}/rerank"
    end

    # The body of the request, as a Hash (it is sent as JSON)
    def request_body(query, texts)
      case format
      when 'cohere'
        {model: model, query: query, documents: texts, top_n: texts.size}
      else
        {query: query, texts: texts, truncate: true}
      end
    end

    # One score for each text, in the order of the texts (a higher score is better). Raises Error for anything that is not an
    # answer to this request: no connection, the time, a status that is not a success, an answer that cannot be read, a text
    # without a score, a score that is not a number.
    def scores(query, texts)
      return [] if texts.empty?

      texts.each_slice(BATCH.fetch(format, 32)).flat_map do |part|
        self.class.read(format, call(JSON.generate(request_body(query, part))), part.size)
      end
    end

    # The scores of an answer (the text of it) for count texts
    def self.read(format, body, count)
      data = JSON.parse(body)
      rows = format == 'cohere' ? (data.is_a?(Hash) ? data['results'] : nil) : data
      raise Error, 'the answer is not a list of scores' unless rows.is_a?(Array)

      key = format == 'cohere' ? 'relevance_score' : 'score'
      scores = Array.new(count)
      rows.each do |row|
        index = row.is_a?(Hash) ? row['index'] : nil
        score = row.is_a?(Hash) ? row[key] : nil
        raise Error, 'a row has no index or no score' unless index.is_a?(Integer) && score.is_a?(Numeric)
        raise Error, "the index #{index} is outside the #{count} texts" unless (0...count).cover?(index)

        scores[index] = score.to_f
      end
      raise Error, 'a text has no score' if scores.any?(&:nil?)

      scores
    rescue JSON::ParserError => e
      raise Error, "the answer is not JSON: #{e.message[0, 80]}"
    end

    private

    def call(json)
      headers = {'Content-Type' => 'application/json', 'Accept' => 'application/json'}
      headers['Authorization'] = "Bearer #{@key}" if @key
      uri = URI.parse(endpoint)
      return @http.call(uri, json, headers, timeout) if @http

      http_call(uri, json, headers)
    rescue Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "#{e.class}: #{e.message[0, 120]}"
    end

    def http_call(uri, json, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = timeout
      http.read_timeout = timeout
      response = http.post(uri.request_uri, json, headers)
      raise Error, "status #{response.code}: #{response.body.to_s[0, 160]}" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s
    end
  end
end
