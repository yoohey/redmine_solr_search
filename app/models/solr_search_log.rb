# frozen_string_literal: true

# A search of the search screen (design D-45). Written by SolrSearch::SearchLog.record.
class SolrSearchLog < SolrSearchRecord
  # How many words of a top the admin page shows
  TOP = 20
  # What the list of the search log (and the words beside the dictionary) shows when no period is chosen: the log is kept for ever, and a
  # screen that reads all of it grows slower as it grows (M6 review 10)
  DEFAULT_DAYS = 30

  # The words that were searched most often among the searches of a relation, most first, with how many times: {word (lower case) => times}
  def self.top(relation)
    relation.group('LOWER(query)').order(Arel.sql('COUNT(*) DESC')).limit(TOP).count
  end

  # The words of the searches that did not help: [no result, a result and nothing opened] (design D-45). first_pages: the first pages of
  # the searches of a period.
  def self.tops(first_pages)
    [top(first_pages.where(hit_count: 0, error: nil)), top(first_pages.where('hit_count > 0').where(clicked_at: nil))]
  end

  # a search that Solr answered with nothing
  def zero?
    error.nil? && hit_count == 0 # rubocop:disable Style/NumericPredicate
  end
end
