# frozen_string_literal: true

module SolrSearch
  # The counts about the searches that Prometheus reads (design D-45), kept in the database apart from the log. add must
  # never fail a search or a click: it is called under SearchLog.record and Clicks.record, which log and go on.
  module Counters
    module_function

    # Adds to a count, whether or not there is a row for it yet, and whatever else is adding at the same time: the addition
    # is done by the database (UPDATE ... SET value = value + n), and a row that two creators both want is created once.
    def add(key, by = 1)
      return if SolrSearchCounter.where(key: key).update_all(['value = value + ?', by]).positive?

      SolrSearchCounter.create!(key: key, value: by)
    rescue ActiveRecord::RecordNotUnique
      SolrSearchCounter.where(key: key).update_all(['value = value + ?', by])
    end

    # The same counts to add, each key once with the sum, in the order of the keys (what add_all does; pure: a light test checks it)
    def merge(increments)
      increments.each_with_object(Hash.new(0)) {|(key, by), sums| sums[key] += by }.sort.to_a
    end

    # {key => value} of all of them
    def all
      SolrSearchCounter.pluck(:key, :value).to_h
    end

    # Adds a list of [key, n] in one transaction: one commit for the whole search or click, not one for each count (a search
    # added to 6 to 9 counts, each its own commit, on the search's own time: M6 review 9). The same key is added once; the
    # rows are updated in the order of their keys, so that two searches at once take the same rows in the same order and
    # wait for one another instead of each holding what the other wants. Plain UPDATEs, the same on every database.
    # A row that is not there yet is made before, outside of the transaction (a failed INSERT would spoil it on PostgreSQL),
    # and only the first time a key is counted.
    def add_all(increments)
      merged = merge(increments)
      return if merged.empty?

      keys = merged.map(&:first)
      (keys - SolrSearchCounter.where(key: keys).pluck(:key)).each {|key| create_row(key) }
      SolrSearchCounter.transaction do
        merged.each {|key, by| SolrSearchCounter.where(key: key).update_all(['value = value + ?', by]) }
      end
    end

    # A row at 0 for a key that has none; one that somebody else made at the same moment is the same row
    def create_row(key)
      SolrSearchCounter.create!(key: key, value: 0)
    rescue ActiveRecord::RecordNotUnique
      nil
    end
    private_class_method :create_row
  end
end
