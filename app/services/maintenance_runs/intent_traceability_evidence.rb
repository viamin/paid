# frozen_string_literal: true

module MaintenanceRuns
  # Snapshots the persisted design-artifact reconciliation evidence for the
  # intent_traceability recipe prompt. The recipe forbids the investigation
  # from rebuilding an RDR/issue inventory, so the shared reconciler's durable
  # results are attached here instead: pending findings carry the traceability
  # gaps and stored associations carry the known trees that must survive as
  # counterevidence. The snapshot is bounded and discloses every omission.
  # @spec MAINT-046
  class IntentTraceabilityEvidence
    MAX_FINDINGS = 50
    MAX_ASSOCIATIONS = 75
    MAX_EVIDENCE_ENTRIES = 5
    EMPTY_SNAPSHOT = <<~EMPTY.chomp
      No persisted reconciliation findings or associations exist for this project
      yet. Report that absence as an unresolved coverage limitation of the shared
      reconciliation evidence; do not infer from it that no traceability gaps
      exist, and do not rebuild the inventory the reconciler owns.
    EMPTY

    def self.call(project:, max_findings: MAX_FINDINGS, max_associations: MAX_ASSOCIATIONS)
      new(project:, max_findings:, max_associations:).render
    end

    def initialize(project:, max_findings:, max_associations:)
      @project = project
      @max_findings = max_findings
      @max_associations = max_associations
    end

    def render
      return EMPTY_SNAPSHOT if persisted_finding_count.zero? && associations_total.zero?

      [ header, findings_section, associations_section ].join("\n\n")
    end

    private

    attr_reader :project, :max_findings, :max_associations

    # Resolved-only projects still have reconciliation results: the empty
    # limitation text is reserved for a reconciler that has recorded nothing.
    def persisted_finding_count
      @persisted_finding_count ||= project.design_artifact_findings.count
    end

    def pending_state_counts
      @pending_state_counts ||= project.design_artifact_findings.pending_findings.group(:state).count
    end

    def pending_total
      pending_state_counts.values.sum
    end

    def listed_findings
      @listed_findings ||= project.design_artifact_findings.pending_findings
        .includes(resolution_issue: :project).order(:artifact_path).limit(max_findings).to_a
    end

    def listed_associations
      @listed_associations ||= project.design_artifact_associations
        .order(:artifact_path, :issue_identity).limit(max_associations).to_a
    end

    def associations_total
      @associations_total ||= project.design_artifact_associations.count
    end

    def header
      "Captured #{Time.current.utc.iso8601} from persisted FeatureIntents::ReconcileDesignArtifacts " \
        "results; it reports the latest persisted issue coverage (" \
        "#{latest_coverage_at}), not live GitHub or repository state."
    end

    def latest_coverage_at
      [
        project.design_artifact_findings.maximum(:covered_at),
        project.design_artifact_associations.maximum(:updated_at)
      ].compact.max&.utc&.iso8601 || "unavailable"
    end

    def findings_section
      <<~SECTION.chomp
        Pending findings by state: #{state_counts}; resolved to date: #{resolved_summary}.
        #{finding_lines.join("\n")}
      SECTION
    end

    def state_counts
      return "none pending" if pending_total.zero?

      pending_state_counts.map { |state, count| "#{state} #{count}" }.join(", ")
    end

    def resolved_summary
      counts = project.design_artifact_findings.where(status: "resolved").group(:state).count
      counts.empty? ? "none" : counts.map { |state, count| "#{state} #{count}" }.join(", ")
    end

    def finding_lines
      listed = listed_findings.map { |finding| "- #{describe(finding)}" }
      omitted = pending_total - listed.size
      listed << "(+#{omitted} more pending findings omitted from this snapshot)" if omitted.positive?
      listed
    end

    def describe(finding)
      evidence = finding.evidence.first(MAX_EVIDENCE_ENTRIES).join("; ")
      "#{finding.artifact_path} — #{finding.state} (#{finding.status}, covered " \
        "#{finding.covered_at.utc.iso8601})#{assignment(finding)}: #{evidence}"
    end

    def assignment(finding)
      issue = finding.resolution_issue
      return if issue.nil?

      ", assigned to #{issue.project.full_name}##{issue.github_number}"
    end

    def associations_section
      <<~SECTION.chomp
        Known artifact-to-issue associations from stored reconciliation results (#{associations_total}):
        #{association_lines.join("\n")}
      SECTION
    end

    def association_lines
      listed = listed_associations.map do |association|
        "- #{association.artifact_path} @ #{association.artifact_revision[0, 12]} → " \
          "#{association.issue_identity} (#{association.provenance})"
      end
      omitted = associations_total - listed.size
      listed << "(+#{omitted} more associations omitted from this snapshot)" if omitted.positive?
      listed
    end
  end
end
