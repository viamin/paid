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

    def initialize(issue:, status:, ignored_blocker_codes: [])
      @issue = issue
      @status = status
      @ignored_blocker_codes = ignored_blocker_codes
    end

    def call
      Result.new(work_item: issue.github_number, project: issue.project.full_name,
        source_revision: source_revision, corpus_version: manifest.fetch("corpus_version"),
        corpus_digest: Digest::SHA256.file(manifest_path).hexdigest,
        rubric_version: manifest.dig("rubric", "version"), model_version: manifest.dig("rubric", "model"),
        input_revisions: cases.index_with { |corpus_case| corpus_case.fetch("evidence_revision", corpus_case.fetch("evidence").length) },
        blockers: blockers)
    end

    private

    attr_reader :ignored_blocker_codes, :issue, :status

    def manifest
      @manifest ||= YAML.safe_load_file(manifest_path).tap { |document| document.fetch("cases") }
    end

    def manifest_path = Rails.root.join(MANIFEST_PATH)
    def cases = manifest.fetch("cases")
    def source_revision = PartialCloseouts::Assessment.call(issue).source_revision

    def blockers
      status.blockers.reject { |blocker| blocker.code.in?(ignored_blocker_codes) }.map do |blocker|
        { code: blocker.code, message: blocker.message, evidence: blocker.evidence, recovery: blocker.recovery }
      end
    end
  end
end
