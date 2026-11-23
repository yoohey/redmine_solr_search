# frozen_string_literal: true

module SolrSearch
  # The ヴ row and the バ row are indexed as written (design D-21, schema v1 round 3c), so that a search can tell them
  # apart. To find both, the plugin sends a word in every spelling (バイオリン -> バイオリン OR ヴァイオリン).
  # An optional feature: off in the "exact string" mode (D-24 R9), and to be switchable by the administrator.
  # First a port of expand() in docs/experiments/schema-v1/gen_r3c.py; since fixed to keep the spelling typed and to
  # give ビュ, ビャ, ビョ their ヴ spelling (M1 review A3).
  # The small ヶ and ヵ are kept apart from ケ and カ in the same way (M7): 霞ケ関 (Tokyo Metro) and 霞ヶ関 (Tobu Tojo line) are
  # two stations, 茅ケ崎 (JR) and 茅ヶ崎 (the city) two names. The index has them as written; a search finds both, and the "exact
  # string" mode only the one typed. Only after an ideograph (霞ケ, 三ヵ): ケーキ and ケース are left alone.
  module SpellingVariants
    # ヴ row -> バ row, full-width only: applied after NFKC, which has already composed ｳﾞ and ウ + U+3099 into ヴ.
    # Longest first, so that ヴァ is not read as ヴ + ァ.
    FOLD = [%w[ヴァ バ], %w[ヴィ ビ], %w[ヴゥ ブ], %w[ヴェ ベ], %w[ヴォ ボ],
            %w[ヴャ ビャ], %w[ヴュ ビュ], %w[ヴョ ビョ], %w[ヴ ブ]].freeze
    # バ-row spelling -> ヴ spelling, longest first (ビュ -> ヴュ, not ヴィュ). ブ is not given ヴゥ (rarely written, and
    # it would make every word with ブ half as long again); a word typed with ヴゥ is still sent as typed.
    TO_VU = [%w[ビャ ヴャ], %w[ビュ ヴュ], %w[ビョ ヴョ],
             %w[バ ヴァ], %w[ビ ヴィ], %w[ブ ヴ], %w[ベ ヴェ], %w[ボ ヴォ]].freeze
    # Splits a word into the keys of TO_VU and single characters
    PARTS = /#{Regexp.union(TO_VU.map(&:first))}|./m
    # the small kana and the large one are one choice, after an ideograph; the first of each pair is the large one
    SMALL_KANA = {'ケ' => %w[ケ ヶ], 'ヶ' => %w[ケ ヶ], 'カ' => %w[カ ヵ], 'ヵ' => %w[カ ヵ]}.freeze
    MAX_VARIANTS = 16

    module_function

    # The word as typed (NFKC, the form Solr indexes), then every other spelling with each バ-row part as it is or in
    # its ヴ form; [word] when there is nothing to vary. At most MAX_VARIANTS: a word with many バ-row characters keeps
    # the first combinations, but never loses the spelling typed (M1 review A3).
    def expand(word)
      typed = word.unicode_normalize(:nfkc)
      base = FOLD.reduce(typed) {|w, (src, dst)| w.gsub(src, dst)}
      # a TO_VU pair is the part's two choices: as it is, and its ヴ spelling; so is a small or large kana after an ideograph
      parts = base.scan(PARTS)
      choices = parts.each_with_index.map do |part, i|
        small = SMALL_KANA[part] if i.positive? && parts[i - 1].match?(/\p{Han}\z/)
        TO_VU.assoc(part) || small || [part]
      end
      return [word] if choices.all? {|c| c.size == 1}

      variants = [typed]
      combine(choices, '', variants)
      variants
    end

    def combine(choices, prefix, out)
      return if out.size >= MAX_VARIANTS
      if choices.empty?
        out << prefix unless out.include?(prefix) # the spelling typed is already first
        return
      end

      choices.first.each {|c| combine(choices.drop(1), prefix + c, out)}
    end
  end
end
