# frozen_string_literal: true

# The parent of the plugin's models (design D-62): Redmine's ApplicationRecord where it has one (6.0 and later: it adds the
# translated attribute names), ActiveRecord::Base where it has none (5.1, whose models inherit that, and which adds the
# translated attribute names to ActiveRecord::Base itself).
class SolrSearchRecord < (defined?(::ApplicationRecord) ? ::ApplicationRecord : ActiveRecord::Base)
  self.abstract_class = true

  # A column kept as JSON (design D-62). Rails 7.1 takes the coder as a keyword (7.2 and later only so); Rails 6.1 (Redmine
  # 5.1) takes it as the second argument and would read the keyword as an option it ignores, keeping YAML: rows written on
  # 5.1 could then not be read after an upgrade.
  def self.serialize_json(*names)
    names.each do |name|
      if ActiveRecord.version >= Gem::Version.new('7.1')
        serialize name, coder: JSON
      else
        serialize name, JSON
      end
    end
  end
end
