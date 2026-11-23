# frozen_string_literal: true

module SolrSearch
  # How the index is, against Redmine, in the Prometheus text format (design D-45): for each type the number of documents in
  # Redmine and in Solr, the newest update in each, how far Solr is behind, and how old its newest document is. It asks Solr, so it
  # is a page of its own (/solr_search/metrics/index), not a part of the one that reads the database alone. render only formats
  # what gather gives it, so that a light test checks it.
  module IndexHealth
    # {type => [what the indexer puts in updated_at, the column of it]}: the newest in Redmine is read from the same value
    # A type that is added to the index and not to the list below has no newest time (left out of the page, like any
    # unknown value), instead of failing the whole page with a KeyError (M6 review 21)
    NO_NEWEST = ->(_scope) { nil }
    NEWEST_IN_REDMINE = {
      'issue' => ->(scope) { scope.maximum('issues.updated_on') },
      'journal' => ->(scope) { scope.maximum('journals.updated_on') },
      'wiki_page' => ->(scope) { scope.joins(:content).maximum('wiki_contents.updated_on') },
      'document' => ->(scope) { scope.maximum('documents.created_on') },
      'attachment' => ->(scope) { scope.maximum('attachments.created_on') }
    }.freeze

    module_function

    # How far Solr is behind: Redmine's newest minus Solr's, never negative; nil when either is not known. In whole seconds: Solr
    # keeps the time of an update to the second, the database to the millisecond, and the same update must not look late.
    def lag(redmine_newest, solr_newest)
      return nil unless redmine_newest && solr_newest

      [redmine_newest.to_i - solr_newest.to_i, 0].max
    end

    # data: {up: true/false (Solr answered), now: Time, types: {type => {redmine_count:, redmine_newest:, solr_count:, solr_newest:}}}.
    # What is not known (Solr did not answer, a type with no document) is left out rather than written as 0.
    def render(data)
      out = []
      types = data[:types]
      gauge(out, 'solr_search_index_up', '1 when Solr answered the check of the index, 0 when it did not', [[{}, data[:up] ? 1 : 0]])
      gauge(out, 'solr_search_index_documents', 'Documents of a type: where is redmine (in the database, in the index scope) or solr',
            types.flat_map {|type, v| [[{type: type, where: 'redmine'}, v[:redmine_count]], [{type: type, where: 'solr'}, v[:solr_count]]] }.reject {|_l, n| n.nil? })
      gauge(out, 'solr_search_index_newest_timestamp_seconds', 'Unix time of the newest update of a type, in Redmine and in Solr',
            types.flat_map {|type, v| [[{type: type, where: 'redmine'}, v[:redmine_newest]], [{type: type, where: 'solr'}, v[:solr_newest]]] }
                 .reject {|_l, t| t.nil? }.map {|labels, t| [labels, t.to_i] })
      gauge(out, 'solr_search_index_lag_seconds', "How far Solr's newest update is behind Redmine's (0: not behind)",
            types.filter_map {|type, v| (seconds = lag(v[:redmine_newest], v[:solr_newest])) && [{type: type}, seconds] })
      gauge(out, 'solr_search_index_newest_age_seconds', "How old Solr's newest document of a type is, now",
            types.filter_map {|type, v| v[:solr_newest] && [{type: type}, [data[:now].to_i - v[:solr_newest].to_i, 0].max] })
      # the custom fields only the index has, with values (D-57); not written when they were not looked for (Solr did not answer)
      if (orphans = data[:orphan_fields])
        gauge(out, 'solr_search_index_deleted_fields', 'Custom fields that Redmine no longer has and the index still has values of',
              [[{}, orphans.size]])
        gauge(out, 'solr_search_index_deleted_field_issues', 'Issues of the index with a value of a custom field that Redmine no longer has (an issue with two such fields counts twice)',
              [[{}, orphans.sum {|field| field[:count] }]])
      end
      out.join("\n") << "\n"
    end

    def gauge(out, name, help, samples)
      return if samples.empty?

      out << "# HELP #{name} #{help}" << "# TYPE #{name} gauge"
      samples.each {|labels, value| out << "#{name}#{Metrics.label_text(labels)} #{Metrics.number(value)}" }
    end

    # The data, from the database and from Solr (one request: the count of each type and its newest updated_at). When Solr
    # does not answer, up is false and what is Solr's is empty.
    def gather(client:, now: Time.current)
      # client: nil when there is no address of Solr at all: Solr that does not answer (M6 review 7)
      solr = client && begin
        facets = client.select(q: '*:*', rows: 0, fq: "source:#{SOURCE}", 'json.facet' => FACET)
                       .dig('facets', 't', 'buckets') || []
        facets.to_h {|b| [b['val'], {count: b['count'], newest: (Time.iso8601(b['newest']) if b['newest'])}] }
      rescue Client::Error
        nil
      end
      types = Indexer.all_types.to_h do |type|
        scope = Indexer.scope(type)
        found = solr && (solr[type] || {count: 0, newest: nil})
        [type, {redmine_count: scope.count, redmine_newest: NEWEST_IN_REDMINE.fetch(type) { NO_NEWEST }.call(scope),
                solr_count: found&.dig(:count), solr_newest: found&.dig(:newest)}]
      end
      # Luke and a count for each: only when Solr answered
      orphans = solr && begin
        ReindexTargets.deleted_fields(client)
      rescue Client::Error
        nil
      end
      {up: !solr.nil?, now: now, types: types, orphan_fields: orphans}
    end

    FACET = '{"t":{"type":"terms","field":"type","limit":50,"facet":{"newest":"max(updated_at)"}}}'
  end
end
