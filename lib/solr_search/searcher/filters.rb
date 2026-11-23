# frozen_string_literal: true

module SolrSearch
  class Searcher
    # The narrowing of a search by what the user chose (types, projects, update date, attributes, folders, sources; design D-33, D-49). Moved here from Searcher; nothing changed.
    module Filters
      private

      # The user's own narrowing (R5), on top of the permission filter. Explicit OR, like the permission filter; the
      # projects as a set of ids written as there (PermissionFilter.terms; Gemini review 2026-10-04, item 2).
      # An external document has no project_id: the sources, already narrowed to the chosen projects, pass this one too
      def narrowing_filters(types, project_ids, sources = [], filters = {}, custom = {})
        narrowing(types, project_ids, sources, filters, custom).values
      end

      # The same as a hash by what is chosen (:type, :project), so that a facet can leave out its own
      def narrowing(types, project_ids, sources, choices = {}, custom = {})
        filters = {}
        if types.present?
          doc_types = TYPE_FILTERS.values_at(*types).compact.flatten
          filters[:type] = doc_types.empty? ? NOTHING : "type:(#{doc_types.join(' OR ')})"
        end
        unless project_ids.nil?
          clause = project_ids.empty? ? NOTHING : PermissionFilter.terms('project_id', project_ids)
          filters[:project] = or_sources(clause, sources)
        end
        filters[:updated] = UPDATED_RANGES[choices[:updated]] if UPDATED_RANGES.key?(choices[:updated])
        ID_FILTERS.each do |key, field|
          ids = Array(choices[key]).filter_map {|id| Integer(id, exception: false)}
          filters[key] = PermissionFilter.terms(field, ids) if ids.any?
        end
        filters.merge!(custom)
        if (path = choices[:folder]) && (depth = self.class.folder_depth(path))
          filters[:folder] = "{!term f=file_dir_#{depth} v='#{path.chomp('/')}'}"
        end
        STRING_FILTERS.each do |key, field|
          values = Array(choices[key]).map(&:to_s).grep(STRING_VALUE).uniq.sort
          # the extension is indexed as it was written: the usual spellings of it (pdf, PDF, Pdf) are all let through
          values = values.flat_map {|v| [v, v.upcase, v.capitalize] }.uniq if key == :file_exts
          filters[key] = "{!terms f=#{field} v='#{values.join(',')}'}" if values.any?
        end
        filters
      end

      # Only these sources ('redmine' is the value of Redmine's own data). The names are checked by the caller.
      def source_filter_clause(source_filter)
        return [] if source_filter.empty?

        ["{!terms f=source v='#{source_filter.sort.join(',')}'}"]
      end
    end
  end
end
