# frozen_string_literal: true

require 'yaml'

module SolrSearch
  # Runs a golden query set (design D-45; the arithmetic is in Golden) and writes the run to solr_search_golden_runs. Each
  # search is made as the user: Searcher with that user's permission filter, the whole list at once.
  class GoldenRunner
    SEED_DIR = File.join(File.expand_path('../..', __dir__), 'docker', 'seed')
    FILES = {'coverage' => 'expected.yml', 'ranking' => 'golden.yml'}.freeze
    # without DATASET: the first of these that is there. The public repository has ja-basic only (O-58).
    DATASETS = %w[ja-cf ja-basic].freeze

    def self.default_dataset(seed_dir: SEED_DIR)
      DATASETS.find {|name| File.file?(File.join(seed_dir, name, 'expected', FILES['coverage'])) } || DATASETS.first
    end

    attr_reader :dataset

    # dataset: the folder name under docker/seed (expected/expected.yml for set A, expected/golden.yml for set B)
    def initialize(dataset:, seed_dir: nil, note: nil, logger: nil)
      @dataset = dataset
      @seed_dir = seed_dir || SEED_DIR
      @note = note.presence
      @logger = logger || ->(_msg) {}
    end

    # The sets (coverage, ranking) whose file this data set has.
    def available_sets
      FILES.keys.select {|set| File.file?(path(FILES[set])) }
    end

    def coverage
      expected = load_set('coverage')
      rows = []
      timed do
        expected['words'].each do |entry|
          expected['users'].each do |login|
            want = Golden.wanted(entry, login)
            got = search(entry['word'], login, dictionary: QueryDictionary.empty) # the word as it is: expected.yml holds what the word itself matches
            rows << Golden.coverage_row(want, got).merge(query: entry['word'], user: login) unless want.empty? && got.empty?
          end
        end
      end
      totals = Golden.coverage_totals(rows)
      record('coverage', rows.size, totals, Golden.coverage_details(rows))
    end

    def ranking
      cases = Golden.cases(load_set('ranking'))
      ranked = nil
      timed do
        ranked = cases.map do |c|
          got = search(c[:query], c[:user])
          c.merge(rank: Golden.best_rank(c[:expect], got), first: got.first(3))
        end
      end
      totals = Golden.ranking_totals(ranked)
      record('ranking', ranked.size, totals, Golden.ranking_details(ranked))
    end

    private

    def load_set(set)
      file = path(FILES.fetch(set))
      unless File.file?(file)
        raise Golden::Invalid, "#{set}: the data set #{@dataset.inspect} has no #{FILES[set]} (DATASET=<folder under docker/seed>, SET=coverage or ranking)"
      end

      YAML.safe_load(File.read(file)) # not safe_load_file: Psych 3.3, newer than Ruby 2.7's
    end

    def path(file)
      File.join(@seed_dir, @dataset, 'expected', file)
    end

    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      @duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    def user_named(login)
      @users ||= {}
      @users[login] ||= login == 'anonymous' ? User.anonymous : User.find_by(login: login)
      raise Golden::Invalid, "no user with the login #{login.inspect}" unless @users[login]

      @users[login]
    end

    # the containers of the list, in the order of the list, for a search as the user
    def search(text, login, dictionary: SolrSearchSynonym.dictionary)
      result = Searcher.new(user: user_named(login), tuning: SolrSearchTuning.current, dictionary: dictionary).search(text, per_page: 100_000, detail: false)
      result ? result.groups.map(&:group_id) : []
    end

    def record(kind, queries, totals, details)
      run = SolrSearchGoldenRun.create!(
        kind: kind, dataset: @dataset, ran_at: Time.current, duration_ms: @duration_ms, queries: queries,
        expected: totals[:expected], found: totals[:found], leaks: totals[:leaks].to_i, recall: totals[:recall],
        precision: totals[:precision], mrr: totals[:mrr], recall_at_k: totals[:recall_at_k], k: totals[:k],
        note: @note, details: details.to_json
      )
      @logger.call("#{kind}: #{queries} searches in #{@duration_ms} ms")
      run
    end
  end
end
