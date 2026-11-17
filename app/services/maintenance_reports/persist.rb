# frozen_string_literal: true

require "digest"

module MaintenanceReports
  # One transactional persistence boundary for maintenance evidence. Tool and
  # agent adapters supply structured facts; this service does no semantic
  # classification and therefore keeps that judgment in agent_harness.
  # @spec MAINT-020 MAINT-021 MAINT-022 MAINT-023 MAINT-024 MAINT-025 MAINT-026 MAINT-027 MAINT-029
  class Persist
    def self.call(...) = new(...).call

    def initialize(run:, completed_checks: [], incomplete_checks: [], findings: [], resolved_scope: nil, exclusions: [],
      evidence: {}, outcome: nil)
      @run = run
      @completed_checks = completed_checks
      @incomplete_checks = incomplete_checks
      @findings = findings
      @resolved_scope = resolved_scope
      @exclusions = exclusions
      @evidence = evidence
      @requested_outcome = outcome
    end

    def call
      run.project.with_lock do
        MaintenanceReport.transaction do
          report = find_or_create_report
          persist_occurrences(report)
          validate_outcome!(report)
          report
        end
      end
    end

    private

    attr_reader :completed_checks, :evidence, :exclusions, :findings, :incomplete_checks, :requested_outcome,
      :resolved_scope, :run

    def find_or_create_report
      MaintenanceReport.find_or_initialize_by(agent_run: run).tap do |report|
        attributes = { account: run.project.account, project: run.project,
                       resolved_scope:, exclusions:,
                       completed_checks:, incomplete_checks:, evidence: }
        attributes[:outcome] = outcome unless incomplete_terminal_outcome?(report)
        attributes[:incomplete_checks] = report.incomplete_checks if report.outcome == "partial" && incomplete_checks.empty?
        report.assign_attributes(attributes)
        report.save!
      end
    end

    def persist_occurrences(report)
      findings.each do |attributes|
        canonical = find_or_update_canonical(attributes)
        report.finding_occurrences.find_or_create_by!(maintenance_finding: canonical) do |occurrence|
          occurrence.assign_attributes(occurrence_attributes(attributes, canonical))
        end
      end
    end

    def find_or_update_canonical(attributes)
      identity = identity_digest(attributes)
      finding = MaintenanceFinding.find_or_initialize_by(project: run.project, recipe_key: recipe_key, identity_digest: identity)
      evidence_digest = digest(attributes[:supporting_evidence])
      reassessment = finding.persisted? && finding.dismissed? && finding.supporting_evidence_digest != evidence_digest
      finding.assign_attributes(account: run.project.account, category: attributes.fetch(:category), claim: attributes.fetch(:claim),
        symbols: attributes.fetch(:symbols), locations: attributes.fetch(:locations), supporting_evidence_digest: evidence_digest,
        reassessment_required: reassessment || finding.reassessment_required)
      finding.save!
      finding
    end

    def occurrence_attributes(attributes, canonical)
      attributes.slice(:category, :claim, :symbols, :locations, :supporting_evidence, :contrary_evidence, :analyzer_provenance,
        :raw_tool_confidence, :agent_assessment, :proposed_action, :validation_plan, :verification_disposition).merge(
          account: run.project.account, observed_status: canonical.status, analyzer_provenance: attributes[:analyzer_provenance] || {},
          supporting_evidence: attributes[:supporting_evidence] || [], contrary_evidence: attributes[:contrary_evidence] || []
        )
    end

    def outcome
      return requested_outcome if requested_outcome.in?(%w[cancelled budget_exhausted])
      return "partial" if incomplete_checks.any?
      findings.any? || run.maintenance_report&.finding_occurrences&.exists? ? "completed" : "clean"
    end

    def validate_outcome!(report)
      return if incomplete_terminal_outcome?(report)

      report.update!(outcome: outcome) unless report.outcome == outcome
    end

    def incomplete_terminal_outcome?(report)
      report.persisted? && report.outcome.in?(%w[partial cancelled budget_exhausted])
    end

    def recipe_key
      run.maintenance_objective.presence || "custom"
    end

    def identity_digest(attributes)
      digest(claim: attributes.fetch(:claim).squish, symbols: Array(attributes.fetch(:symbols)).map(&:to_s).sort)
    end

    def digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical_json(value)))
    end

    def canonical_json(value)
      return value.map { |item| canonical_json(item) } if value.is_a?(Array)
      return value.to_h { |key, item| [ key.to_s, canonical_json(item) ] }.sort.to_h if value.is_a?(Hash)

      value
    end
  end
end
