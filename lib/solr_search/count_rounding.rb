# frozen_string_literal: true

module SolrSearch
  # How many results the screen says (Q-48): a count under EXACT_BELOW is written as it is; a larger one keeps its two
  # leading digits (1,234 -> 1,200; 34,567 -> 35,000). The count Solr gives is not exact for what the user may see
  # (the display check drops some, and the counts of hits count notes and attachments one by one), so the screen writes
  # it with "about" and does not pretend to the last digit. The pages are computed from the real number, not from this.
  module CountRounding
    EXACT_BELOW = 100
    KEPT_DIGITS = 2

    def self.round(count)
      return count if count.nil? || count < EXACT_BELOW

      digits = count.to_s.size
      unit = 10**(digits - KEPT_DIGITS)
      ((count + unit / 2) / unit) * unit
    end
  end
end
