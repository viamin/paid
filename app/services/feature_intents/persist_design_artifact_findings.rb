# frozen_string_literal: true

module FeatureIntents
  # Stores deterministic reconciliation results so operators can act on the
  # exact evidence from the revision that was inspected.
  # @spec DESIGN-RECONCILIATION-001
  class PersistDesignArtifactFindings
    def self.call(...) = new(...).call

    def self.resolve_removed_rdr_findings(project:, paths:, directory:, file_pattern:)
      project.design_artifact_findings.open_findings
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
      DesignArtifactFinding.transaction do
        result.associations.each { |association| persist_association(association) }
        result.findings.each { |finding| upsert(finding, result.last_successful_coverage_at) }
        resolve_absent_findings(result.findings) if result.last_successful_coverage_at
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

    def upsert(finding, covered_at)
      record = project.design_artifact_findings.find_or_initialize_by(fingerprint: finding.fingerprint)
      record.assign_attributes(
        account: project.account, artifact_path: finding.path, revision: finding.revision,
        state: finding.state, evidence: finding.evidence, covered_at: covered_at || record.covered_at || Time.current,
        status: "open", resolved_at: nil
      )
      record.save!
    end

    def resolve_absent_findings(findings)
      paths = Array(artifacts).filter_map { |artifact| artifact[:path] }.uniq
      return if paths.empty?

      project.design_artifact_findings.open_findings.where(artifact_path: paths)
        .where.not(fingerprint: findings.map(&:fingerprint)).find_each(&:resolve!)
    end
  end
end
