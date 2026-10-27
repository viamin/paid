# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Converts the audit agent's bounded structured output into durable check
    # results before coverage synthesis. Missing or invalid selected outcomes
    # become explicit gaps instead of disappearing from the report.
    # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
    class IngestResults
      OUTPUT_DELIMITER = "paid-layered-verification-output"
      OUTPUT_PATTERN = /^#{Regexp.escape(OUTPUT_DELIMITER)}[ \t]*\r?$\R(.*?)^#{Regexp.escape(OUTPUT_DELIMITER)}[ \t]*\r?$/m
      STDOUT_TAIL_CHUNKS = 100
      MISSING_LIMITATION = "The selected check did not produce a recorded outcome."

      def self.call(...) = new(...).call

      def initialize(agent_run:)
        @agent_run = agent_run
      end

      def call
        agent_run.with_lock do
          return if audit_metadata["results_ingested_at"].present?

          persist_reported_results
          persist_missing_results
          mark_ingested!
        end
      end

      private

      attr_reader :agent_run

      def persist_reported_results
        reported_results.filter_map { |attributes| normalized_attributes(attributes) }
          .each { |attributes| LayeredVerificationCheckResult.create!(attributes) }
      end

      def persist_missing_results
        recorded = LayeredVerificationCheckResult.where(agent_run:).pluck(:obligation_id, :agent_reported).to_set do |id, report|
          [ id, report["selected_check"] ]
        end
        selected_checks.each do |obligation, selected_check|
          next if recorded.include?([ obligation.id, selected_check ])

          LayeredVerificationCheckResult.create!(missing_attributes(obligation, selected_check))
        end
      end

      def reported_results
        payload = structured_payload
        payload.is_a?(Hash) ? Array(payload["check_results"]) : []
      end

      def structured_payload
        raw = stdout
        match = delimited_payload(raw) || delimited_payload(agent_run.normalized_agent_output(raw, succeeded: true))
        JSON.parse(match || "{}")
      rescue JSON::ParserError
        {}
      end

      def stdout
        records = agent_run.agent_run_logs.stdout.recent.limit(STDOUT_TAIL_CHUNKS).pluck(:content).reverse
        records.join
      end

      def delimited_payload(output)
        output.to_s.scan(OUTPUT_PATTERN).last&.first
      end

      def normalized_attributes(raw)
        return unless raw.is_a?(Hash)

        attributes = raw.to_h.deep_stringify_keys
        obligation = obligations_by_id[attributes["obligation_id"].to_i]
        selected_check = attributes["selected_check"].to_s
        return unless obligation && selected_for?(obligation, selected_check)
        return if recorded_result?(obligation, selected_check)

        result_attributes(obligation, selected_check, attributes)
      end

      def recorded_result?(obligation, selected_check)
        LayeredVerificationCheckResult.where(agent_run:, obligation:)
          .where("agent_reported ->> 'selected_check' = ?", selected_check).exists?
      end

      def result_attributes(obligation, selected_check, attributes)
        producer = attributes["producer"].to_s
        state = attributes["execution_state"].to_s
        coverage = attributes["obligation_coverage"].to_s
        return invalid_attributes(obligation, selected_check) unless valid_outcome?(obligation, producer, state, coverage, attributes)

        result = {
          obligation:, correspondence_claim: claim_for(obligation, attributes), agent_run:, producer:,
          execution_state: state, obligation_coverage: coverage,
          input_revision: hash_value(attributes["input_revision"]),
          evidence_ref: attributes["evidence_ref"], evidence_summary: hash_value(attributes["evidence_summary"]),
          cause_signature: attributes["cause_signature"],
          agent_reported: hash_value(attributes["agent_reported"]).merge("selected_check" => selected_check),
          recorder_verified: { "structured_output" => true }, cost: hash_value(attributes["cost"]),
          limitations: attributes["limitations"].to_s
        }
        revisions_match?(obligation, result[:input_revision]) ? result : stale_attributes(result)
      end

      def revisions_match?(obligation, input_revision)
        reported = input_revision.values.map(&:to_s).select(&:present?)
        expected_revisions(obligation).all? { |revision| reported.include?(revision) }
      end

      def expected_revisions(obligation)
        [ audit_metadata["target_revision"], obligation.external_revision ].map(&:to_s).select(&:present?).uniq
      end

      def hash_value(value)
        value.is_a?(Hash) ? value : {}
      end

      def stale_attributes(attributes)
        attributes.merge(
          execution_state: "stale", obligation_coverage: "unresolved", cause_signature: nil,
          limitations: "The reported input revision does not match the audit's pinned revisions."
        )
      end

      def valid_outcome?(obligation, producer, state, coverage, attributes)
        LayeredVerificationCheckResult::PRODUCERS.include?(producer) &&
          LayeredVerificationCheckResult::EXECUTION_STATES.include?(state) &&
          LayeredVerificationCheckResult::OBLIGATION_COVERAGES.include?(coverage) &&
          attributes["limitations"].present? &&
          (coverage != "contradicted" || attributes["cause_signature"].to_s.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)) &&
          valid_claim_reference?(obligation, attributes)
      end

      def invalid_attributes(obligation, selected_check)
        missing_attributes(obligation, selected_check).merge(
          execution_state: "incomplete",
          limitations: "The selected check returned an invalid structured outcome."
        )
      end

      def missing_attributes(obligation, selected_check)
        {
          obligation:, agent_run:, producer: producer_for(selected_check), execution_state: "not_run",
          obligation_coverage: "unresolved", input_revision: { "target_revision" => audit_metadata["target_revision"] },
          agent_reported: { "selected_check" => selected_check }, recorder_verified: { "structured_output" => false },
          limitations: MISSING_LIMITATION
        }
      end

      def producer_for(selected_check)
        return selected_check if LayeredVerificationCheckResult::PRODUCERS.include?(selected_check)

        "semantic_audit"
      end

      def claim_for(obligation, attributes)
        claim_id = attributes["correspondence_claim_id"]
        claim_id.present? ? obligation.correspondence_claims.find_by(id: claim_id) : nil
      end

      def valid_claim_reference?(obligation, attributes)
        attributes["correspondence_claim_id"].blank? || claim_for(obligation, attributes).present?
      end

      def selected_for?(obligation, selected_check)
        selected_checks.include?([ obligation, selected_check ])
      end

      def selected_checks
        @selected_checks ||= obligations.flat_map do |obligation|
          plan = audit_metadata.fetch("plan", {}).fetch(obligation.id.to_s, {})
          Array(plan["selected_checks"]).map { |check| [ obligation, check.to_s ] }
        end
      end

      def obligations
        @obligations ||= agent_run.project.layered_verification_obligations.where(id: audit_metadata["obligation_ids"]).to_a
      end

      def obligations_by_id
        @obligations_by_id ||= obligations.index_by(&:id)
      end

      def audit_metadata
        @audit_metadata ||= agent_run.external_metadata.fetch("layered_verification")
      end

      def mark_ingested!
        metadata = agent_run.external_metadata.deep_dup
        metadata.fetch("layered_verification")["results_ingested_at"] = Time.current.iso8601
        agent_run.update!(external_metadata: metadata)
      end
    end
  end
end
