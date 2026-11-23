# frozen_string_literal: true

module SolrSearch
  # What the admin page shows (design D-28): where Solr is, whether it answers, how many documents of each type the
  # database and the "redmine" collection have, and what each replica's searches see.
  class Status
    Row = Struct.new(:type, :db, :solr, keyword_init: true)
    # num_docs, newest: what a search on that replica alone sees (committed documents; newest is the latest
    # updated_at among them). nil when the replica does not answer. flag: see Status.flag.
    Replica = Struct.new(:core, :node, :state, :leader, :num_docs, :newest, :flag, keyword_init: true)

    # The page only looks: a Solr that hangs, or a node that is down, must not hold it for long. The read timeout is
    # the plugin setting; the connection is given at most CONNECT_TIMEOUT (a node in the same network either connects
    # at once or is down).
    CONNECT_TIMEOUT = 2

    # The client every admin-side screen uses (admin page, source pages, a project's settings tab)
    def self.admin_client
      Client.from_env(SolrSearch.collection, read_timeout: Settings.seconds('admin_timeout'),
                                  open_timeout: [Settings.seconds('admin_timeout'), CONNECT_TIMEOUT].min)
    end

    # replicas_error: why the replica table could not be read (the collection itself answered); nil when it was read
    # check: what CollectionCheck found (the collection there, its schema as expected); counts and replicas only when ok
    attr_reader :url, :error, :rows, :replicas, :replicas_error, :qtime, :check

    def initialize(client: nil)
      @client = client || self.class.admin_client
      @url = @client.collection_url
      @rows = []
      @replicas = []
      load
    end

    def connected?
      @error.nil?
    end

    # Solr answers, the collection is there and its schema is as expected: the counts below are those of the index
    def ready?
      @check&.ok? || false
    end

    # Marks the replicas whose searches see other documents than the others' (M1 review A5): :no_response when it
    # does not answer; :behind when its newest document is older than another's; :count_differs, on each of them, when
    # those with the newest document see different numbers (which is right cannot be told: a replica that missed
    # deletions has more documents, not fewer). nil: nothing to report.
    def self.flag(replicas)
      answering = replicas.select(&:num_docs)
      newest = answering.filter_map(&:newest).max
      counts_differ = answering.select {|r| r.newest == newest}.map(&:num_docs).uniq.size > 1
      replicas.each do |r|
        r.flag = if r.num_docs.nil? then :no_response
                 elsif r.newest != newest then :behind
                 elsif counts_differ then :count_differs
                 end
      end
    end

    private

    def load
      @check = CollectionCheck.call(@client)
      @error = @check.error if @check.state == :unreachable
      return unless @check.ok?

      res = @client.select(q: '*:*', rows: 0, fq: "source:#{SOURCE}", facet: 'true', 'facet.field': 'type')
      @qtime = res.dig('responseHeader', 'QTime')
      solr = Hash[*res.dig('facet_counts', 'facet_fields', 'type')]
      @rows = Indexer.all_types.map {|type| Row.new(type: type, db: Indexer.scope(type).count, solr: solr[type].to_i)}
      @replicas = self.class.flag(load_replicas)
    rescue Client::Error => e
      @error = e.message
    end

    # The replicas come from CLUSTERSTATUS through the same base URL as searches (design Q-6: the admin path must stay
    # open to Redmine). If it fails, the page says so rather than showing an empty table (M1 review D5).
    # Each replica on its own (a search with distrib=false on its core): a stopped leader stays "active" in ZooKeeper,
    # so what its searches see is what shows it. Luke's "current" and "lastModified" are not used: with commitWithin
    # and autoCommit (openSearcher=false) they say little about what searches see (docs/solr-knowhow.md, chapter 9).
    def load_replicas
      shards = @client.cluster_status.dig('cluster', 'collections', @client.collection, 'shards') || {}
      shards.values.flat_map {|shard| shard['replicas'].values}.map do |r|
        seen = replica_view(r['base_url'], r['core'])
        Replica.new(core: r['core'], node: r['node_name'], state: r['state'], leader: r['leader'] == 'true',
                    num_docs: seen&.dig('numFound'),
                    newest: (time = seen&.dig('docs', 0, 'updated_at')) && Time.zone.parse(time))
      end
    rescue Client::Error => e
      @replicas_error = e.message
      []
    end

    # {numFound, docs: [the newest document]} as a search on this core alone sees it; nil when it does not answer
    def replica_view(base_url, core)
      # base_url and core come from Solr's own answer; they are used as an address only when they look like one (a
      # misconfigured or odd answer must not make this page ask some other place: Gemini, Sec-3)
      return nil unless core.to_s.match?(SolrSearch::COLLECTION_NAME) && (SolrUrl.normalize(base_url) rescue nil)

      core_client = Client.new(base_url, core, read_timeout: @client.read_timeout, open_timeout: @client.open_timeout)
      core_client.select(q: '*:*', distrib: 'false', rows: 1, fl: 'updated_at', sort: 'updated_at desc')['response']
    rescue Client::Error
      nil
    end
  end
end
