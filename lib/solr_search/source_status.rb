# frozen_string_literal: true

module SolrSearch
  # What the admin page says about the external index sources (design D-33, D-35): whether each source's collection
  # is there, made from the configset of external documents, and how many of its documents carry another source value
  # (they never come out of a search); and which of Solr's collections are not sources yet. Marks only: searches do
  # not depend on them.
  class SourceStatus
    # state: :ok, :missing (no collection), :wrong_configset, or :unknown (Solr did not answer: error says why).
    # wrong_source: documents whose source is not the collection's name (nil when not counted)
    Check = Struct.new(:state, :configset, :wrong_source, :error, keyword_init: true)

    # A collection that is not a source: whether it may become one (selectable), or why not
    Candidate = Struct.new(:name, :configset, :selectable, keyword_init: true)

    attr_reader :error

    # client: any Client of this Solr (its base URL is used). Asks Solr for its collections once.
    def initialize(client:)
      @client = client
      @configsets = client.collection_configsets
    rescue Client::Error => e
      @error = e.message
      @configsets = nil
    end

    def answered?
      !@configsets.nil?
    end

    # {source id => Check}. count_wrong_source: false leaves out the search that counts the documents whose source value
    # is wrong, one request to each collection (the admin page has it; a project's settings tab does not need it)
    def check(sources, count_wrong_source: true)
      sources.to_h {|source| [source.id, check_one(source, count_wrong_source)] }
    end

    # Solr's collections that are no source yet, but Redmine's own (design D-35), by name
    def candidates(sources)
      return [] unless answered?

      taken = sources.map(&:collection)
      # neither Redmine's own collection, nor a collection called what its documents' source is called (M6 review, Gemini 1-2)
      @configsets.except(SolrSearch.collection, SolrSearch::SOURCE, *taken).sort.map do |name, configset|
        Candidate.new(name: name, configset: configset,
                      selectable: configset == SOURCE_CONFIGSET && SolrSearch.external_collection?(name))
      end
    end

    # Whether a collection may be chosen for a new source now: nil when it may, otherwise a symbol saying why
    def refusal(name)
      return :redmine if [SolrSearch.collection, SolrSearch::SOURCE].include?(name) # never Redmine's own, nor one named like its source (D-35, D-44)
      return :unknown unless answered?
      return :missing unless @configsets.key?(name)

      :wrong_configset unless @configsets[name] == SOURCE_CONFIGSET
    end

    def configset(name)
      @configsets&.[](name)
    end

    # The path of one document in a collection, to try a path mapping against; nil when there is none or Solr does not answer
    def sample_path(name)
      return unless answered? && @configsets.key?(name)

      collection = Client.new(@client.base_url, name, read_timeout: @client.read_timeout,
                                                      open_timeout: @client.open_timeout)
      collection.select(q: 'path:[* TO *]', rows: 1, fl: 'path').dig('response', 'docs', 0, 'path')
    rescue Client::Error
      nil
    end

    private

    def check_one(source, count_wrong_source)
      return Check.new(state: :unknown, error: @error) unless answered?
      return Check.new(state: :missing) unless @configsets.key?(source.collection)

      configset = @configsets[source.collection]
      return Check.new(state: :wrong_configset, configset: configset) unless configset == SOURCE_CONFIGSET

      Check.new(state: :ok, configset: configset, wrong_source: (wrong_source(source) if count_wrong_source))
    end

    # documents of the collection whose source is another value; nil when the collection does not answer
    def wrong_source(source)
      collection = Client.new(@client.base_url, source.collection, read_timeout: @client.read_timeout,
                                                                   open_timeout: @client.open_timeout)
      collection.select(q: '*:*', rows: 0, fq: "-source:#{source.collection}").dig('response', 'numFound')
    rescue Client::Error
      nil
    end
  end
end
