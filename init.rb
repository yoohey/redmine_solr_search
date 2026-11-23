# Full-text search for Redmine backed by Solr (docs/design.md).
# lib/ is autoloaded by Redmine (SolrSearch::*); lib/tasks/*.rake are loaded by Redmine's Rakefile.
Redmine::Plugin.register :redmine_solr_search do
  name 'Redmine Solr Search'
  author 'yoohey'
  description 'Full-text search over Redmine data and external documents (shared folders and the like), backed by Solr'
  version '1.0.1'
  # 5.1 to 7.x (design D-62, chapter 13): Redmine compares each end with as many parts as it has, so '7' covers every 7.x
  requires_redmine version: '5.1'..'7'   # developed on 6.1; 5.1, 6.0 and 7.0 checked (design D-62, docs/experiments/redmine-versions)

  # Administration > Plugins > Configure (design D-28). Values are strings: '1' on, '0' off; numbers as text.
  # Read them through SolrSearch::Settings, which falls back on these defaults.
  # show_solr_request is off by default: the request shows internal URLs and project ids (design chapter 7)
  settings default: {# the Solr address set on the admin page (design D-43); empty: the environment variable SOLR_URL
                     'solr_url' => '',
                     # the collection of Redmine's data (design D-44); empty: redmine
                     'redmine_collection' => 'redmine',
                     # the Tika address set on the admin page (design D-61); empty: the environment variable TIKA_URL, then http://tika:9998
                     'tika_url' => '',
                     'expand_spelling_variants' => '1', 'show_solr_request' => '0', 'run_retention_days' => '30',
                     'search_timeout' => '10', 'admin_timeout' => '5',
                     # who can use the global search: 'all' (default), 'logged', 'with_permission'
                     'global_search_access' => 'all',
                     # the most words a search may have (design D-24); 1 to 20
                     'max_words' => '10',
                     # containers on a page of the search screen; 10 to 100
                     'per_page' => '50',
                     # style declarations for <span class="highlight"> on the search screen (M4 review, #13)
                     'highlight_style' => SolrSearch::Settings::DEFAULT_HIGHLIGHT_STYLE,
                     # the crawl scheduler (design D-22): each task on or off, every <number> <unit>
                     'schedule_incremental_enabled' => '1', 'schedule_incremental_every' => '10',
                     'schedule_incremental_unit' => 'minutes',
                     'schedule_resend_enabled' => '1', 'schedule_resend_every' => '1', 'schedule_resend_unit' => 'days',
                     'schedule_reconcile_enabled' => '1', 'schedule_reconcile_every' => '1',
                     'schedule_reconcile_unit' => 'days',
                     # attachments: Tika makes the text of the files (design D-36), a crawl of its own
                     'schedule_attachments_enabled' => '1', 'schedule_attachments_every' => '10',
                     'schedule_attachments_unit' => 'minutes',
                     # attachments: the extensions whose text is made, and the limits (design D-47)
                     'attachment_extensions' => SolrSearch::AttachmentText::DEFAULT_EXTENSIONS.join(' '),
                     'attachment_max_file_mb' => '50', 'attachment_max_text_mb' => '3',
                     # the optional external reranker (design D-56), set on the fine tuning tab: no address, no reranker. The key is
                     # the environment variable RERANKER_API_KEY, not a setting
                     'reranker_url' => '', 'reranker_format' => 'tei', 'reranker_model' => '', 'reranker_timeout' => '3',
                     'reranker_docs' => '40', 'reranker_chars' => '400'},
           partial: 'settings/solr_search_settings'

  # Full-text search project module and permissions (design D-32, D-34)
  project_module :solr_search do
    permission :use_solr_search, {solr_search: [:index]}, read: true
    permission :search_external_sources, {}, read: true
    permission :manage_solr_search_sources, {solr_search_project_sources: [:update]}, require: :member
  end

  # One search page outside any project (design chapter 7, R8); who sees what is decided per search (design Q-3)
  menu :top_menu, :solr_search, {controller: 'solr_search', action: 'index', project_id: nil},
       caption: :label_solr_search, after: :projects,
       if: Proc.new { SolrSearch.global_search_allowed?(User.current) }
  # The same page as a tab of the pages outside any project (Projects, Activity, Issues...), so the page shows its tab
  menu :application_menu, :solr_search, {controller: 'solr_search', action: 'index', project_id: nil},
       caption: :label_solr_search, last: true,
       if: Proc.new { SolrSearch.global_search_allowed?(User.current) }
  # Project menu: search scoped to the project (design D-24 R8, D-34)
  menu :project_menu, :solr_search, {controller: 'solr_search', action: 'index'},
       param: :project_id, caption: :label_solr_search, permission: :use_solr_search
  # Administration > Full-text search: the state of the search (design D-28)
  menu :admin_menu, :solr_search, {controller: 'solr_search_admin', action: 'index'},
       caption: :label_solr_search, icon: 'search', html: {class: 'icon icon-search'}
end

# A project deleted takes its links to external index sources with it, each kept as history (design D-32). init.rb
# runs in to_prepare (Redmine::PluginLoader), so Project is patched again after each reload, never twice.
unless Project.reflect_on_association(:solr_search_project_sources)
  Project.has_many :solr_search_project_sources, class_name: 'SolrSearchProjectSource', dependent: :destroy
  # and its allowances to link sources (design D-34)
  Project.has_many :solr_search_source_allowed_projects, class_name: 'SolrSearchSourceAllowedProject',
                                                         dependent: :destroy
end

# The icons of the plugin's pages, with or without Redmine 6.0's sprite_icon (design D-62)
ActionView::Base.include(SolrSearch::IconHelper) unless ActionView::Base.include?(SolrSearch::IconHelper)

unless ProjectsHelper.ancestors.include?(SolrSearch::ProjectsHelperPatch)
  ProjectsHelper.prepend(SolrSearch::ProjectsHelperPatch)
end
