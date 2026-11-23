# frozen_string_literal: true

module SolrSearch
  # The golden query sets (design D-45): how the search does against what is known to be right.
  #   coverage (A): from the seed's expected.yml, for each word and user, every container the user may see that holds the
  #                 word: recall (found of what should be), precision (right of what was found), leaks (found, not visible)
  #   ranking  (B): golden.yml, written by hand: for a query and a user, the containers that should come in the first K
  #                 places: MRR and the share found in the first K
  # What is compared is a container: one row of the list (an issue with its notes and attachments, a wiki page, a
  # document), as in Group#group_id ("issue-12"). This file holds the arithmetic and the reading of the files, which need
  # neither Rails nor Solr (test/unit/golden_test.rb); Runner makes the searches.
  module Golden
    DEFAULT_K = 5
    # How many of what went wrong are kept in a run's details
    DETAIL_LIMIT = 30

    class Invalid < StandardError; end

    # "issue#12", "journal#3@issue#12", "attachment#7@wiki#4", "wiki#2", "document#9" => the container's group id, or nil
    # for what the search does not look in by default: an issue's custom fields are searched only when asked for ("include
    # attributes", D-31), so a word that only a custom field holds is not expected from the default search
    def self.container(key)
      case key
      when /\A(?:issue)#(\d+)\z/, /\A(?:journal|attachment)#\d+@issue#(\d+)\z/ then "issue-#{$1}"
      when /\Awiki#(\d+)\z/, /\Aattachment#\d+@wiki#(\d+)\z/ then "wiki_page-#{$1}"
      when /\Adocument#(\d+)\z/, /\Aattachment#\d+@document#(\d+)\z/ then "document-#{$1}"
      end
    end

    # The containers a user should find for one word of expected.yml ({'records' => [{'visible_to' =>, 'ids' =>}]})
    def self.wanted(word_entry, login)
      Array(word_entry['records']).select {|g| g['visible_to'].include?(login)}
                                  .flat_map {|g| g['ids']}.filter_map {|key| container(key)}.uniq
    end

    # One search of set A. want, got: arrays of group ids. => {want:, got:, hit:, leak:, missing:} (the last two are arrays)
    def self.coverage_row(want, got)
      want = want.uniq
      got = got.uniq
      {want: want.size, got: got.size, hit: (want & got).size, leaks: (got - want), missing: (want - got)}
    end

    # The totals of set A over rows of coverage_row. Recall and precision are nil when nothing was to be found, or found:
    # a 0 there would say "all wrong" about a set that asked for nothing.
    def self.coverage_totals(rows)
      want = rows.sum {|r| r[:want]}
      got = rows.sum {|r| r[:got]}
      hit = rows.sum {|r| r[:hit]}
      {expected: want, found: hit, leaks: rows.sum {|r| r[:leaks].size},
       recall: want.zero? ? nil : hit.to_f / want, precision: got.zero? ? nil : hit.to_f / got}
    end

    # The best (smallest) place, from 1, that one of the wanted containers has in the list; nil when none is in it
    def self.best_rank(wanted, got)
      place = wanted.filter_map {|id| got.index(id)}.min
      place && place + 1
    end

    # The totals of set B over rows of {rank: place or nil, top: the places it must be in}: MRR (1 / the place of the
    # first right one, 0 when none is found; the mean over the queries) and the share of queries whose first right one
    # is within its own top. k: the widest top, which names the share.
    def self.ranking_totals(rows)
      return {expected: 0, found: 0, mrr: nil, recall_at_k: nil, k: DEFAULT_K} if rows.empty?

      found = rows.count {|r| r[:rank] && r[:rank] <= r[:top]}
      {expected: rows.size, found: found, k: rows.map {|r| r[:top]}.max,
       mrr: rows.sum {|r| r[:rank] ? 1.0 / r[:rank] : 0.0} / rows.size, recall_at_k: found.to_f / rows.size}
    end

    # golden.yml (an array of {query, user, expect, top, purpose}) => cases with their defaults. user: a login, or
    # "anonymous"; default admin. top: the places the first right one must be in; default DEFAULT_K.
    def self.cases(list)
      raise Invalid, 'golden.yml must be a list' unless list.is_a?(Array)

      list.each_with_index.map do |c, i|
        raise Invalid, "entry #{i + 1}: not a mapping" unless c.is_a?(Hash)

        query = c['query'].to_s.strip
        expect = Array(c['expect']).map(&:to_s)
        raise Invalid, "entry #{i + 1}: query is empty" if query.empty?
        raise Invalid, "entry #{i + 1} (#{query}): expect is empty" if expect.empty?
        unless expect.all? {|id| id.match?(/\A(issue|wiki_page|document)-\d+\z/)}
          raise Invalid, "entry #{i + 1} (#{query}): expect must be like issue-12, wiki_page-3, document-7"
        end

        top = Integer((c['top'].nil? ? DEFAULT_K : c['top']).to_s, 10, exception: false) # 2.5 and 'x' are not places
        raise Invalid, "entry #{i + 1} (#{query}): top must be a whole number of 1 or more" unless top&.positive?

        {query: query, user: (c['user'] || 'admin').to_s, expect: expect, top: top, purpose: c['purpose'].to_s}
      end
    end

    # What is kept of a run that did not go as expected (set A: the rows with a leak or something missing; set B: the
    # queries not found in the first places), the first DETAIL_LIMIT.
    def self.coverage_details(rows)
      rows.select {|r| r[:leaks].any? || r[:missing].any?}.first(DETAIL_LIMIT).map do |r|
        {query: r[:query], user: r[:user], leaks: r[:leaks].first(5), missing_count: r[:missing].size,
         missing: r[:missing].first(5)}
      end
    end

    def self.ranking_details(cases_with_ranks)
      cases_with_ranks.reject {|c| c[:rank] && c[:rank] <= c[:top]}.first(DETAIL_LIMIT).map do |c|
        {query: c[:query], user: c[:user], expect: c[:expect], rank: c[:rank], top: c[:top], first: c[:first]}
      end
    end
  end
end
