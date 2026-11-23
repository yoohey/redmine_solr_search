# frozen_string_literal: true

# A click on a result of the search screen (design D-45). Written by SolrSearch::Clicks.record.
class SolrSearchClick < SolrSearchRecord
  belongs_to :log, class_name: 'SolrSearchLog', optional: true
end
