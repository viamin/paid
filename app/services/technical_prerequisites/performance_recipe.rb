# frozen_string_literal: true

module TechnicalPrerequisites
  # Validates the reviewed, structured contract that makes a performance
  # comparison repeatable. Repository prose never becomes executable input.
  # @spec PARTIAL-CLOSEOUT-041
  class PerformanceRecipe
    SHA = /\A[0-9a-f]{40}\z/i
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

    def payload = requirement.measurement_recipe.to_h.deep_stringify_keys

    def complete?
      current_commit_sha.match?(SHA) && payload["baseline_commit_sha"].to_s.match?(SHA) &&
        workload_complete? && Array(payload["metrics"]).all? { |metric| metric.is_a?(String) && metric.present? } &&
        Array(payload["metrics"]).any? && payload["samples"].to_i.between?(2, 50) &&
        payload["environment"].is_a?(String) && payload["environment"].present? &&
        payload["budget_seconds"].to_i.positive? && artifact_contract_complete?
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
