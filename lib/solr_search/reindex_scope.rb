# frozen_string_literal: true

module SolrSearch
  # What a partial reindex is limited to (design D-57): the issues of some trackers, or the issues that have, or had,
  # a value in some custom fields. The scope is written in the request (SolrSearchRun#request_options['scope']) as
  # {'trackers' => [ids]} or {'fields' => [ids]}; the pure parts (the rules for it, the Solr query) are here, so that a
  # light test can check them. Which issues it means is decided when the run starts (Indexer#reindex_partial).
  module ReindexScope
    KINDS = %w[trackers fields].freeze
    # How many ids one request may name: each field makes five OR clauses, and Solr refuses more than 1024 clauses in a query
    MAX_IDS = 150

    # Raised for a scope that cannot be used. reason: :no_scope (nothing chosen), :both (both kinds), :bad_id.
    class Invalid < StandardError
      attr_reader :reason

      def initialize(message, reason)
        super(message)
        @reason = reason
      end
    end

    # The field names that carry a custom field's value in an issue's document (docs/schema.md): the text (cft_), its
    # Japanese analysis (cfj_), and the values of a filter (cfs_, cfn_, cfd_).
    FIELD_PREFIXES = %w[cft cfj cfs cfn cfd].freeze

    module_function

    # {'trackers' => [ids]} or {'fields' => [ids]} (the ids as integers, sorted, each once), or nil when neither is asked
    # for (a full reindex). Both at once, or an id that is not a positive integer, is refused.
    def normalize(trackers: nil, fields: nil)
      kinds = {'trackers' => ids(trackers), 'fields' => ids(fields)}.reject {|_kind, list| list.empty?}
      return if kinds.empty?
      raise Invalid.new('trackers and fields together', :both) if kinds.size > 1

      kinds
    end

    # The same from a stored scope (a Hash with string keys, or nil)
    def of(hash)
      return unless hash.respond_to?(:to_h) && hash.to_h.any?

      normalize(trackers: hash.to_h['trackers'], fields: hash.to_h['fields'])
    end

    # Whether the options of a run (SolrSearchRun#request_options) ask for a partial reindex
    def partial?(options)
      options.respond_to?(:to_h) && options.to_h['scope'].present?
    end

    # Whether a reindex run stands for the incremental crawl (Scheduler.last_start): not partial, and every one of the
    # types (the incremental crawl's) was asked for. The types are in its options (a request, and every reindex since
    # they were written there); an older run has only its counts; with neither (a run that failed before it sent
    # anything), it is counted, as all reindexes were before.
    def covers?(options, counts, types)
      return false if partial?(options)

      asked = Array(options.to_h['types']) if options.respond_to?(:to_h)
      asked = counts.to_h.keys if (asked.nil? || asked.empty?) && counts.respond_to?(:to_h)
      asked.nil? || asked.empty? || (types - asked).empty?
    end

    def kind(scope)
      scope.keys.first
    end

    def ids_of(scope)
      scope.values.first
    end

    # The Solr query for the issue documents that have a value in one of these custom fields (every field name a
    # custom field's value goes to). Used with the filters source and type.
    def solr_query(field_ids)
      field_ids.flat_map {|id| FIELD_PREFIXES.map {|prefix| "#{prefix}_#{Integer(id)}:*"}}.join(' OR ')
    end

    # The ids of the custom fields that names (field names of an index) are the values of: "cft_12" and "cfj_12" are 12.
    # Names of other fields are left out.
    def field_ids(names)
      names.filter_map {|name| name[/\A(?:#{FIELD_PREFIXES.join('|')})_([1-9]\d*)\z/, 1]&.to_i}.uniq.sort
    end

    # [integers] from what a form or a rake task gives (a string "1,2", an array, nil); each once, sorted
    def ids(value)
      unless value.nil? || value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Array)
        raise Invalid.new('not a list of ids', :bad_id) # a Hash (trackers[a]=1) or the like from a request
      end
      list = value.is_a?(String) ? value.split(',') : Array(value)
      list = list.map {|item| item.to_s.strip}.reject(&:empty?)
      raise Invalid.new("more than #{MAX_IDS} ids", :bad_id) if list.size > MAX_IDS
      list.map do |item|
        raise Invalid.new("not an id: #{item.inspect}", :bad_id) unless item.match?(/\A[1-9]\d{0,9}\z/)

        item.to_i
      end.uniq.sort
    end
  end
end
