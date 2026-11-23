# frozen_string_literal: true

module SolrSearch
  # What is looked up once per request (reset by Rails after each one)
  class Current < ActiveSupport::CurrentAttributes
    # {user id => whether the user may use the search in some project}
    attribute :use_permission
  end
end
