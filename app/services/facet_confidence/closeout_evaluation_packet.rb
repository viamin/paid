# frozen_string_literal: true

require "digest"
require "yaml"

module FacetConfidence
  # Read-only packet for the Inbox closeout surface. It deliberately reuses the
  # frozen #4573 corpus; no UI rendering path runs semantic assessment work.
  # @spec FACET-CONFIDENCE-020
  class CloseoutEvaluationPacket
    MANIFEST_PATH = "docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml"

    Result = Data.define(:work_item, :project, :source_revision, :corpus_version,
      :corpus_digest, :rubric_version, :model_version, :input_revisions, :blockers) do
      def ready? = blockers.empty?
    end

    def self.call(...) = new(...).call

    def initialize(issue:, status:)
      @issue = issue
      @status = status
    end

    # Input revisions are keyed by case id only: the packet travels to the
    # pre-freeze Inbox surface, so embedding the case payloads as keys would
    # leak the frozen expectations, shapes, and selection rationale the
    # reference judgments must stay blinded to (FACET-CONFIDENCE-021).
    def call
      Result.new(work_item: issue.github_number, project: issue.project.full_name,
        source_revision: source_revision, corpus_version: manifest.fetch("corpus_version"),
        corpus_digest: Digest::SHA256.file(manifest_path).hexdigest,
        rubric_version: manifest.dig("rubric", "version"), model_version: manifest.dig("rubric", "model"),
        input_revisions: cases.to_h { |corpus_case| [ corpus_case.fetch("id"), corpus_case.fetch("evidence_revision", corpus_case.fetch("evidence").length) ] },
        blockers: blockers)
    end

    private

    attr_reader :issue, :status

    def manifest
      @manifest ||= YAML.safe_load_file(manifest_path).tap { |document| document.fetch("cases") }
    end

    def manifest_path = Rails.root.join(MANIFEST_PATH)
    def cases = manifest.fetch("cases")
    def source_revision = PartialCloseouts::Assessment.call(issue).source_revision

    def blockers
      status.blockers.map do |blocker|
        { code: blocker.code, message: blocker.message, evidence: blocker.evidence, recovery: blocker.recovery }
      end
    end
  end
end
