# frozen_string_literal: true

class MutantResultsReader
  RESULTS_DIRECTORY = ".mutant/results"
  RESULT_PATTERNS = [ "*.yml", "*.yaml" ].freeze

  def self.read(worktree_path)
    new(worktree_path:).read
  end

  def initialize(worktree_path:)
    @worktree_path = worktree_path
  end

  def read
    return nil if worktree_path.blank?
    return nil unless Dir.exist?(results_directory)

    result_path = latest_result_path
    return nil unless result_path

    raw_data = YAML.safe_load_file(result_path, permitted_classes: [ Symbol, Time ], aliases: true)
    return nil unless raw_data.is_a?(Hash)

    data = raw_data.deep_symbolize_keys
    total_mutations = extract_count(data, :total_mutations, :mutations_total, :total)
    killed_mutations = extract_count(data, :killed_mutations, :mutations_killed, :killed)
    return nil unless total_mutations && killed_mutations

    {
      total_mutations: total_mutations,
      killed_mutations: killed_mutations,
      source_path: result_path
    }
  end

  private

  attr_reader :worktree_path

  def results_directory
    File.join(worktree_path, RESULTS_DIRECTORY)
  end

  def latest_result_path
    RESULT_PATTERNS
      .flat_map { |pattern| Dir.glob(File.join(results_directory, pattern)) }
      .select { |path| File.exist?(path) }
      .max_by { |path| File.mtime(path) }
  end

  def extract_count(data, *keys)
    [ data, data[:summary], data[:totals] ].compact.each do |source|
      keys.each do |key|
        value = source[key]
        return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
      end
    end

    nil
  end
end
