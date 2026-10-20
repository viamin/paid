# frozen_string_literal: true

module FeatureIntents
  # Stores deterministic reconciliation results so operators can act on the
  # exact evidence from the revision that was inspected.
  # @spec DESIGN-RECONCILIATION-001
  class PersistDesignArtifactFindings
    def self.call(...) = new(...).call

    def self.resolve_removed_rdr_findings(project:, paths:, directory:, file_pattern:)
      # Include decision-pending rows so an operator's assigned/deferred/
      # dismissed decision no longer leaves a permanent record once the RDR is
      # removed: reconciliation, not the operator's note, is the verifier.
      project.design_artifact_findings.pending_findings
        .where("artifact_path LIKE ?", "#{ActiveRecord::Base.sanitize_sql_like(directory)}/%")
        .find_each do |finding|
          next unless File.dirname(finding.artifact_path) == directory
          next unless File.fnmatch?(file_pattern, File.basename(finding.artifact_path))
          next if finding.artifact_path.in?(paths)

          finding.resolve!
        end
    end

    def initialize(project:, revision:, artifacts:, issues:, coverage_complete: true)
      @project = project
      @revision = revision
      @artifacts = artifacts
      @issues = issues
      @coverage_complete = coverage_complete
    end

    def call
      result = ReconcileDesignArtifacts.call(project:, revision:, artifacts:, issues:, coverage_complete:)
      persist(result)
      result
    end

    private

    attr_reader :project, :revision, :artifacts, :issues, :coverage_complete

    def persist(result)
      records = existing_records(result.findings)

      DesignArtifactFinding.transaction do
        result.associations.each { |association| persist_association(association) }
        result.findings.each { |finding| upsert(finding, result.last_successful_coverage_at, records[finding.fingerprint]) }
        resolve_absent_findings(result.findings) if result.last_successful_coverage_at
      end
    end

    def existing_records(findings)
      project.design_artifact_findings.where(fingerprint: findings.map(&:fingerprint))
        .includes(:resolution_issue).index_by(&:fingerprint)
    end

    def persist_association(association)
      record = DesignArtifactAssociation.find_or_initialize_by(
        project:, artifact_path: association.fetch(:path), artifact_revision: association.fetch(:revision),
        issue_identity: association.fetch(:identity)
      )
      record.assign_attributes(
        account: project.account, issue_revision: association[:issue_revision], provenance: association.fetch(:provenance)
      )
      record.save!
    end

    def upsert(finding, covered_at, record)
      record ||= project.design_artifact_findings.build(fingerprint: finding.fingerprint)
      record.assign_attributes(
        account: project.account, artifact_path: finding.path, revision: finding.revision,
        state: finding.state, evidence: finding.evidence, covered_at: covered_at || record.covered_at || Time.current,
        **resolution_attributes(record)
      )
      record.save!
    end

    def resolution_attributes(record)
      return reopened_attributes(record) if assigned_issue_closed?(record)
      return { status: record.status, resolved_at: record.resolved_at } if record.decision_pending?

      { status: "open", resolved_at: nil }
    end

    def assigned_issue_closed?(record)
      record.status == "assigned" && record.resolution_issue&.github_state == "closed"
    end

    def reopened_attributes(record)
      {
        status: "open",
        resolved_at: nil,
        resolution_metadata: record.resolution_metadata.merge(
          "reopened_at" => Time.current.iso8601,
          "reopened_reason" => "The assigned issue closed without reconciliation resolving this gap."
        )
      }
    end

    def resolve_absent_findings(findings)
      paths = Array(artifacts).filter_map { |artifact| artifact[:path] }.uniq
      return if paths.empty?

      # Include decision-pending rows so an operator's assigned/deferred/
      # dismissed decision does not remain pending when reconciliation
      # verifies the underlying gap is gone.
      project.design_artifact_findings.pending_findings.where(artifact_path: paths)
        .where.not(fingerprint: findings.map(&:fingerprint)).find_each(&:resolve!)
    end
  end
end
