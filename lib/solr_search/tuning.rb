# frozen_string_literal: true

module SolrSearch
  # The tuning of the order of the results, for the "fine tuning" tab of the admin page (design D-51, Q-34): the weights that
  # the search sends to Solr with the words. Plain values (no database, no Rails: test/unit); SolrSearchTuning keeps them.
  #
  # A value is only a weight in a query: nothing here changes what is found, only the order, and nothing needs the index made
  # again. The defaults are what the search sent before there was a tab (Searcher::QF, nothing else), so a search that was
  # never tuned sends the same query as ever.
  module Tuning
    # the fields of the main clause, in the order of qf (the Japanese ones, which find by words, and the 2-gram ones)
    QF_FIELDS = %w[title_ja content_ja title content].freeze
    # what a type is called here => of Searcher::TYPE_FILTERS (an issue's notes count with the issue)
    TYPES = %w[issue wiki_page document attachment external].freeze

    DEFAULTS = {
      'qf' => {'title_ja' => 3.0, 'content_ja' => 2.0, 'title' => 1.0, 'content' => 1.0},
      'pf2' => 0.0,
      'types' => TYPES.to_h {|type| [type, 1.0] },
      'sources' => {},
      'recency' => {'strength' => 0.0, 'half_life_days' => 180.0}
    }.freeze

    # what a value may be (checked when it is saved)
    RANGES = {
      weight: 0.0..20.0, phrase: 0.0..20.0, factor: 0.1..10.0, strength: 0.0..5.0, half_life: 7.0..3650.0
    }.freeze
    MAX_SOURCES = 100
    DAY_MS = 86_400_000

    module_function

    # raw: what was saved (or nil, or parts of it): the defaults where a value is missing or is not a number; what is not in
    # DEFAULTS is dropped. Values are not clamped: validate decides what may be saved.
    def normalize(raw)
      raw = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
      {
        'qf' => QF_FIELDS.to_h {|f| [f, number(hash(raw['qf'])[f], DEFAULTS['qf'][f])] },
        'pf2' => number(raw['pf2'], DEFAULTS['pf2']),
        'types' => TYPES.to_h {|t| [t, number(hash(raw['types'])[t], 1.0)] },
        'sources' => hash(raw['sources']).filter_map {|name, v| [name.to_s, number(v, 1.0)] if source_name?(name) }.first(MAX_SOURCES).to_h,
        'recency' => {'strength' => number(hash(raw['recency'])['strength'], DEFAULTS['recency']['strength']),
                      'half_life_days' => number(hash(raw['recency'])['half_life_days'], DEFAULTS['recency']['half_life_days'])}
      }
    end

    # {"path" => reason} for what may not be saved (empty: it may). The path names the value ("qf.title_ja", "sources.src_3").
    def validate(tuning)
      errors = {}
      check = lambda do |path, value, range|
        errors[path] = :range unless value.is_a?(Numeric) && value.finite? && range.cover?(value)
      end
      QF_FIELDS.each {|f| check.("qf.#{f}", tuning['qf'][f], RANGES[:weight]) }
      errors['qf'] = :none_positive unless tuning['qf'].values.any? {|w| w.is_a?(Numeric) && w.positive? }
      check.('pf2', tuning['pf2'], RANGES[:phrase])
      TYPES.each {|t| check.("types.#{t}", tuning['types'][t], RANGES[:factor]) }
      tuning['sources'].each {|name, v| check.("sources.#{name}", v, RANGES[:factor]) }
      check.('recency.strength', tuning['recency']['strength'], RANGES[:strength])
      check.('recency.half_life_days', tuning['recency']['half_life_days'], RANGES[:half_life])
      errors
    end

    # From the form's parameters (strings; a blank is "not given": the default), or nil values for what is not a number
    def parse(params)
      params = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
      parsed = normalize(params)
      # a number that is not one is kept as nil, to be refused by validate (normalize would have turned it into the default)
      bad = {}
      flat(params).each {|path, v| bad[path] = true if v.to_s.strip != '' && Float(v.to_s, exception: false).nil? }
      [parsed, bad]
    end

    # [[path, before, after], ...] for what differs between two tunings (both normalized), in the order of the form
    def changes(before, after)
      flat_before = flat(before).to_h
      flat(after).filter_map {|path, value| [path, flat_before.fetch(path, nil), value] if flat_before.fetch(path, nil) != value }
    end

    # --- what goes to Solr ---------------------------------------------------------------------------------------------

    # qf: the fields with a weight above zero; a weight of one is written as the field alone (as Searcher::QF always did)
    def qf(tuning)
      QF_FIELDS.filter_map {|f| w = tuning['qf'][f]; w.positive? ? field_weight(f, w) : nil }.join(' ')
    end

    # The parameters beside qf: pf2 (a bonus for the words of a query that stand next to each other, in the Japanese fields) and
    # boost (what the score is multiplied by: the type, the source, how new). Only what is not neutral: a search that was never
    # tuned has none, and sends what it always sent. exact: the n-gram search takes no phrase bonus (its fields are others).
    def params(tuning, exact: false)
      extra = {}
      pf2 = tuning['pf2']
      extra[:pf2] = %w[title_ja content_ja].map {|f| field_weight(f, pf2) }.join(' ') if pf2.positive? && !exact
      factors = boost_factors(tuning)
      extra[:boost] = factors.size == 1 ? factors.first : "product(#{factors.join(',')})" if factors.any?
      extra
    end

    def boost_factors(tuning)
      factors = []
      TYPES.each do |type|
        factor = tuning['types'][type]
        factors << if_type(Searcher::TYPE_FILTERS.fetch(type), factor) unless factor == 1.0
      end
      tuning['sources'].each do |name, factor|
        factors << "if(query({!v='source:#{name}'}),#{format_number(factor)},1)" unless factor == 1.0
      end
      strength = tuning['recency']['strength']
      if strength.positive?
        # 1 + strength * (1 / (1 + age / half life)): twice the weight at once as much as a half life ago; the day, not the second,
        # so that the function is the same all day
        scale = 1.0 / (tuning['recency']['half_life_days'] * DAY_MS)
        factors << "sum(1,product(#{format_number(strength)},recip(ms(NOW/DAY,updated_at),#{format('%.4e', scale)},1,1)))"
      end
      factors
    end

    def if_type(doc_types, factor)
      "if(query({!v='type:(#{doc_types.join(' OR ')})'}),#{format_number(factor)},1)"
    end

    # --- helpers -------------------------------------------------------------------------------------------------------

    def source_name?(name)
      SolrSearch.external_collection?(name.to_s)
    end

    def hash(value)
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    def number(value, default)
      return default if value.nil? || value.to_s.strip == ''

      Float(value.to_s, exception: false) || default
    end

    def field_weight(field, weight)
      weight == 1.0 ? field : "#{field}^#{format_number(weight)}"
    end

    def format_number(number)
      number == number.to_i ? number.to_i.to_s : number.to_s
    end

    # every value of the form, by its path ("qf.title_ja")
    def flat(params, prefix = nil)
      params.flat_map do |key, value|
        path = [prefix, key].compact.join('.')
        value.is_a?(Hash) ? flat(value, path) : [[path, value]]
      end
    end
  end
end
