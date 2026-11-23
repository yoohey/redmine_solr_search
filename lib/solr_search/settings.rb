# frozen_string_literal: true

module SolrSearch
  # The plugin settings (Administration > Plugins > Configure; design D-28), with the defaults of init.rb for a value
  # never saved. Saving the settings page stores the whole hash, so a setting added later is missing from older saves.
  module Settings
    module_function

    def [](name)
      Setting.plugin_redmine_solr_search[name].presence || default(name)
    end

    # The settings that the admin page edits (the fine tuning tab and the status tab), not the plugin's settings screen. Saving that
    # screen replaces the whole hash, so it sends these back as hidden fields (admin_page_values): a setting of the admin page is put
    # in this list, and nowhere else (design D-51).
    ADMIN_PAGE_KEYS = %w[solr_url redmine_collection tika_url show_solr_request expand_spelling_variants highlight_style reranker_url
                         reranker_format reranker_model reranker_timeout reranker_docs reranker_chars].freeze

    # What is stored now, as a Hash with String keys ({} when nothing was saved)
    def stored
      saved = Setting.plugin_redmine_solr_search
      saved.respond_to?(:to_h) ? saved.to_h.stringify_keys : {}
    end

    # Puts the changes among the stored settings (a merge: what is not in the changes stays) and logs what changed. The one way
    # that the plugin writes its settings. changes: {name => String}; by: who, for the log.
    def update(changes, by: nil)
      saved = stored
      changes = changes.to_h.transform_keys(&:to_s)
      changes.each do |key, value|
        SolrSearch.log(:info, "#{key} changed#{" by #{by}" if by}: #{saved[key].to_s.inspect} -> #{value.inspect}") if saved[key].to_s != value.to_s
      end
      Setting.plugin_redmine_solr_search = saved.merge(changes)
    end

    # {name => value} that the plugin's settings screen sends back for ADMIN_PAGE_KEYS. The collection as it is kept (empty: the
    # default is not written as if it had been chosen), and the highlight style only when it was saved (a saved empty one is "no
    # style", not the default).
    def admin_page_values
      saved = stored
      ADMIN_PAGE_KEYS.filter_map do |name|
        case name
        when 'redmine_collection' then [name, saved[name].to_s]
        when 'highlight_style' then [name, highlight_style] if saved.key?(name)
        else [name, self[name].to_s]
        end
      end.to_h
    end

    # The Solr address in use and where it comes from: [url, :screen or :env], or nil when neither is set (design D-43).
    # Read at each call: a change on the admin page is used by the next request, and by the scheduler's next tick.
    def solr_address
      SolrUrl.resolve(saved: self['solr_url'], env: ENV['SOLR_URL'])
    end

    # The Tika address in use and where it comes from: [url, :screen, :env or :default] (design D-61). Read at each call, like
    # solr_address.
    def tika_address
      TikaClient.resolve(saved: self['tika_url'], env: ENV['TIKA_URL'])
    end

    # The collection of Redmine's data (design D-44): the saved name when it is a valid one, COLLECTION otherwise (never
    # saved, saved empty, or a value that Solr's rule for names would refuse: it goes into URLs and filters)
    def redmine_collection
      name = self['redmine_collection'].to_s.strip
      COLLECTION_NAME.match?(name) ? name : COLLECTION
    end

    # A number of seconds (timeouts): at least 1
    def seconds(name)
      [self[name].to_i, 1].max
    end

    # The most words a search may have (design D-24): Solr is not asked beyond it, so that no one can send it a huge
    # query (5,000 words: a 400 and a 60 KB line in the log each time). Redmine's own search keeps 5.
    MAX_WORDS = (1..20)

    # A number outside MAX_WORDS is taken as its nearest end; one that is no number (or blank), as the default
    def max_words
      value = Integer(self['max_words'].to_s, 10, exception: false) || Integer(default('max_words'), 10)
      value.clamp(MAX_WORDS)
    end

    # Containers on a page of the search screen (a setting; Searcher::PER_PAGE is the default). A number outside the range is
    # taken as its nearest end; one that is no number (or blank), as the default.
    PER_PAGE = (10..100)

    def per_page
      value = Integer(self['per_page'].to_s, 10, exception: false) || Integer(default('per_page'), 10)
      value.clamp(PER_PAGE)
    end

    # Default style for highlighted words (<span class="highlight">) on the search screen (M4 review, #13)
    DEFAULT_HIGHLIGHT_STYLE = 'font-weight: bold; background-color: #ffe066;'

    # The style declarations for <span class="highlight">: the default until saved, and may be cleared to empty
    def highlight_style
      saved = Setting.plugin_redmine_solr_search
      raw = saved.is_a?(Hash) && saved.key?('highlight_style') ? saved['highlight_style'].to_s : default('highlight_style').to_s
      raw.tr('{}<>', '').strip
    end

    ATTACHMENT_FILE_MB = (1..500)
    ATTACHMENT_TEXT_MB = (1..20)

    # The extensions whose attachments get their text made (design D-47): the valid ones of the saved list, the default when
    # there is none (never saved, empty, or nothing valid in it)
    def attachment_extensions
      valid, = AttachmentText.parse_extensions(self['attachment_extensions'])
      valid.presence || AttachmentText::DEFAULT_EXTENSIONS
    end

    # The pieces of the saved list that were left out because they are not an extension (shown on the settings screen)
    def attachment_extensions_ignored
      AttachmentText.parse_extensions(self['attachment_extensions']).last
    end

    # The largest file sent to Tika, and the longest text kept (design D-47), in bytes: megabytes of 1,048,576 within their
    # range; a number outside it is taken as its nearest end, and one that is no number as the default
    def attachment_max_file_bytes
      megabytes('attachment_max_file_mb', ATTACHMENT_FILE_MB) * 1_048_576
    end

    def attachment_max_text_bytes
      megabytes('attachment_max_text_mb', ATTACHMENT_TEXT_MB) * 1_048_576
    end

    def megabytes(name, range)
      value = Integer(self[name].to_s, 10, exception: false) || Integer(default(name), 10)
      value.clamp(range)
    end

    def default(name)
      Redmine::Plugin.find(:redmine_solr_search).settings[:default][name]
    end

    INTERVAL_UNITS = %w[minutes hours days].freeze

    # How often the scheduler runs a crawl task (design D-22): a duration, or nil when it is disabled. Kept as a
    # number and a unit, as entered ("1 day" stays 1 day).
    def interval(task)
      return nil unless self["schedule_#{task}_enabled"] == '1'

      unit = self["schedule_#{task}_unit"]
      unit = 'minutes' unless INTERVAL_UNITS.include?(unit)
      [self["schedule_#{task}_every"].to_i, 1].max.public_send(unit)
    end
  end
end
