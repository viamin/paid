# frozen_string_literal: true

module Inbox
  # Surfaces a layered-verification finding as an actionable Inbox item.
  #
  # The detail pane shows the obligation's scope and canonical source
  # reference, the conflicting source, model, or specification claims, the
  # observed implementation behavior, the check outcomes with their
  # limitations and the revision they were bound to, why a decision is
  # needed, and the possible resolutions with their consequences.
  #
  # A clean audit never produces an entry: only a finding that needs a human
  # decision does.
  #
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016
  class LayeredVerificationFinding
    def self.candidates(project_ids)
      LayeredVerificationFinding
        .where(project_id: project_ids)
        .where.not(status: "resolved")
        .includes(:obligation, :agent_run)
    end

    def self.call(finding)
      new(finding).call
    end

    def initialize(finding)
      @finding = finding
    end

    def call
      Snapshot.new(finding:, summary:, waiting_since:, detail:)
    end

    class Snapshot
      attr_reader :detail, :finding, :summary, :waiting_since

      def initialize(finding:, summary:, waiting_since:, detail:)
        @finding = finding
        @summary = summary
        @waiting_since = waiting_since
        @detail = detail
      end

      def deferred?
        finding.deferred?
      end

      def project
        finding.project
      end
    end

    private

    attr_reader :finding

    def summary
      return "#{finding.question} (deferred: #{finding.deferral_reason})" if finding.deferred?

      finding.question
    end

    def waiting_since
      finding.deferred_at || finding.created_at
    end

    def detail
      {
        "obligation" => obligation_detail,
        "source_passages" => Array(finding.source_passages),
        "claims" => claims,
        "observed_behavior" => finding.observed_behavior,
        "limitations" => finding.limitations,
        "check_outcomes" => check_outcomes,
        "question" => finding.question,
        "options" => Array(finding.options),
        "owner_actions" => Array(finding.owner_actions),
        "observations" => Array(finding.observations),
        "deferral" => deferral,
        "links" => links
      }
    end

    def obligation_detail
      obligation = finding.obligation
      {
        "external_identity" => obligation.external_identity,
        "scope" => obligation.scope_description,
        "framework" => obligation.framework,
        "approval_state" => obligation.approval_state,
        "external_revision" => obligation.external_revision,
        "approved_revision_reference" => obligation.approved_revision_reference
      }
    end

    def claims
      finding.obligation.correspondence_claims.map do |claim|
        {
          "claim_type" => claim.claim_type,
          "source_reference" => claim.source_reference,
          "target_reference" => claim.target_reference,
          "abstraction_boundaries" => claim.abstraction_boundaries,
          "assumptions" => claim.assumptions
        }
      end
    end

    def check_outcomes
      finding.check_results.order(:id).map do |result|
        {
          "check_result_id" => result.id,
          "producer" => result.producer,
          "execution_state" => result.execution_state,
          "obligation_coverage" => result.obligation_coverage,
          "limitations" => result.limitations,
          "evidence_ref" => result.evidence_ref,
          "bound_revision" => result.input_revision["external_revision"],
          "current_revision" => result.input_revision["external_revision"] == finding.external_revision
        }
      end
    end

    def deferral
      return {} unless finding.deferred?

      { "reason" => finding.deferral_reason, "deferred_at" => finding.deferred_at }
    end

    def links
      {
        "audit_run_id" => finding.agent_run_id,
        "obligation_external_identity" => finding.obligation.external_identity,
        "evidence_refs" => check_outcomes.filter_map { |outcome| outcome["evidence_ref"] }.uniq
      }
    end
  end
end
