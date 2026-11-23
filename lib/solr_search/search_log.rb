# frozen_string_literal: true

require 'securerandom'

module SolrSearch
  # Writes the log of the searches (design D-45). A search must never fail because its log could not be written.
  module SearchLog
    QUERY_MAX = 1000
    PATH_MAX = 2000
    # 255: a string column is that long on MySQL, and a row that does not fit is not written there (M6 review 6)
    ERROR_MAX = 255

    module_function

    # The values of one row. user: an object with id, login and logged? (Redmine's User); result: the search's result
    # (hit_count, group_count), nil for a search that failed; shown: the groups of the page that the screen showed;
    # shown_of: the groups of the page that Solr gave; collection: the collection of Redmine's data that was searched; sources:
    # the collections of the external sources that were searched too (design D-45). click_token: the mark that the screen of this
    # search sends back with its clicks (Clicks.accepted?). Pure but for the token's default: a light test checks it.
    def attributes(user:, query:, request_path:, project_id:, page:, took_ms:, result: nil, shown: nil, shown_of: nil, error: nil,
                   collection: nil, sources: [], click_token: SecureRandom.hex(16))
      {
        user_id: (user.id if user.logged?),
        user_login: (user.login if user.logged?),
        query: query.to_s[0, QUERY_MAX],
        request_path: request_path.to_s[0, PATH_MAX],
        project_id: project_id,
        page: page,
        hit_count: result&.hit_count,
        group_count: result&.group_count,
        dropped_count: (shown_of - shown if shown && shown_of),
        took_ms: took_ms,
        error: error&.to_s&.[](0, ERROR_MAX),
        collection: collection,
        external_sources: Array(sources).join(',').presence,
        click_token: click_token
      }
    end

    # Writes the row; a failure is said in Redmine's log and goes no further
    # The counts that Prometheus reads (Counters, SearchStats) are added in a step of their own: that one failing does not lose
    # the row, and the row failing does not lose the count of the search that was made.
    def record(**args)
      attrs = attributes(**args)
      count(attrs)
      SolrSearchLog.create!(attrs.merge(created_at: Time.current))
    rescue StandardError => e
      SolrSearch.log(:warn, "the search log could not be written: #{e.class}: #{e.message}")
      nil
    end

    def count(attrs)
      Counters.add_all(SearchStats.search_increments(page: attrs[:page], hit_count: attrs[:hit_count], took_ms: attrs[:took_ms],
                                                     dropped_count: attrs[:dropped_count], error: attrs[:error]))
    rescue StandardError => e
      SolrSearch.log(:warn, "the counts of the search could not be added: #{e.class}: #{e.message}")
    end
    private_class_method :count
  end
end
