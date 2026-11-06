# frozen_string_literal: true

module TechnicalPrerequisites
  # Validates the reviewed, structured contract that makes a performance
  # comparison repeatable. Repository prose never becomes executable input.
  # @spec PARTIAL-CLOSEOUT-041
  class PerformanceRecipe
    SHA = /\A[0-9a-f]{40}\z/i
    # TechnicalPrerequisiteValidationJob terminates at a 20-minute
    # perform_timeout. Cap the reviewed total measurement budget below that,
    # leaving headroom for provisioning, dual-revision checkout, and cleanup so
    # a completed comparison is always persisted as durable evidence.
    MAX_BUDGET_SECONDS = 15 * 60
    Result = Data.define(:recipe, :error) do
      def valid? = error.nil?
    end

    def self.call(...) = new(...).call

    def initialize(requirement:, current_commit_sha:)
      @requirement = requirement
      @current_commit_sha = current_commit_sha
    end

    def call
      return Result.new(recipe: nil, error: "Select a reviewed performance recipe with complete provenance.") unless complete?

      Result.new(recipe: payload.merge("current_commit_sha" => current_commit_sha), error: nil)
    end

    private

    attr_reader :requirement, :current_commit_sha

    def payload = @payload ||= requirement.measurement_recipe.to_h.deep_stringify_keys

    def complete?
      revisions_pinned? && revisions_distinct? && workload_complete? && metrics_complete? &&
        samples_complete? && environment_complete? && budget_complete? && artifact_contract_complete? &&
        requires_browser_valid?
    end

    # Validation is strict, not coercive: the persisted payload is consumed
    # as-is by ValidateExecution (`samples` gets `.times`, `metrics` gets
    # `.to_h`), so a string that survives `"3".to_i` here would crash sampling
    # after the budget was spent. Only exact types admit a recipe.
    def metrics_complete?
      metrics = payload["metrics"]
      metrics.is_a?(Array) && metrics.any? && metrics.all? { |metric| metric.is_a?(String) && metric.present? }
    end

    def samples_complete?
      samples = payload["samples"]
      samples.is_a?(Integer) && samples.between?(2, 50)
    end

    def budget_complete?
      budget = payload["budget_seconds"]
      budget.is_a?(Numeric) && budget.to_f.between?(1, MAX_BUDGET_SECONDS)
    end

    def environment_complete?
      payload["environment"].is_a?(String) && payload["environment"].present?
    end

    # A baseline pinned to the produced revision — a copy/paste slip or a
    # case variant, since a SHA is case-insensitive — is a self-comparison:
    # both sample sets would collapse onto one revision and present identical
    # percentiles as a complete before/after result.
    def revisions_distinct?
      payload["baseline_commit_sha"].to_s.downcase != current_commit_sha.to_s.downcase
    end

    def revisions_pinned?
      current_commit_sha.to_s.match?(SHA) && payload["baseline_commit_sha"].to_s.match?(SHA)
    end

    # Optional attestation: the isolated runner never provisions a browser
    # sidecar for a performance measurement, so a recipe that explicitly
    # declares this need is accepted here (its provenance is still valid) but
    # is held unavailable at capability inspection instead of being silently
    # measured in an environment that cannot satisfy it.
    def requires_browser_valid?
      payload["requires_browser"].nil? || [ true, false ].include?(payload["requires_browser"])
    end

    def workload_complete?
      workload = payload["workload"]
      workload.is_a?(Hash) && workload["identity"].present? && workload["provenance"].present? && workload["representative"] == true
    end

    def artifact_contract_complete?
      contract = Array(payload["artifact_contract"])
      contract.include?("raw_samples") && contract.include?("comparison")
    end
  end
end
