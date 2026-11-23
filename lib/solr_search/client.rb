# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module SolrSearch
  # Thin wrapper around the Solr HTTP API of one collection (design chapter 7). It knows nothing about Redmine
  # models. The base URL is the load balancer in front of the Solr nodes (design D-23), so one URL is enough.
  class Client
    # Raised when Solr answers with a non-2xx status or cannot be reached. Decide on #status, not on the message:
    # the message of a refused update depends on which node took the request (docs/solr-knowhow.md, chapter 9).
    class Error < StandardError
      attr_reader :status

      def initialize(message, status = nil)
        super(message)
        @status = status
      end
    end

    OPEN_TIMEOUT = 5
    # Characters of Solr's error message kept in Error#message (and so in the log): a refused query can be long
    MESSAGE_LIMIT = 300
    # For the crawl, which sends large batches. The screens pass shorter ones from the plugin settings.
    READ_TIMEOUT = 60

    # The client for the address in use: the one set on the admin page, else the environment variable SOLR_URL (design
    # D-43; e.g. http://solr-lb/solr). collection: e.g. "redmine". read_timeout: seconds to wait for an answer.
    def self.from_env(collection, read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT)
      address = Settings.solr_address or raise Error, 'the Solr address is not set (admin page, or SOLR_URL)'
      new(address.first, collection, read_timeout: read_timeout, open_timeout: open_timeout)
    end

    attr_reader :base_url, :collection, :collection_url, :read_timeout, :open_timeout

    # open_timeout: seconds to wait for the connection
    def initialize(base_url, collection, read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT)
      @base_url = base_url.chomp('/')
      @collection = collection
      @collection_url = "#{@base_url}/#{collection}"
      @read_timeout = read_timeout
      @open_timeout = open_timeout
    end

    # Adds or replaces documents (an array of hashes). Solr commits them within commit_within milliseconds;
    # callers do not commit after every request (design D-22).
    def add(docs, commit_within: 10_000)
      return if docs.empty?

      post_json("update?commitWithin=#{commit_within}", docs)
    end

    def delete_by_ids(ids, commit_within: 10_000)
      return if ids.empty?

      post_json("update?commitWithin=#{commit_within}", {delete: ids})
    end

    # Which of these ids the collection has (real-time get). Unlike a search, it also sees documents not committed
    # yet, so a document sent a moment ago is found too.
    def existing_ids(ids)
      get_docs(ids, fl: 'id').keys
    end

    # {id => stored fields} of the documents the index has among ids (a real-time get, like existing_ids)
    def get_docs(ids, fl:)
      return {} if ids.empty?

      req = Net::HTTP::Post.new(uri('get'))
      req.set_form(form_pairs(ids: ids.join(','), fl: fl, wt: 'json'))
      request(req).dig('response', 'docs').to_h {|doc| [doc['id'], doc]}
    end

    # Every id of the documents matching the filters (committed ones), page by page with cursorMark: sorted on the
    # unique key, so that a long list costs no deep paging. Yields the number of ids read so far after each page that
    # has some.
    def all_ids(fq, rows: 10_000)
      ids = []
      cursor = '*'
      loop do
        res = select(q: '*:*', fq: fq, fl: 'id', sort: 'id asc', rows: rows, cursorMark: cursor)
        docs = res.dig('response', 'docs')
        ids.concat(docs.map {|doc| doc['id']})
        yield ids.size if block_given? && docs.any?
        break if res['nextCursorMark'] == cursor

        cursor = res['nextCursorMark']
      end
      ids
    end

    # An explicit hard commit that opens a new searcher. For the end of a manual full reindex, not for each request.
    def commit
      post_json('update?commit=true', {})
    end

    # params: a hash of Solr request parameters; an array value is sent as a repeated parameter (fq, fl ...).
    # Sent as a form POST, so long queries (many collections or ids) do not hit the URL length limit.
    def select(params)
      request(Net::HTTP::Post.new(uri('select')).tap {|req| req.set_form(form_pairs(params.merge(wt: 'json')))})
    end

    # The names of the collections that Solr has (Collections API LIST)
    def collection_names
      request(Net::HTTP::Get.new(URI("#{@base_url}/admin/collections?action=LIST&wt=json"))).fetch('collections', [])
    end

    # The names of the configsets that Solr has (Configset API LIST)
    def configset_names
      request(Net::HTTP::Get.new(URI("#{@base_url}/admin/configs?action=LIST&wt=json"))).fetch('configSets', [])
    end

    # The names of the fields the index really has documents with, dynamic ones too (Luke: /admin/luke, numTerms=0 so that
    # no terms are read). Luke answers for one core of the collection: enough for one shard (the replicas have the same
    # documents); with more shards, a field only another shard has is not seen (docs/operations.md).
    def field_names
      request(Net::HTTP::Get.new(URI("#{@collection_url}/admin/luke?numTerms=0&wt=json"))).fetch('fields', {}).keys
    end

    # The schema of the collection as Solr has it (Schema API, a read): {"schema" => {fields, dynamicFields, ...}}
    def schema
      request(Net::HTTP::Get.new(URI("#{@collection_url}/schema?wt=json")))
    end

    # The collection's shards and replicas as ZooKeeper sees them (Collections API CLUSTERSTATUS).
    def cluster_status
      request(Net::HTTP::Get.new(URI("#{@base_url}/admin/collections?" +
                                     URI.encode_www_form(action: 'CLUSTERSTATUS', collection: @collection, wt: 'json'))))
    end

    # Every collection with its configset, as ZooKeeper sees them: {name => configset} (the external index sources'
    # checks on the admin page, design D-33)
    def collection_configsets
      res = request(Net::HTTP::Get.new(URI("#{@base_url}/admin/collections?" +
                                           URI.encode_www_form(action: 'CLUSTERSTATUS', wt: 'json'))))
      (res.dig('cluster', 'collections') || {}).transform_values {|c| c['configName'] }
    end

    # The names of the Solr nodes that are up, as ZooKeeper sees them (Collections API CLUSTERSTATUS)
    def live_nodes
      res = request(Net::HTTP::Get.new(URI("#{@base_url}/admin/collections?" +
                                           URI.encode_www_form(action: 'CLUSTERSTATUS', wt: 'json'))))
      res.dig('cluster', 'live_nodes') || []
    end

    # The GET URL equivalent to select(params), for debugging (the request itself is a form POST).
    def select_url(params)
      "#{uri('select')}?#{URI.encode_www_form(form_pairs(params.merge(wt: 'json')))}"
    end

    private

    def post_json(path, body)
      req = Net::HTTP::Post.new(uri(path))
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate(body)
      request(req)
    end

    def request(req)
      u = req.uri
      res = Net::HTTP.start(u.host, u.port, use_ssl: u.scheme == 'https',
                            open_timeout: @open_timeout, read_timeout: @read_timeout) {|http| http.request(req)}
      body = parse(res.body)
      unless res.is_a?(Net::HTTPSuccess)
        msg = body.is_a?(Hash) ? body.dig('error', 'msg') : nil
        detail = (msg || res.body).to_s
        detail = "#{detail[0, MESSAGE_LIMIT]}... (#{detail.size} characters)" if detail.size > MESSAGE_LIMIT
        raise Error.new("Solr #{req.method} #{u.path} failed (#{res.code}): #{detail}", res.code.to_i)
      end
      body
    rescue Net::OpenTimeout => e
      raise Error, "Solr #{req.method} #{req.uri.path} could not connect within #{@open_timeout} s (#{e.class})"
    rescue Net::ReadTimeout => e # connected, but no answer: Solr hangs or the request is too heavy
      raise Error, "Solr #{req.method} #{req.uri.path} did not answer within #{@read_timeout} s (#{e.class})"
    # an SSL error: an https address where Solr speaks http, or a certificate this host does not trust (Gemini review 2026-11-09)
    rescue SystemCallError, IOError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => e
      raise Error, "Solr #{req.method} #{req.uri.path} unreachable: #{e.class}: #{e.message}"
    end

    def parse(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      text
    end

    def uri(path)
      URI("#{@collection_url}/#{path}")
    end

    def form_pairs(params)
      params.flat_map {|key, value| Array(value).map {|v| [key.to_s, v.to_s]}}
    end
  end
end
