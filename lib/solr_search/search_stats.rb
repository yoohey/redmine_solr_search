# frozen_string_literal: true

module SolrSearch
  # What a search, and a click on its results, add to the counts that Prometheus reads (design D-45). Pure: it says which
  # counts to add to and by how much; Counters does the adding. The histograms are kept as the number in each bucket (not
  # cumulative); Metrics makes them cumulative when it writes them, as Prometheus wants.
  module SearchStats
    # the buckets, in the unit the log keeps: milliseconds for the time, a count for the hits, a place for the rank
    DURATION_MS = [25, 50, 100, 250, 500, 1000, 2500, 5000, 10_000].freeze
    HITS = [0, 1, 5, 20, 100, 1000].freeze
    RANK = [1, 2, 3, 5, 10, 20, 50].freeze
    CLICK_KINDS = SolrSearch::Clicks::KINDS

    module_function

    # The key of the bucket that a value falls in: the smallest bound that is not less than it, or inf
    def bucket_key(prefix, bounds, value)
      "#{prefix}:le:#{bounds.find {|bound| value <= bound } || 'inf'}"
    end

    # [[key, n]] for one search (a page of results): result is found, zero or failed. Only the first page is a search of its
    # own (a page 2 is the same search going on), so only it counts in the searches and in the hits; every page that Solr
    # answered counts in the time, and in the groups that Redmine's checks did not show.
    def search_increments(page:, hit_count:, took_ms:, dropped_count:, error:)
      out = []
      result = error ? 'failed' : (hit_count.to_i.zero? ? 'zero' : 'found')
      out << ["searches:#{result}", 1] if page == 1
      return out if error

      out << [bucket_key('duration', DURATION_MS, took_ms.to_i), 1] << ['duration:sum_ms', took_ms.to_i] << ['duration:count', 1]
      if page == 1
        out << [bucket_key('hits', HITS, hit_count.to_i), 1] << ['hits:sum', hit_count.to_i] << ['hits:count', 1]
      end
      out << ['dropped_groups', dropped_count] if dropped_count.to_i.positive?
      out
    end

    # [[key, n]] for one click. first_click: it is the first click of a first page's search (a search that found something
    # and had something opened: the other side of the searches that did not help).
    def click_increments(kind:, rank:, first_click:)
      kind = CLICK_KINDS.include?(kind) ? kind : 'other'
      out = [['clicks:total', 1], ["clicks:kind:#{kind}", 1]]
      out << ['searches_with_click', 1] if first_click
      if rank
        out << [bucket_key('click_rank', RANK, rank), 1] << ['click_rank:sum', rank] << ['click_rank:count', 1]
      end
      out
    end
  end
end
