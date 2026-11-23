# frozen_string_literal: true

# What the parts of the plugin share (the classes are in lib/solr_search/).
module SolrSearch
  # The collection of Redmine's data, and the value of its documents' source field (docs/schema.md)
  COLLECTION = 'redmine'
  SOURCE = 'redmine'

  # The configset of external documents: only collections made from it can be external index sources (design D-35)
  SOURCE_CONFIGSET = 'src'

  # Solr's own rule for collection names (SolrIdentifierValidator, Solr 9.10.1). An external source's collection name
  # is also the source value of its documents and goes as it is into the filter that lets them through (D-33).
  COLLECTION_NAME = /\A(?!-)(?!\.+\z)[._A-Za-z0-9-]+\z/ # not "." or ".." (a path of its own in an address)

  # The collection of Redmine's data in use: the one set on the admin page, COLLECTION until then (design D-44). Read at
  # each call, so that a change is used by the next request and the scheduler's next tick. COLLECTION when there is no
  # Redmine around (the light tests).
  def self.collection
    defined?(::Setting) ? Settings.redmine_collection : COLLECTION
  end

  # Whether a collection may be an external index source: a valid name, and never the collection of Redmine's data,
  # whose documents the filter would then let through without the permission conditions (design D-35). Nor a collection
  # named SOURCE ("redmine"), whatever the Redmine collection is called: the documents of Redmine's data carry
  # source:redmine whatever the collection's name, and an external collection's chain makes its documents' source the
  # collection's name, so such a collection's documents would look like Redmine's (design D-38, D-44; M6 review 1).
  def self.external_collection?(name)
    name.is_a?(String) && COLLECTION_NAME.match?(name) && name != collection && name != SOURCE
  end

  # Redmine's log, marked [solr_search]: what the run records cannot tell (where a failure happened, a run that hangs)
  # is looked up here. In the official Docker image it goes to stdout (RAILS_LOG_TO_STDOUT), i.e. docker compose logs.
  def self.log(level, message)
    Rails.logger.public_send(level, "[solr_search] #{message}")
  end

  GLOBAL_SEARCH_ACCESS = %w[all logged with_permission].freeze

  # The setting global_search_access as one of GLOBAL_SEARCH_ACCESS. A value that is none of them (a typo, an old save)
  # is taken as the strictest: this setting only ever narrows who may search, and an admin always may.
  def self.global_search_access(value = Settings['global_search_access'])
    GLOBAL_SEARCH_ACCESS.include?(value) ? value : 'with_permission'
  end

  # Whether a user may open and use the global full-text search (/solr_search), by the plugin setting
  # global_search_access. has_permission is asked only when the mode needs it ('with_permission', for a user who is
  # not an admin), because the top menu asks on every page.
  def self.global_search_allowed?(user = User.current, access: global_search_access, &has_permission)
    case access
    when 'all' then true
    when 'logged' then user.logged?
    else user.admin? || (has_permission || -> { any_use_permission?(user) }).call
    end
  end

  # Whether the user may use the search in some project; once per request and user
  def self.any_use_permission?(user)
    cache = Current.use_permission ||= {}
    cache.fetch(user.id) { cache[user.id] = Project.allowed_to(user, :use_solr_search).exists? }
  end

  # The version the plugin's migrations name (design D-62): the Rails in use, but no later than 7.2, which they were written
  # for. On Redmine 6.x and 7.x (Rails 7.2 and 8.x) the tables are made as before; Redmine 5.1 (Rails 6.1) knows no 7.2.
  def self.migration_version
    [ActiveRecord::Migration.current_version, 7.2].min
  end
end
