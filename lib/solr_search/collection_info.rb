# frozen_string_literal: true

module SolrSearch
  # What the collections are like at the time of an export of the search log (design D-45): the rows of collections.csv, one
  # fact in each, "long" so that a query can pick what it wants. gather asks Solr and the database; rows only formats what it
  # is given, so that a light test checks it.
  module CollectionInfo
    module_function

    # data: {exported_at:, solr_url:, solr_url_from:, redmine: {name:, configset:, shards:, replicas:, state:, problems:,
    # documents:, counts: {type => [Redmine's, Solr's]}}, externals: [{label:, collection:, configset:, state:, documents:,
    # wrong_source:}]}. Returns [[collection, role, key, value]].
    def rows(data)
      redmine = data[:redmine]
      name = redmine[:name]
      out = [['', 'export', 'exported_at', data[:exported_at]],
             ['', 'export', 'solr_url', data[:solr_url]],
             ['', 'export', 'solr_url_from', data[:solr_url_from]]]
      %i[configset shards replicas state documents].each {|key| out << [name, 'redmine', key.to_s, redmine[key]] }
      out << [name, 'redmine', 'schema_problems', Array(redmine[:problems]).join('; ')]
      redmine[:counts].each do |type, (in_redmine, in_solr)|
        out << [name, 'redmine', "documents_redmine_#{type}", in_redmine]
        out << [name, 'redmine', "documents_solr_#{type}", in_solr]
      end
      data[:externals].each do |source|
        %i[label configset state documents wrong_source].each {|key| out << [source[:collection], 'external', key.to_s, source[key]] }
      end
      out
    end

    # The data, from Solr and the database. A part that Solr does not answer is left empty, with the state saying why. With no
    # address of Solr at all, the whole of Solr's part is empty, and the file is still made: the log is wanted most when the
    # connection is broken (M6 review 7).
    def gather(status: nil)
      name = SolrSearch.collection
      address = Settings.solr_address
      client = begin
        Status.admin_client
      rescue Client::Error
        nil
      end
      status ||= Status.new(client: client) if client
      configsets = client ? rescue_empty({}) { client.collection_configsets } : {}
      shards = client ? rescue_empty({}) { client.cluster_status.dig('cluster', 'collections', name, 'shards') || {} } : {}
      check = status&.check
      counts = status&.ready? ? status.rows.to_h {|row| [row.type, [row.db, row.solr]] } : {}
      {
        exported_at: Time.current, solr_url: address&.first, solr_url_from: address&.last,
        redmine: {name: name, configset: configsets[name], shards: shards.size.nonzero?, replicas: shards.values.sum {|s| s['replicas'].size }.nonzero?,
                  state: check&.state || :unreachable, problems: check ? check.problems.map {|p| "#{p.kind}:#{p.name}" } : [],
                  documents: (rescue_empty(nil) { client.select(q: '*:*', rows: 0, fq: "source:#{SOURCE}").dig('response', 'numFound') } if client),
                  counts: counts},
        externals: externals(client)
      }
    end

    def externals(client)
      sources = SolrSearchSource.order(:name).to_a
      checks = client ? SourceStatus.new(client: client).check(sources) : {}
      sources.map do |source|
        check = checks[source.id]
        {label: source.name, collection: source.collection, configset: check&.configset, state: check&.state, wrong_source: check&.wrong_source,
         documents: (rescue_empty(nil) { Client.new(client.base_url, source.collection, read_timeout: client.read_timeout, open_timeout: client.open_timeout)
                                               .select(q: '*:*', rows: 0).dig('response', 'numFound') } if client)}
      end
    end

    def rescue_empty(empty)
      yield
    rescue Client::Error
      empty
    end
  end
end
