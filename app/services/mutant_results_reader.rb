# frozen_string_literal: true

require "shellwords"

class MutantResultsReader
  RESULTS_DIRECTORY = ".mutant/results"
  RESULT_PATTERNS = [ "*.yml", "*.yaml" ].freeze
  ENV_ASSIGNMENT_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*=.*/.freeze

  def self.read(worktree_path)
    new(worktree_path:).read
  end

  def self.with_results_dir(command)
    return command if command.blank?

    tokens = Shellwords.split(command)
    return command if tokens.empty?

    env_tokens, command_tokens = split_env_prefix(tokens)
    stripped = []
    index = 0

    while index < command_tokens.length
      case command_tokens[index]
      when "--results-dir"
        index += 2
      when /\A--results-dir=/
        index += 1
      else
        stripped << command_tokens[index]
        index += 1
      end
    end

    normalized_env = ensure_test_env(env_tokens)
    normalized_command = stripped + [ "--results-dir", RESULTS_DIRECTORY ]

    [ normalized_env.join(" "), Shellwords.join(normalized_command) ].reject(&:blank?).join(" ")
  end

  def self.split_env_prefix(tokens)
    env_tokens = []
    index = 0

    while index < tokens.length && tokens[index].match?(ENV_ASSIGNMENT_PATTERN)
      env_tokens << tokens[index]
      index += 1
    end

    [ env_tokens, tokens.drop(index) ]
  end
  private_class_method :split_env_prefix

  def self.ensure_test_env(env_tokens)
    return env_tokens if env_tokens.any? { |token| token.start_with?("RAILS_ENV=") }

    env_tokens + [ "RAILS_ENV=test" ]
  end
  private_class_method :ensure_test_env

  def initialize(worktree_path:)
    @worktree_path = worktree_path
  end

  def read
    return nil if worktree_path.blank?
    return nil unless Dir.exist?(results_directory)

    result_path = latest_result_path
    return nil unless result_path

    raw_data = YAML.safe_load_file(result_path, permitted_classes: [], aliases: false)
    return nil unless raw_data.is_a?(Hash)

    total_mutations = extract_count(raw_data, "total_mutations")
    killed_mutations = extract_count(raw_data, "killed") || extract_count(raw_data, "killed_mutations")
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

  def extract_count(data, key)
    [ data, data["summary"] ].compact.each do |source|
      value = source[key]
      return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)
    end

    nil
  end
end
