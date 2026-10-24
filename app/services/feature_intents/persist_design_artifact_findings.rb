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
        .where("artifact_path = ? OR artifact_path LIKE ?", directory,
          "#{ActiveRecord::Base.sanitize_sql_like(directory)}/%")
        .find_each do |finding|
          next unless finding.artifact_path == directory || matching_rdr_path?(finding.artifact_path, directory, file_pattern)
          next if finding.artifact_path.in?(paths)

          finding.resolve!
        end
    end

    def self.matching_rdr_path?(path, directory, file_pattern)
      File.dirname(path) == directory && File.fnmatch?(file_pattern, File.basename(path))
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
        persisted = result.findings.map do |finding|
          upsert(finding, result.last_successful_coverage_at, records[finding.fingerprint], records[finding_identity(finding)])
        end
        resolve_absent_findings(persisted) if result.last_successful_coverage_at
      end
    end

    def existing_records(findings)
      paths = findings.map(&:path).uniq
      records = project.design_artifact_findings.where(artifact_path: paths).includes(:resolution_issue).to_a
      records.each_with_object({}) do |record, index|
        index[record.fingerprint] = record
        index[finding_identity(record)] ||= record
      end
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

    def upsert(finding, covered_at, exact_record, identity_record)
      record = exact_record || carry_forward_record(finding, identity_record)
      record ||= project.design_artifact_findings.build
      record.assign_attributes(
        account: project.account, fingerprint: finding.fingerprint, artifact_path: finding.path, revision: finding.revision,
        state: finding.state, evidence: finding.evidence, covered_at: covered_at || record.covered_at || Time.current,
        **resolution_attributes(record)
      )
      record.save!
      record
    end

    def carry_forward_record(finding, record)
      return unless record&.decision_pending?
      return unless record.evidence == finding.evidence

      record
    end

    def finding_identity(finding)
      [ finding.respond_to?(:artifact_path) ? finding.artifact_path : finding.path, finding.state ].join(":")
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
        .where.not(id: findings.map(&:id)).find_each(&:resolve!)
    end
  end
end
