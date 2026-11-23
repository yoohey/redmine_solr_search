# frozen_string_literal: true

# The crawl's state for Prometheus (design D-39, M6). Off unless SOLR_SEARCH_METRICS_TOKEN is set (404, as if it were
# not there); with it, a request must carry "Authorization: Bearer <token>". It has no Redmine login: the monitoring
# system is not a user. The reverse proxy in front of Redmine must not pass this path on (docker/nginx/entry.conf):
# Prometheus reads it from inside the network.
class SolrSearchMetricsController < ApplicationController
  skip_before_action :check_if_login_required

  before_action :authorize_metrics

  def index
    last_runs = SolrSearchRun::TASKS.index_with do |task|
      SolrSearchRun.finished.where(task: task).order(id: :desc).first
    end
    running = SolrSearchRun.where(status: 'running').distinct.pluck(:task)
    heartbeat = SolrSearchHeartbeat.find_by(name: SolrSearch::Scheduler::NAME)
    render plain: SolrSearch::Metrics.render(heartbeat: heartbeat, last_runs: last_runs, running: running,
                                             counters: SolrSearch::Counters.all,
                                             golden: SolrSearchGoldenRun::KINDS.index_with {|kind| SolrSearchGoldenRun.latest(kind)}),
           content_type: SolrSearch::Metrics::CONTENT_TYPE
  end

  # How the index is against Redmine (design D-45): asks Solr, so it is a page of its own, read by its own job with a longer time
  # limit; the page above reads the database alone and does not wait for Solr. Solr that does not answer is a 0 in
  # solr_search_index_up, not an error of the page.
  def index_health
    # no address of Solr at all is Solr that does not answer, not an error of this page (M6 review 7)
    client = begin
      SolrSearch::Status.admin_client
    rescue SolrSearch::Client::Error
      nil
    end
    data = SolrSearch::IndexHealth.gather(client: client)
    render plain: SolrSearch::IndexHealth.render(data), content_type: SolrSearch::Metrics::CONTENT_TYPE
  end

  private

  # Off unless a token is set (404, as if the page were not there); with one, it must be given as a Bearer token
  def authorize_metrics
    token = ENV[SolrSearch::Metrics::ENV_TOKEN].to_s
    return head :not_found if token.empty?
    return if token_given?(token)

    response.headers['WWW-Authenticate'] = 'Bearer realm="solr_search"'
    head :unauthorized
  end

  # Compared by their digests, so that the time it takes does not tell how much of a guess was right
  def token_given?(token)
    given = request.authorization.to_s[/\ABearer (.+)\z/, 1].to_s
    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(given), Digest::SHA256.hexdigest(token))
  end
end
