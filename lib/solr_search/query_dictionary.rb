# frozen_string_literal: true

module SolrSearch
  # The query expansion dictionary (design D-53, Q-27): groups of terms that mean the same, kept by the plugin (not in the
  # Solr configset), and used when a search is made: a word of the query that is a term of a group becomes the OR of the
  # group's terms. Plain values, no database, no Rails (test/unit); SolrSearchSynonym keeps the text.
  #
  # The text: one group per line, terms separated by "," (or the full-width "，" and "、"); a line that starts with "#" and a
  # blank line are skipped. A term may hold spaces ("シングル サインオン"): it is compared with consecutive words of the query.
  module QueryDictionary
    MAX_GROUP_TERMS = 8
    MAX_TERM_WORDS = 4
    MAX_TERM_LENGTH = 100
    MAX_LINES = 2_000
    MAX_BYTES = 200 * 1024
    SEPARATOR = /[,，、]/

    # One line of the text that cannot be used: the number of the line (from 1; 0 for the text as a whole) and why
    Problem = Struct.new(:line, :reason, :detail, keyword_init: true)

    Parsed = Struct.new(:groups, :problems, keyword_init: true)

    module_function

    # text => Parsed: groups = [[term, ...], ...] (the terms in NFKC, as they will be sent, the first spelling of each kept)
    # and problems = what was refused. A line with a problem is left out of the groups.
    def parse(text)
      text = text.to_s
      problems = []
      problems << Problem.new(line: 0, reason: :too_big) if text.bytesize > MAX_BYTES
      lines = text.lines
      problems << Problem.new(line: 0, reason: :too_many_lines) if lines.size > MAX_LINES
      groups = []
      lines.first(MAX_LINES).each_with_index do |raw, i|
        line = raw.strip
        next if line.empty? || line.start_with?('#')

        terms = unique_terms(line.split(SEPARATOR).map {|t| clean(t) }.reject(&:empty?))
        reason = problem_of(terms)
        reason ? problems << Problem.new(line: i + 1, reason: reason) : groups << terms
      end
      Parsed.new(groups: groups, problems: problems)
    end

    # What looks wrong but is allowed (the check button of the tab says it; saving does not wait for it): [Problem, ...] with
    #   other_separator: a line with a character that is likely meant to separate (; | = -> a tab ...) as the terms' separator
    #   duplicate_term:  the same term twice in a line (the second is dropped)
    #   shared_term:     a term of several lines (they are used together, one step: A,B and B,C do not make A and C the same)
    OTHER_SEPARATORS = /[;；|｜\/／=＝→⇒>＞\t]/
    def warnings(text)
      found = []
      seen = Hash.new {|h, k| h[k] = [] }
      text.to_s.lines.first(MAX_LINES).each_with_index do |raw, i|
        line = raw.strip
        next if line.empty? || line.start_with?('#')

        if (char = line[OTHER_SEPARATORS])
          found << Problem.new(line: i + 1, reason: :other_separator, detail: char == "\t" ? 'Tab' : char)
        end
        terms = line.split(SEPARATOR).map {|t| clean(t) }.reject(&:empty?)
        dup = terms.group_by {|t| key(t) }.find {|_, v| v.size > 1 }
        found << Problem.new(line: i + 1, reason: :duplicate_term, detail: dup.last.first) if dup
        unique_terms(terms).each {|t| seen[key(t)] << [i + 1, t] }
      end
      seen.each_value do |places|
        next if places.size < 2

        found << Problem.new(line: places.first.first, reason: :shared_term,
                             detail: "#{places.first.last} (#{places.map(&:first).join(', ')})")
      end
      found.sort_by {|w| [w.line, w.reason.to_s] }
    end

    # The dictionary of a text (the groups that are fit to use; the rest is left out)
    def build(text)
      Dictionary.new(parse(text).groups)
    end

    def empty
      Dictionary.new([])
    end

    def clean(term)
      term.unicode_normalize(:nfkc).gsub(/[[:space:]]+/, ' ').strip
    end

    def key(term)
      clean(term).downcase
    end

    def unique_terms(terms)
      terms.uniq {|t| key(t) }
    end

    def problem_of(terms)
      return :too_few if terms.size < 2
      return :too_many_terms if terms.size > MAX_GROUP_TERMS
      return :term_too_long if terms.any? {|t| t.length > MAX_TERM_LENGTH }
      return :term_too_many_words if terms.any? {|t| t.split(' ').size > MAX_TERM_WORDS }

      nil
    end

    # The terms of the groups by their key; what a search asks
    class Dictionary
      def initialize(groups)
        @index = Hash.new {|h, k| h[k] = [] }
        groups.each do |terms|
          terms.each {|term| @index[QueryDictionary.key(term)].concat(terms) }
        end
        @index.each_value {|terms| terms.replace(QueryDictionary.unique_terms(terms)) }
        @index.default_proc = nil
        @longest = @index.keys.map {|k| k.split(' ').size }.max || 0
      end

      def empty?
        @index.empty?
      end

      # The words of a query => a list of alternatives, one per place of the query: [word] for a word that is not in the
      # dictionary; for words (one, or several that stand together) that are a term, [the words as typed, the group's other
      # terms]. The longest term is matched first. Nothing else changes: the order of the places is that of the words.
      def expand(words)
        return words.map {|w| [w] } if empty?

        places = []
        i = 0
        while i < words.size
          size, terms = match_at(words, i)
          if terms
            typed = words[i, size].join(' ')
            places << [typed, *terms.reject {|t| QueryDictionary.key(t) == QueryDictionary.key(typed) }]
            i += size
          else
            places << [words[i]]
            i += 1
          end
        end
        places
      end

      private

      def match_at(words, i)
        [@longest, words.size - i].min.downto(1) do |size|
          terms = @index[QueryDictionary.key(words[i, size].join(' '))]
          return [size, terms] if terms
        end
        nil
      end
    end
  end
end
