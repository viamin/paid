# frozen_string_literal: true

module PartialCloseouts
  # Schedules the one bounded recovery audit that a merged-partial guard would
  # otherwise require an operator to request manually. All authority remains
  # in the existing project gate and continuation admission service.
  # @spec PARTIAL-CLOSEOUT-024
  class Advance
    Result = Data.define(:agent_run, :code) do
      def scheduled? = agent_run.present?
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, assessment:)
      @agent_run = agent_run
      @assessment = assessment.to_h.deep_stringify_keys
    end

    def call
      return record(Result.new(agent_run: nil, code: :source_run_in_flight)) unless agent_run.finished?
      return record(Result.new(agent_run: nil, code: :remaining_work)) if gaps.present?
      return record(Result.new(agent_run: nil, code: :automation_disabled)) unless project_gate_open?

      result = Issues::RequestContinuation.call(
        issue: agent_run.issue,
        actor: agent_run.project.effective_owner,
        reason: "Paid scheduled a fresh acceptance audit after current evidence superseded the prior partial-closeout gaps.",
        origin: :automatic
      )
      record(Result.new(agent_run: result.agent_run, code: result.code))
    end

    private

    attr_reader :agent_run, :assessment

    def gaps = Array(assessment["gaps"])

    def project_gate_open?
      Issues::AutoPickProjectGate.call(agent_run.project)
    end

    def record(result)
      agent_run.update!(
        reconciliation: agent_run.reconciliation.merge(
          "advance" => {
            "action" => "fresh_acceptance_audit",
            "outcome" => result.scheduled? ? "scheduled" : "waiting",
            "code" => result.code&.to_s,
            "continuation_request_id" => result.agent_run&.continuation_request_id,
            "at" => Time.current.iso8601
          }.compact
        )
      )
      result
    end
  end
end
