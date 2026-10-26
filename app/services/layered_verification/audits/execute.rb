# frozen_string_literal: true

require "set"

module LayeredVerification
  module Audits
    # Executes the checks an audit's plan selected, records every outcome as a
    # `LayeredVerificationCheckResult`, and synthesizes the audit's coverage.
    #
    # A check the run cannot execute is recorded explicitly (`not_run`,
    # `incomplete`, or `non_applicable`) with a stated reason — never
    # dropped. A contradicted obligation does not abort the audit: its
    # dependent checks wait for a decision while independent checks continue,
    # and the audit completes with the findings it recorded.
    #
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-024
    class Execute
      PRODUCER_ASSESSMENT = "implementation_conformance"
      PRODUCER_SEMANTIC_AUDIT = "semantic_audit"
      PRODUCER_FORMAL_VERIFICATION = "formal_verification"

      def self.call(...)
        new(...).call
      end

      def initialize(audit:, source_reader: nil, executor: nil, assessment: nil)
        @audit = audit
        @source_reader = source_reader
        @executor = executor
        @assessment = assessment
      end

      def call
        return audit if audit.terminal?

        mark_running
        results = run_checks
        return cancel if cancelled?

        findings = record_findings(results)
        report = SynthesizeCoverage.call(audit:, obligations:, check_results: results, findings:)
        finish(report, findings: findings)
      end

      private

      attr_reader :assessment, :audit, :executor, :source_reader

      def obligations
        @obligations ||= audit.project.layered_verification_obligations
          .where(external_identity: planned_obligation_identities)
          .order(:id)
          .to_a
      end

      def mark_running
        audit.update!(status: "running", waiting_reason: nil)
        agent_run.update!(status: "running", started_at: Time.current, completed_at: nil)
      end

      def run_checks
        blocked = Set.new
        results = []

        planned_checks.each do |check|
          break if cancelled?

          obligation = obligation_for(check)
          next unless obligation

          if blocked.include?(obligation.id)
            results << record_not_run(obligation, check, "waiting for a decision on the contradicted finding for this obligation")
            next
          end

          if results.size >= max_checks
            results << record_not_run(obligation, check, "the audit's check budget was exhausted before this check ran")
            break
          end

          result = execute_check(check, obligation)
          results << result
          blocked << obligation.id if result.obligation_coverage == "contradicted"
        end

        results
      end

      def execute_check(check, obligation)
        case check["producer"]
        when PRODUCER_FORMAL_VERIFICATION then run_formal_verification(check, obligation)
        when PRODUCER_ASSESSMENT, PRODUCER_SEMANTIC_AUDIT then run_assessment(check, obligation)
        else record_not_run(obligation, check, "no supported command or adapter runs this producer in the current release")
        end
      end

      def run_formal_verification(check, obligation)
        model = audit.plan.dig("artifacts", "formal_model") || formal_model
        TlcRunner.call(
          project: audit.project,
          obligation: obligation,
          model: model,
          executor: executor || ContainerExecutor.new(agent_run: agent_run),
          agent_run: agent_run
        )
      rescue StandardError => e
        Rails.logger.error(
          message: "layered_verification.formal_verification_failed",
          audit_id: audit.id,
          error_class: e.class.name,
          error: e.message
        )
        record_not_run(obligation, check, "the model check could not be executed")
      end

      def run_assessment(check, obligation)
        claim = ensure_claim(check, obligation)
        source, target = source_and_target(check, claim)

        return record_incomplete(obligation, check, source[:error]) if source[:error]

        assessment_for(check, obligation, claim, source, target)
      end

      def assessment_for(check, obligation, claim, source, target)
        assessor = assessment || CorrespondenceAssessment.new(
          project: audit.project,
          obligation: obligation,
          claim: claim,
          source: source,
          target: target,
          producer: check["producer"],
          agent_run: agent_run
        )
        assessor.call.check_result
      end

      def ensure_claim(check, obligation)
        claim_type = check["claim_type"].to_s
        return if claim_type.blank?

        EnsureClaim.call(
          obligation: obligation,
          claim_type: claim_type,
          source_reference: source_path(check, 0),
          target_reference: source_path(check, 1)
        )
      end

      def source_and_target(check, claim)
        source_path = source_path(check, 0)
        target_path = source_path(check, 1)
        target_path = claim&.target_reference if target_path.blank? && claim&.target_reference.present?

        [ read(source_path), read(target_path) ]
      end

      def source_path(check, index)
        inputs = Array(check["required_inputs"]).filter_map { |input| path_from(input) }
        inputs[index] || audit.sources.to_a[index]&.dig("path") || audit.sources.to_a.first&.dig("path")
      end

      def path_from(input)
        value = input.to_s.strip
        return if value.blank?
        return if value.start_with?("/")
        return if value.split("/").include?("..")

        value
      end

      def read(path)
        return { "path" => path, "content" => nil, "error" => "no source path was resolved for this check" } if path.blank?

        reader = source_reader || Sources::Read.new(project: audit.project, revision: audit.target_revision)
        result = reader.call(path)
        { "path" => path, "content" => result.content, "error" => result.error }
      end

      def record_not_run(obligation, check, reason)
        record(obligation:, check:, execution_state: "not_run", obligation_coverage: "unresolved", limitations: reason)
      end

      def record_incomplete(obligation, check, reason)
        record(obligation:, check:, execution_state: "incomplete", obligation_coverage: "unresolved", limitations: reason)
      end

      def record(obligation:, check:, execution_state:, obligation_coverage:, limitations:)
        LayeredVerificationCheckResult.create!(
          obligation: obligation,
          agent_run: agent_run,
          producer: check["producer"].to_s,
          execution_state: execution_state,
          obligation_coverage: obligation_coverage,
          input_revision: { "external_revision" => obligation.external_revision }.compact,
          evidence_ref: nil,
          evidence_summary: { "producer" => check["producer"], "claim_type" => check["claim_type"] }.compact,
          agent_reported: {},
          recorder_verified: { "plan_check" => check },
          cost: { "tokens" => 0 },
          limitations: limitations
        )
      end

      def record_findings(results)
        results.filter_map do |result|
          next unless result.obligation_coverage == "contradicted"

          Findings::Record.call(
            project: audit.project,
            obligation: result.obligation,
            check_result: result,
            agent_run: agent_run
          )
        end
      end

      def finish(report, findings:)
        review_package = RecordReviewPackage.call(audit:, obligations:, check_results: report_results, findings:)
        audit.update!(
          status: "completed",
          report: report_document(report).merge("review_package_id" => review_package.id),
          progress: { "checks_completed" => report.coverage.sum { |entry| entry["check_outcomes"].size } },
          completed_at: Time.current
        )
        agent_run.complete!
        audit
      end

      def report_results
        obligations.flat_map { |obligation| obligation.check_results.where(agent_run: agent_run).to_a }
      end

      def report_document(report)
        {
          "coverage" => report.coverage,
          "business_intent_validation" => report.business_intent_validation,
          "verification_coverage" => report.verification_coverage
        }
      end

      def cancel
        audit.update!(status: "cancelled", cancelled_at: Time.current, waiting_reason: "the audit run was cancelled")
        agent_run.cancel!(error: "the audit was cancelled")
        audit
      end

      def cancelled?
        agent_run.reload.status == "cancelled"
      end

      def agent_run
        audit.agent_run
      end

      def planned_checks
        Array(audit.plan["selected_checks"])
      end

      def planned_obligation_identities
        @planned_obligation_identities ||= begin
          declared = Array(audit.plan["obligation_external_identities"])
            .filter_map(&:presence)
          declared.presence || planned_checks.filter_map { |check| check["obligation_external_identity"].presence }
        end
      end

      def obligation_for(check)
        obligations.find { |obligation| obligation.external_identity == check["obligation_external_identity"] }
      end

      def formal_model
        audit.plan.dig("artifacts", "formal_model")
      end

      def max_checks
        audit.budget["max_checks"].to_i.clamp(1, ResolveScope::MAX_CHECKS)
      end
    end
  end
end
