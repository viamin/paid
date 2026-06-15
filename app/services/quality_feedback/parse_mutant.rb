# frozen_string_literal: true

require "yaml"

module QualityFeedback
  class ParseMutant
    RESULTS_GLOB = ".mutant/results/*.yml"

    def self.call(...)
      new(...).call
    end

    def initialize(worktree_path:)
      @worktree_path = worktree_path
    end

    def call
      result_files = Dir[File.join(worktree_path, RESULTS_GLOB)].sort
      return empty_result if result_files.empty?

      errors = result_files.flat_map do |path|
        alive_mutations(path).map { |mutation| build_error(mutation) }
      end

      QualityFeedbackService::CheckResult.new(
        type: :mutation_test,
        success: errors.empty?,
        errors: errors,
        warnings: [],
        raw_output: result_files.join("\n")
      )
    end

    private

    attr_reader :worktree_path

    def empty_result
      QualityFeedbackService::CheckResult.new(
        type: :mutation_test,
        success: true,
        errors: [],
        warnings: [],
        raw_output: ""
      )
    end

    def alive_mutations(path)
      data = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      Array(data["alive_mutations"])
    rescue Psych::Exception
      []
    end

    def build_error(mutation)
      subject = mutation["subject"]
      subject_path = mutation["subject_path"]
      source_line = mutation["source_line"]
      mutation_diff = mutation["mutation_diff"]

      {
        file: subject_path.to_s,
        line: source_line,
        message: "Surviving mutation in #{subject}: #{mutation_diff}. Strengthen the test or delete redundant production code if the mutation proves the behavior is unnecessary.",
        rule: "alive_mutation",
        severity: "high"
      }
    end
  end
end
