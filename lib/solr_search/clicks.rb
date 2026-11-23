# frozen_string_literal: true

require 'active_support/security_utils'

module SolrSearch
  # Writes the clicks on the result list (design D-45). Like the search log, it must never fail a request.
  module Clicks
    KINDS = %w[title note attachment more other].freeze
    GROUP_MAX = 255 # see SearchLog::ERROR_MAX
    TITLE_MAX = 200
    HREF_MAX = 1000
    RANK_MAX = 1000
    # the same link pressed twice within this long is one click (a double click)
    REPEAT_WITHIN = 2.seconds
    # How long after a search a click on its list is taken: the page may stay open a while
    VALID_FOR = 1.day

    module_function

    # The values of one row, from what the screen's script sent. Pure: a light test checks it.
    def attributes(group:, rank:, kind:, title:, href:)
      number = Integer(rank.to_s, 10, exception: false)
      {
        group_id: group.to_s[0, GROUP_MAX],
        rank: (number if number && number.between?(1, RANK_MAX)),
        kind: (kind.to_s if KINDS.include?(kind.to_s)) || 'other',
        title: title.to_s.squish[0, TITLE_MAX].presence,
        href: href.to_s[0, HREF_MAX].presence
      }
    end

    # Whether a click is taken: the screen sent the mark of that very search (the row's number alone is a running number that
    # anyone can guess, and a user who is not logged in has no user to compare), from the same user, within VALID_FOR. mine: the
    # id of the user who is logged in, nil when nobody is. Pure: a light test checks it (M6 review 2).
    def accepted?(log, mine:, token:, now: Time.current)
      return false unless log && log.click_token.present? && token.is_a?(String) && token.bytesize == log.click_token.bytesize
      return false unless ActiveSupport::SecurityUtils.secure_compare(log.click_token, token)

      log.user_id == mine && log.created_at > VALID_FOR.ago(now)
    end

    # The counts that Prometheus reads (design D-45). The first click of a first page's search that found something is also
    # counted as a search with a click: the other side of the searches that did not help. A failure here is only logged.
    def count(log, attrs)
      # the first click of the search is the one that sets clicked_at: one UPDATE decides it, so two clicks at once cannot both
      # be the first, or neither (a count of the rows would be)
      first_of_the_search = SolrSearchLog.where(id: log.id, clicked_at: nil).update_all(clicked_at: Time.current) == 1
      first = first_of_the_search && log.page == 1 && log.hit_count.to_i.positive?
      Counters.add_all(SearchStats.click_increments(kind: attrs[:kind], rank: attrs[:rank], first_click: first))
    rescue StandardError => e
      SolrSearch.log(:warn, "the counts of the click could not be added: #{e.class}: #{e.message}")
    end
    private_class_method :count

    # Writes the click of a search; nil when it is the same link pressed again at once, or could not be written
    def record(log, **args)
      attrs = attributes(**args)
      last = SolrSearchClick.where(log_id: log.id).order(:id).last
      return nil if last && last.group_id == attrs[:group_id] && last.href == attrs[:href] && last.created_at > REPEAT_WITHIN.ago

      click = SolrSearchClick.create!(attrs.merge(log_id: log.id, created_at: Time.current))
      count(log, attrs)
      click
    rescue StandardError => e
      SolrSearch.log(:warn, "the click could not be written: #{e.class}: #{e.message}")
      nil
    end
  end
end
