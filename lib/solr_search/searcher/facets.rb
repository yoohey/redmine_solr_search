# frozen_string_literal: true

module SolrSearch
  class Searcher
    # The facets of the search screen (design D-49) and the custom field choices: the definition of the JSON facets, the filters that a choice makes, and the reading of the answer. Moved here from Searcher; nothing changed.
    module Facets
      private

      # One request for the count of hits and the facets (D-49). Its filters are tagged so that each facet leaves its own
      # choice out (the type facet shows what the other types would give while one is ticked), and all the sources that
      # the user may search are asked, not only the chosen. The unit is the container: unique(group_id) over the whole
      # match, which is what Result Grouping's group.facet counted (m7-order round 2); a plain facet after a collapse
      # would count the kept documents only.
      def facet_counts(base, types:, project_ids:, sources:, wide_sources:, source_filter:, filters:, custom:, custom_facets:)
        request = base.reject {|k, _| k.to_s.start_with?('hl') || %i[sort start debug boost pf2].include?(k)}
        # the permission filter lets through the documents of all the sources; the choice of projects (tagged) lets through
        # those of the chosen projects' sources only, as a search does. Without it the wider sources are counted by the
        # facet of the sources per project, which leaves that choice out.
        add_sources(request, wide_sources)
        tagged = narrowing(types, project_ids, sources, filters, custom).map {|tag, expr| "{!lucene tag=#{tag}}(#{expr})"}
        tagged += source_filter_clause(source_filter).map {|expr| "{!lucene tag=source}(#{expr})"}
        request[:fq] = [request[:fq], *tagged]
        request.merge!(rows: 0, fl: 'id', json: {facet: facet_definition(filters, custom_facets)}.to_json)
        res = @client.select(request)
        [res.dig('response', 'numFound'), read_facets(res['facets'] || {}, custom_facets)]
      end

      def facet_definition(filters = {}, custom_facets = [])
        unique = {containers: 'unique(group_id)'}
        definition = TYPE_FILTERS.to_h do |key, doc_types|
          [:"type_#{key}", {type: 'query', q: "type:(#{doc_types.join(' OR ')})", domain: {excludeTags: 'type'}, facet: unique}]
        end
        UPDATED_RANGES.each do |key, range|
          definition[:"updated_#{key}"] = {type: 'query', q: range, domain: {excludeTags: 'updated'}, facet: unique}
        end
        # the folders one level below the chosen one (the first level when none is chosen), within it: its own choice stays
        depth = self.class.folder_depth(filters[:folder]) || 0
        if depth < FOLDER_LEVELS
          definition[:folders] = {type: 'terms', field: "file_dir_#{depth + 1}", limit: FACET_LIMIT, sort: {containers: 'desc'}, facet: unique}
        end
        custom_facets.each {|custom| definition[:"cf_#{Integer(custom.id)}"] = custom_facet_definition(custom, unique) }
        definition[:source] = {type: 'terms', field: 'source', limit: 100, sort: {containers: 'desc'},
                               domain: {excludeTags: 'source'}, facet: unique}
        # the sources as the projects see them: without the choice of projects, with the choice of sources (D-49)
        definition[:sources_by_project] = {type: 'terms', field: 'source', limit: 100, sort: {containers: 'desc'},
                                           domain: {excludeTags: 'project'}, facet: unique}
        FACET_FIELDS.each do |name, field|
          # the tag of a choice is its key in ID_FILTERS or STRING_FILTERS ("tracker_ids"), of the projects "project"
          tag = name == :projects ? 'project' : FACET_FILTERS.fetch(name)
          definition[name] = {type: 'terms', field: field, limit: FACET_LIMIT, sort: {containers: 'desc'},
                              domain: {excludeTags: tag.to_s}, facet: unique}
        end
        definition
      end

      # One custom field, counted without its own choice, and only where the user may see the field (a field shown to some roles
      # only: the facet of a project the user cannot see it in would count values the user may not know)
      def custom_facet_definition(custom, unique)
        id = Integer(custom.id)
        domain = {excludeTags: "cf_#{id}"}
        domain[:filter] = PermissionFilter.terms('project_id', custom.project_ids) if custom.project_ids
        field = "#{CUSTOM_FIELD_PREFIX.fetch(custom.kind)}_#{id}"
        if custom.kind == :values
          {type: 'terms', field: field, limit: FACET_LIMIT, sort: {containers: 'desc'}, domain: domain, facet: unique}
        else # the range of what is there: the screen shows it beside the inputs
          {type: 'query', q: "#{field}:[* TO *]", domain: domain, facet: {min: "min(#{field})", max: "max(#{field})"}}
        end
      end

      # The filters of the custom facets as expressions by tag (cf_<id>): a value is chosen from what the facet showed, a range is
      # asked for as numbers or dates. Only for the fields in custom_facets (the ones the user may see), and in the projects where
      # the user may see them (a value of a field that is hidden elsewhere must not tell what is there).
      def custom_filter_expressions(custom_facets, custom_filters)
        custom_facets.each_with_object({}) do |custom, expressions|
          choice = (custom_filters || {})[custom.id] or next
          field = "#{CUSTOM_FIELD_PREFIX.fetch(custom.kind)}_#{Integer(custom.id)}"
          expression = case custom.kind
                       when :values then values_expression(field, choice[:values])
                       when :number then range_expression(field, number(choice[:min]), number(choice[:max]))
                       when :date then range_expression(field, date(choice[:from], 'T00:00:00Z'), date(choice[:to], 'T23:59:59Z'))
                       end
          next unless expression

          expression = "(#{expression} AND #{PermissionFilter.terms('project_id', custom.project_ids)})" if custom.project_ids
          expressions[:"cf_#{Integer(custom.id)}"] = expression
        end
      end

      def values_expression(field, values)
        values = Array(values).map(&:to_s).reject(&:empty?).uniq.first(MAX_CHOSEN_VALUES)
        return if values.empty?

        # one {!term} each: a value may hold a comma or a space; its quotes and backslashes are escaped
        "(#{values.map {|v| "{!term f=#{field} v='#{v.gsub(/[\\']/) {|c| "\\#{c}"}}'}" }.join(' OR ')})"
      end

      def range_expression(field, low, high)
        "#{field}:[#{low || '*'} TO #{high || '*'}]" if low || high
      end

      def number(value)
        number = Float(value.to_s, exception: false)
        number.to_s if number&.finite?
      end

      def date(value, time)
        "#{Date.iso8601(value.to_s)}#{time}" if value.present?
      rescue ArgumentError
        nil
      end

      def read_facets(facets, custom_facets = [])
        buckets = ->(name) { facets.dig(name.to_s, 'buckets') || [] }
        read = {
          types: TYPE_FILTERS.keys.to_h {|key| [key, facets.dig("type_#{key}", 'containers').to_i]},
          updated: UPDATED_RANGES.keys.to_h {|key| [key, facets.dig("updated_#{key}", 'containers').to_i]},
          sources: buckets.(:source).to_h {|b| [b['val'], b['containers']]},
          sources_by_project: buckets.(:sources_by_project).to_h {|b| [b['val'], b['containers']]}
        }
        FACET_FIELDS.each_key {|name| read[name] = buckets.(name).map {|b| [b['val'], b['containers']]} }
        read[:folders] = buckets.(:folders).map {|b| [b['val'], b['containers']]}
        read[:custom] = custom_facets.to_h do |custom|
          facet = facets["cf_#{Integer(custom.id)}"] || {}
          [custom.id, custom.kind == :values ? {values: buckets.(:"cf_#{custom.id}").map {|b| [b['val'], b['containers']]}} : {min: facet['min'], max: facet['max']}]
        end
        # pdf and PDF are one type; the containers of the two are told apart in Solr, so they are added (an external document
        # is its own container: exact; an issue with a pdf and a PDF attachment counts twice, which is rare)
        read[:file_types] = read[:file_types].group_by {|ext, _| ext.to_s.downcase }.map {|ext, rows| [ext, rows.sum(&:last)] }
                                             .sort_by {|ext, count| [-count, ext] }
        read
      end
    end
  end
end
