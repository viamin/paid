# frozen_string_literal: true

module LayeredVerification
  # Persists an explicit uncertainty when structural discovery sees material not
  # represented by a correspondence claim. Semantic interpretation remains a
  # bounded agent_harness responsibility at audit execution.
  # @spec LAYERED-VERIFY-009
  class LinkageFreshness
    LIMITATION = "Structural discovery cannot establish semantic completeness; bounded semantic read-through via agent_harness remains required."

    def self.call(...) = new(...).call

    def initialize(agent_run:, obligation:, material:, limitations: [])
      @agent_run = agent_run
      @obligation = obligation
      @material = material
      @limitations = Array(limitations)
    end

    def call
      LayeredVerificationCheckResult.create!(
        obligation:, agent_run:, producer: "linkage_freshness", execution_state: "incomplete",
        obligation_coverage: "unresolved", input_revision: input_revision,
        evidence_summary: { "unmapped_material" => material }, agent_reported: {}, recorder_verified: { "structural_diff" => true },
        cost: {}, limitations: [ LIMITATION, *@limitations ].join(" ")
      )
    end

    private

    attr_reader :agent_run, :limitations, :material, :obligation

    def input_revision
      { "code" => agent_run.external_metadata.dig("layered_verification", "target_revision"),
        "external_revision" => obligation.external_revision,
        "dependencies" => agent_run.external_metadata.dig("layered_verification", "dependencies") || {} }.compact
    end
  end
end
