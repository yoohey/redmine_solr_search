# frozen_string_literal: true

get 'solr_search', to: 'solr_search#index', as: 'solr_search'
# a click on a result of the list, sent by the screen's script (design D-45)
post 'solr_search/click', to: 'solr_search#click', as: 'solr_search_click'
# project menu and project settings (design D-24 R8, D-34)
get 'projects/:project_id/solr_search', to: 'solr_search#index', as: 'project_solr_search'
post 'projects/:project_id/solr_search/sources', to: 'solr_search_project_sources#update',
                                                 as: 'project_solr_search_sources'

# the crawl's state for Prometheus (design D-39); off unless SOLR_SEARCH_METRICS_TOKEN is set
get 'solr_search/metrics', to: 'solr_search_metrics#index', as: 'solr_search_metrics'
# how the index is against Redmine (design D-45): asks Solr, so a page of its own
get 'solr_search/metrics/index', to: 'solr_search_metrics#index_health', as: 'solr_search_metrics_index'

get 'admin/solr_search', to: 'solr_search_admin#index', as: 'solr_search_admin'
# the admin page's other tabs (design D-34)
get 'admin/solr_search/reindex', to: 'solr_search_admin#reindex', as: 'solr_search_admin_reindex'
get 'admin/solr_search/reindex/inspect', to: 'solr_search_admin#reindex_inspect', as: 'solr_search_admin_reindex_inspect'
get 'admin/solr_search/reindex/estimate', to: 'solr_search_admin#reindex_estimate', as: 'solr_search_admin_reindex_estimate'
get 'admin/solr_search/sources', to: 'solr_search_admin#sources', as: 'solr_search_admin_sources'
get 'admin/solr_search/changes', to: 'solr_search_admin#changes', as: 'solr_search_admin_changes'
# the fine tuning of the order of the results (design D-51, Q-34): the form, the saving or a trial search, and the return to the defaults
get 'admin/solr_search/tuning', to: 'solr_search_tuning#tuning', as: 'solr_search_admin_tuning'
post 'admin/solr_search/tuning', to: 'solr_search_tuning#update_tuning', as: 'solr_search_admin_update_tuning'
post 'admin/solr_search/tuning/reset', to: 'solr_search_tuning#reset_tuning', as: 'solr_search_admin_reset_tuning'
# the query expansion dictionary (design D-53, Q-27): the form, the saving or a trial search, and the emptying
get 'admin/solr_search/synonyms', to: 'solr_search_tuning#synonyms', as: 'solr_search_admin_synonyms'
post 'admin/solr_search/synonyms', to: 'solr_search_tuning#update_synonyms', as: 'solr_search_admin_update_synonyms'
get 'admin/solr_search/synonyms/export', to: 'solr_search_tuning#export_synonyms', as: 'solr_search_admin_export_synonyms'
post 'admin/solr_search/synonyms/reset', to: 'solr_search_tuning#reset_synonyms', as: 'solr_search_admin_reset_synonyms'
# the search log (design D-45): the list, and the deletion (only by an administrator's own act)
get 'admin/solr_search/log', to: 'solr_search_log#search_log', as: 'solr_search_admin_log'
delete 'admin/solr_search/log', to: 'solr_search_log#delete_search_log', as: 'solr_search_admin_delete_log'
# the log as a zip of CSV files, for work by hand
get 'admin/solr_search/log/export', to: 'solr_search_log#export_search_log', as: 'solr_search_admin_log_export'
# the Solr address, set on the status tab (design D-43)
post 'admin/solr_search/solr_url', to: 'solr_search_admin#update_solr_url', as: 'solr_search_admin_solr_url'
post 'admin/solr_search/tika_url', to: 'solr_search_admin#update_tika_url', as: 'solr_search_admin_tika_url'
# a reindex asked for on the status tab (design D-42): written as a request; the scheduler runs it
post 'admin/solr_search/requests', to: 'solr_search_admin#create_request', as: 'solr_search_admin_requests'
delete 'admin/solr_search/requests/:id', to: 'solr_search_admin#cancel_request', as: 'solr_search_admin_request'
resources :solr_search_sources, path: 'admin/solr_search/sources', only: [:new, :create, :edit, :update, :destroy]
