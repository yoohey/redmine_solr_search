# frozen_string_literal: true

module SolrSearch
  class Searcher
    # The external reranker's part of a search (design D-56, Q-24): the first containers by relevance are put in the order that the reranker gave, and the page is cut from that order. Moved here from Searcher; nothing changed.
    module Reranking
      private

      # The request of the results; with an external reranker (design D-56), the page that lies in its window is made of the
      # containers in the order that the reranker gave. => [the answer of Solr, what the reranker did or nil]
      #   1. the first `window` containers by relevance, with a snippet each (a request of its own)
      #   2. the reranker scores their texts (the title and the snippet)
      #   3. the page, taken from that order: its containers are asked for again as the page always is (with the other hits and
      #      the snippets), by their group ids, and put in that order
      # The count of containers is that of the first request. A reranker that fails leaves the order to Solr.
      def select_results(request, text, page, per_page, sort, detail)
        return [@client.select(request), nil] unless rerank_page?(sort, page, per_page, detail)

        window = rerank_window(per_page)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        first = @client.select(window_request(request, window))
        docs = first.dig('response', 'docs')
        return [@client.select(request), nil] if docs.size < 2

        highlighting = first['highlighting'] || {}
        scores = @reranker.scores(text, docs.map {|d| rerank_text(d, highlighting[d['id']] || {})})
        order = docs.each_index.sort_by {|i| [-scores[i], i]}.map {|i| docs[i]['group_id']}
        ids = order[(page - 1) * per_page, per_page] || []
        return [@client.select(request), nil] if ids.empty?

        res = @client.select(request.merge(fq: [*Array(request[:fq]), "group_id:(#{ids.map {|id| self.class.phrase(id)}.join(' OR ')})"],
                                           rows: ids.size, start: 0))
        by_id = res.dig('response', 'docs').to_h {|d| [d['group_id'], d]}
        res['response'] = res['response'].merge('docs' => ids.filter_map {|id| by_id[id]}, 'numFound' => first.dig('response', 'numFound'))
        [res, {used: true, milliseconds: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round, window: docs.size}]
      rescue Reranker::Error => e
        Rails.logger&.warn("redmine_solr_search: the reranker failed, the order is Solr's: #{e.message}") if defined?(Rails) && Rails.respond_to?(:logger)
        [@client.select(request), {used: false, error: e.message}]
      end

      # By relevance, for the screen (the snippets are the texts), and when the page lies in the window
      def rerank_page?(sort, page, per_page, detail)
        @reranker && detail && sort == 'relevance' && page * per_page <= rerank_window(per_page)
      end

      # How many containers are put in order: the setting, rounded up to whole pages
      def rerank_window(per_page)
        ((@reranker.docs.to_f / per_page).ceil * per_page)
      end

      # The first request, as the page's but for the window: no other hits, a snippet as long as the reranker takes
      def window_request(request, window)
        request.reject {|k, _| k.to_s.start_with?('expand') || k == :debug}
               .merge(rows: window, start: 0, 'hl.fragsize': @reranker.chars)
      end

      # The title and the snippet, as plain text (the markers of the highlights taken off), no longer than the reranker takes
      def rerank_text(doc, hl)
        parts = [Array(hl['title']).first, Array(hl['content']).first].map {|s| s.to_s.delete("#{HL_PRE}#{HL_POST}").strip}
        parts.reject(&:empty?).join("\n")[0, @reranker.chars]
      end
    end
  end
end
