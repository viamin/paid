# frozen_string_literal: true

require "digest"
require "set"

module FeatureIntents
  # Reconciles repository design artifacts against already-read GitHub facts.
  # It deliberately accepts only explicit identities: deciding whether prose
  # describes the same work is semantic assessment and belongs to agent_harness.
  # @spec DESIGN-RECONCILIATION-001
  class ReconcileDesignArtifacts
    Finding = Data.define(:fingerprint, :path, :revision, :state, :evidence)
    Result = Data.define(:findings, :associations, :last_successful_coverage_at) do
      def actionable_findings = findings.reject { |finding| finding.state == "deferred" }
    end

    def self.call(...) = new(...).call

    def initialize(project:, revision:, artifacts:, issues:, coverage_complete: true)
      @project = project
      @revision = revision
      @artifacts = Array(artifacts)
      @issues = Array(issues)
      @coverage_complete = coverage_complete
    end

    def call
      findings = artifacts.filter_map { |artifact| finding_for(artifact) }.uniq(&:fingerprint)
      Result.new(
        findings:,
        associations: artifacts.flat_map { |artifact| associations_for(artifact) },
        last_successful_coverage_at: coverage_complete? ? Time.current : nil
      )
    end

    private

    attr_reader :project, :revision, :artifacts, :issues

    def coverage_complete? = @coverage_complete

    def finding_for(artifact)
      state, evidence = state_for(normalize(artifact))
      return unless state

      Finding.new(fingerprint: fingerprint(artifact, state), path: artifact[:path], revision:, state:, evidence:)
    end

    def associations_for(artifact)
      normalized = normalize(artifact)
      semantic_association = semantic_association_for(artifact)
      (normalized.fetch(:associated_issues) + (semantic_association ? [ semantic_association ] : [])).filter_map do |association|
        identity = qualified_reference(association)
        next unless identity && issue_identities.include?(identity)

        {
          path: artifact[:path], revision:, identity:,
          issue_revision: association[:revision] || association["revision"],
          provenance: association[:provenance] || association["provenance"]
        }.compact
      end
    end

    def state_for(artifact)
      return [ "unverifiable", [ "GitHub coverage was incomplete" ] ] unless coverage_complete?
      return [ "deferred", [ "Artifact status is #{artifact[:status]}" ] ] if deferred?(artifact)

      references = artifact[:references] | artifact[:associated_identities]
      return stale_metadata(artifact) if references.empty? && artifact[:stored_identities].any?
      return missing_tree(artifact) if references.empty?

      missing = references.reject { |reference| issue_identities.include?(reference) }
      return if missing.empty?

      [ "partial_tree", missing.map { |reference| "Missing linked issue #{reference}" } ]
    end

    def normalize(artifact)
      {
        status: artifact[:status].to_s,
        references: qualified_references(artifact[:related_issues]),
        stored_identities: qualified_references(artifact[:stored_identities]),
        associated_issues: Array(artifact[:associated_issues]),
        associated_identities: qualified_references(Array(artifact[:associated_issues])),
        body: artifact[:body], path: artifact[:path], revision: artifact[:revision] || revision
      }
    end

    def deferred?(artifact)
      %w[draft deferred superseded historical].any? { |status| artifact[:status].casecmp?(status) }
    end

    def stale_metadata(artifact)
      artifact[:stored_identities].then do |identities|
        [ "stale_metadata", identities.map { |identity| stale_metadata_evidence(identity) } ]
      end
    end

    def stale_metadata_evidence(identity)
      if issue_identities.include?(identity)
        "Stored identity #{identity} is not linked from the artifact"
      else
        "Stored identity #{identity} could not be found in GitHub coverage"
      end
    end

    def qualified_references(values)
      Array(values).filter_map { |value| qualified_reference(value) }.uniq
    end

    def qualified_reference(value)
      return "#{value[:repository]}##{value[:number]}" if value.is_a?(Hash) && value[:repository].present? && value[:number].present?

      reference = value.to_s.strip
      return reference if reference.match?(%r{\A[\w.-]+/[\w.-]+#\d+\z})
      "#{project.full_name}#{reference}" if reference.match?(/\A#\d+\z/)
    end

    def issue_identities
      @issue_identities ||= issues.filter_map { |issue| qualified_reference(issue) }.to_set
    end

    def missing_tree(artifact)
      assessment = semantic_assessment_for(artifact)
      return if assessment.covered?

      [ "missing_tree", [ "No explicit qualified issue links were found", assessment.evidence ] ]
    end

    def semantic_assessment_for(artifact)
      @semantic_assessments ||= {}
      @semantic_assessments[artifact[:path]] ||= AssessDesignArtifactCandidates.call(project:, artifact:, issues:)
    end

    def semantic_association_for(artifact)
      normalized = normalize(artifact)
      return unless coverage_complete?
      return if deferred?(normalized) || normalized[:stored_identities].any?
      return if (normalized[:references] | normalized[:associated_identities]).any?

      assessment = semantic_assessment_for(normalized)
      return unless assessment.covered?

      repository, number = assessment.identity.split("#", 2)
      candidate = issues_by_identity.fetch(assessment.identity)
      {
        repository:, number:, revision: candidate[:revision] || candidate["revision"],
        provenance: "semantic candidate assessment: #{assessment.evidence}"
      }.compact
    end

    def issues_by_identity
      @issues_by_identity ||= issues.each_with_object({}) do |issue, candidates|
        identity = qualified_reference(issue)
        candidates[identity] = issue if identity
      end
    end

    def fingerprint(artifact, state)
      Digest::SHA256.hexdigest([ project.id, artifact[:path], revision, state ].join(":"))
    end
  end
end
