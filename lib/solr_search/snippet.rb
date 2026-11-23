# frozen_string_literal: true

module SolrSearch
  # What the screen does with a snippet from Solr before it shows it. The screen shows three lines of it (CSS line-clamp),
  # but Solr's passage can be much longer: a text without full stops (a table, a list of names) is one sentence for the
  # Unified Highlighter, so the passage is the whole text, whatever hl.fragsize says, and the mark may lie beyond the
  # third line, out of sight (a station found at the 261st character of a 401-character table showed no mark).
  module Snippet
    # a mark that begins within this many characters is in the first three lines, even on a narrow screen
    VISIBLE = 80
    # how many characters of the text before the first mark are kept, when the start is cut away
    LEAD = 30
    ELLIPSIS = '…'

    # text: the snippet with its marks (Searcher::HL_PRE), white space already folded. The start is cut away, with an
    # ellipsis, when the first mark is not in sight; the marks are never split (nothing is cut after the first one).
    def self.from_first_mark(text, mark: Searcher::HL_PRE)
      at = text.index(mark)
      return text if at.nil? || at <= VISIBLE

      ELLIPSIS + text[(at - LEAD)..]
    end
  end
end
