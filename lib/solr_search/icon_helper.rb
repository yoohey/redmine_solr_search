# frozen_string_literal: true

require 'erb'

module SolrSearch
  # An icon and its text in the plugin's pages (design D-62). Redmine 6.0 draws icons as SVG (sprite_icon); 5.1 has no such
  # helper and draws them from the CSS class of the element around (icon icon-ok, icon-warning ...), which the plugin's
  # markup has too, so there the text alone is enough. Included in every view by init.rb.
  module IconHelper
    def solr_search_icon(name, label = nil)
      return sprite_icon(name, label) if respond_to?(:sprite_icon)

      ERB::Util.html_escape(label.to_s)
    end
  end
end
