# frozen_string_literal: true

require 'date'
require 'time'

module SolrSearch
  # Turns the filters of Redmine's issue query (the "Filters" of a list of issues: field, operator, values) into filter queries
  # for Solr (design D-49). The filters are read by Redmine's own IssueQuery (SolrSearchIssueQuery); this is the half that
  # writes Solr's side from plain values, with no database and no Rails: test/unit.
  #
  # What it understands is what the index has of an issue (docs/schema.md): the ids (status, tracker, priority, author,
  # assignee, target version, category), the dates (updated, created, closed, start, due), and the custom fields used as a
  # filter (Searcher's custom facets). The meaning of each operator is what Redmine's Query#sql_for_field gives.
  #
  # Every expression says "an issue's": a note or an attachment of an issue carries its issue's values (and only those have
  # them), and the expressions that say "no value" would let a Wiki page or an external document through: ISSUES keeps the
  # documents of issues, whatever the filters say.
  module FilterTranslator
    ISSUES = "{!prefix f=group_id v='issue-'}"

    ID_FIELDS = {
      'status_id' => 'status_id', 'tracker_id' => 'tracker_id', 'priority_id' => 'priority_id', 'author_id' => 'author_id',
      'assigned_to_id' => 'assigned_to_id', 'fixed_version_id' => 'fixed_version_id', 'category_id' => 'category_id'
    }.freeze
    # Redmine's field => [Solr's, :time (a time, in the user's zone) or :day (a date: the midnight UTC of it)]
    DATE_FIELDS = {
      'updated_on' => ['updated_at', :time], 'created_on' => ['issue_created_at', :time], 'closed_on' => ['issue_closed_at', :time],
      'start_date' => ['start_date', :day], 'due_date' => ['due_date', :day]
    }.freeze
    ID_OPERATORS = %w[= ! * !*].freeze
    STATUS_OPERATORS = (ID_OPERATORS + %w[o c]).freeze
    NUMBER_OPERATORS = %w[= >= <= >< * !*].freeze
    DATE_OPERATORS = %w[= >= <= >< t ld nd w lw l2w nw m lm nm y >t- <t- t- ><t- >t+ <t+ t+ ><t+ * !*].freeze

    # today: the user's today (a Date); zone: the user's time zone (ActiveSupport::TimeZone); first_day_of_week: 1 (Monday) to 7;
    # open_status_ids, closed_status_ids; my_ids: {field => [ids]} for "me" in a list (the user, and for the assignee the user's
    # groups); custom: the custom facets (id, kind, project_ids) of the user, by the field name "cf_<id>".
    Context = Struct.new(:today, :zone, :first_day_of_week, :open_status_ids, :closed_status_ids, :my_ids, :custom, keyword_init: true)

    # expressions: filter queries (strings), all to hold; understood: false when nothing of the filters was something to write
    # (so that the caller does not narrow to issues for nothing); ignored: the fields it could not read.
    Result = Struct.new(:expressions, :ignored, keyword_init: true) do
      def narrowing?
        !expressions.empty?
      end
    end

    module_function

    # filters: {"field" => {operator: "=", values: ["1", "2"]}} (Redmine's query.filters; the keys of the hashes may be strings)
    def call(filters, context)
      expressions = []
      ignored = []
      filters.each do |field, choice|
        operator = (choice[:operator] || choice['operator']).to_s
        values = Array(choice[:values] || choice['values']).map(&:to_s)
        expression = expression_for(field.to_s, operator, values, context)
        expression ? expressions << expression : ignored << field.to_s
      end
      expressions.unshift(ISSUES) unless expressions.empty?
      Result.new(expressions: expressions, ignored: ignored)
    end

    def expression_for(field, operator, values, context)
      if ID_FIELDS.key?(field)
        ids(ID_FIELDS[field], operator, values, context, field)
      elsif DATE_FIELDS.key?(field)
        solr_field, kind = DATE_FIELDS[field]
        dates(solr_field, kind, operator, values, context)
      elsif (custom = custom_field(field, context))
        custom_expression(custom, operator, values, context)
      end
    end

    # --- ids -------------------------------------------------------------------------------------------------------

    def ids(solr_field, operator, values, context, field)
      case operator
      when '=' then terms(solr_field, my_values(values, context, field))
      when '!' then (ids = my_values(values, context, field)).empty? ? nil : "(*:* -#{terms(solr_field, ids)})"
      when '*' then "#{solr_field}:[* TO *]"
      when '!*' then "(*:* -#{solr_field}:[* TO *])"
      when 'o' then terms(solr_field, context.open_status_ids) if field == 'status_id'
      when 'c' then terms(solr_field, context.closed_status_ids) if field == 'status_id'
      end
    end

    # "me" is the user (and, for the assignee, the groups the user is in); only whole numbers stay
    def my_values(values, context, field)
      values.flat_map {|v| v == 'me' ? Array(context.my_ids&.dig(field)) : [v] }
            .filter_map {|v| Integer(v.to_s, exception: false) }.uniq
    end

    def terms(field, ids)
      ids = Array(ids).filter_map {|id| Integer(id.to_s, exception: false) }.uniq.sort
      ids.empty? ? '-*:*' : "{!terms f=#{field} v='#{ids.join(',')}'}"
    end

    # --- dates -----------------------------------------------------------------------------------------------------

    def dates(field, kind, operator, values, context)
      return "#{field}:[* TO *]" if operator == '*'
      return "(*:* -#{field}:[* TO *])" if operator == '!*'

      from, to = date_range(operator, values, context)
      return if from.nil? && to.nil?

      "#{field}:[#{bound(from, kind, context, start: true) || '*'} TO #{bound(to, kind, context, start: false) || '*'}]"
    end

    # [from, to] as dates, either may be nil (no limit); [nil, nil] when the operator or its values are not understood
    def date_range(operator, values, context)
      today = context.today
      first = parse(values[0])
      second = parse(values[1])
      days = values[0].to_s.to_i
      week = week_start(context)
      case operator
      when '=' then [first, first] if first
      when '>=' then [first, nil] if first
      when '<=' then [nil, first] if first
      when '><' then [first, second] if first && second
      when 't' then [today, today]
      when 'ld' then [today - 1, today - 1]
      when 'nd' then [today + 1, today + 1]
      when 'w' then [week, week + 6]
      when 'lw' then [week - 7, week - 1]
      when 'l2w' then [week - 14, week - 1]
      when 'nw' then [week + 7, week + 13]
      when 'm' then [today.beginning_of_month, today.end_of_month]
      when 'lm' then [today.prev_month.beginning_of_month, today.prev_month.end_of_month]
      when 'nm' then [today.next_month.beginning_of_month, today.next_month.end_of_month]
      when 'y' then [today.beginning_of_year, today.end_of_year]
      when '>t-' then [today - days, nil]
      when '<t-' then [nil, today - days]
      when 't-' then [today - days, today - days]
      when '><t-' then [today - days, today]
      when '>t+' then [today + days, nil]
      when '<t+' then [nil, today + days]
      when 't+' then [today + days, today + days]
      when '><t+' then [today, today + days]
      end || [nil, nil]
    end

    # The first day of the user's week that holds today (Redmine's: the language's first day of the week)
    def week_start(context)
      first_day = context.first_day_of_week.to_i.clamp(1, 7)
      today = context.today
      today - ((today.cwday - first_day) % 7)
    end

    def parse(value)
      Date.iso8601(value.to_s[0, 10]) if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}/)
    rescue ArgumentError
      nil
    end

    # A date as the bound of a range: a time field from the start of the day to the end of it in the user's time zone, a date
    # field (the midnight UTC of the day it is) from that midnight to the last second of the day
    def bound(date, kind, context, start:)
      return unless date

      if kind == :day
        "#{date.iso8601}T#{start ? '00:00:00' : '23:59:59'}Z"
      else
        local = context.zone.local(date.year, date.month, date.day)
        (start ? local.beginning_of_day : local.end_of_day).utc.iso8601
      end
    end

    # --- custom fields -----------------------------------------------------------------------------------------------

    def custom_field(field, context)
      id = field[/\Acf_(\d+)\z/, 1]&.to_i
      id && Array(context.custom).find {|c| c.id == id }
    end

    PREFIX = {values: 'cfs', number: 'cfn', date: 'cfd'}.freeze

    # Only in the projects where the user may see the field (a field that is hidden elsewhere must not tell what is there:
    # the same as the choices of the facets, Searcher#custom_filter_expressions)
    def custom_expression(custom, operator, values, context)
      field = "#{PREFIX.fetch(custom.kind)}_#{custom.id}"
      expression = case custom.kind
                   when :values then custom_values(field, operator, values)
                   when :number then number(field, operator, values)
                   when :date then dates(field, :day, operator, values, context)
                   end
      return unless expression

      custom.project_ids ? "(#{expression} AND #{terms('project_id', custom.project_ids)})" : expression
    end

    def custom_values(field, operator, values)
      values = values.reject(&:empty?)
      one_of = ->(vs) { "(#{vs.map {|v| "{!term f=#{field} v='#{v.gsub(/[\\']/) {|c| "\\#{c}" }}'}" }.join(' OR ')})" }
      case operator
      when '=' then values.empty? ? '-*:*' : one_of.(values.first(Searcher::MAX_CHOSEN_VALUES))
      when '!' then values.empty? ? nil : "(*:* -#{one_of.(values.first(Searcher::MAX_CHOSEN_VALUES))})"
      when '*' then "#{field}:[* TO *]"
      when '!*' then "(*:* -#{field}:[* TO *])"
      end
    end

    def number(field, operator, values)
      low = Float(values[0].to_s, exception: false)
      high = Float(values[1].to_s, exception: false)
      case operator
      when '=' then "#{field}:[#{low - 1e-5} TO #{low + 1e-5}]" if low
      when '>=' then "#{field}:[#{low} TO *]" if low
      when '<=' then "#{field}:[* TO #{low}]" if low
      when '><' then "#{field}:[#{low} TO #{high}]" if low && high
      when '*' then "#{field}:[* TO *]"
      when '!*' then "(*:* -#{field}:[* TO *])"
      end
    end
  end
end
