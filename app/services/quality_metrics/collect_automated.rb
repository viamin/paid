# frozen_string_literal: true

module QualityMetrics
  # Collects automated quality metrics after an agent run completes.
  # Scores are based on observable outcomes: PR creation, CI status,
  # iteration count, lint cleanliness, and test results.
  #
  # @example
  #   QualityMetrics::CollectAutomated.call(agent_run: agent_run)
  class CollectAutomated
    attr_reader :agent_run

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def self.call(...)
      new(...).collect
    end

    # @return [QualityMetric] The created or updated quality metric
    def collect
      scores = {
        "pr_created" => pr_created_score,
        "ci_passed" => ci_passed_score,
        "iterations" => iterations_score,
        "lint_clean" => lint_clean_score,
        "tests_pass" => tests_pass_score
      }

      metric = agent_run.quality_metrics.find_or_initialize_by(metric_type: "automated")
      metric.prompt_version = agent_run.prompt_version
      metric.scores = scores
      metric.feedback_source = "system"
      metric.composite_score = metric.calculate_composite_score
      metric.save!
      metric
    end

    private

    # PR created: 1.0 if a PR URL exists, 0.0 otherwise
    def pr_created_score
      agent_run.pull_request_url.present? ? 1.0 : 0.0
    end

    # TODO(#145): ci_passed, lint_clean, and tests_pass currently use the same
    # proxy (agent_run.successful?). Replace with distinct signals from GitHub
    # PR status checks once webhook integration is available.

    # CI passed: proxy via run success until GitHub CI status is available.
    def ci_passed_score
      success_proxy_score
    end

    # Iterations: fewer is better, normalized to 0..1.
    # Formula from RDR-009: max(1.0 - (iterations - 1) * 0.1, 0.0)
    def iterations_score
      iterations = [ agent_run.iterations || 0, 1 ].max
      [ 1.0 - ((iterations - 1) * 0.1), 0.0 ].max
    end

    # Lint clean: proxy via run success until PR status checks are available.
    def lint_clean_score
      success_proxy_score
    end

    # Tests pass: proxy via run success until PR status checks are available.
    def tests_pass_score
      success_proxy_score
    end

    # Shared proxy: 1.0 if the agent run completed successfully, 0.0 otherwise.
    # Used by ci_passed, lint_clean, and tests_pass until distinct signals are available.
    def success_proxy_score
      agent_run.successful? ? 1.0 : 0.0
    end
  end
end
