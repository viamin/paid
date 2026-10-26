# frozen_string_literal: true

module FacetConfidence
  # Read-only, validated view of the frozen assessment-corpus manifest backing
  # a closeout evaluation. Resolution, validation, and digests go through the
  # same AssessmentCorpusLedger machinery the CLI ledger uses, so the UI and
  # services never receive raw hashes with unknown shape and a changed corpus
  # cannot silently feed an existing evaluation.
  # @spec FACET-CONFIDENCE-016
  class Corpus
    MissingManifest = Class.new(StandardError)

    def initialize(path:, digest: "")
      @path = path.to_s
      @digest = digest.to_s
    end

    def cases
      @cases ||= AssessmentCorpusLedger.load_corpus(resolved_path)
    end

    def case_ids
      cases.map { |corpus_case| corpus_case.fetch("id") }
    end

    def find_case(case_id)
      cases.find { |corpus_case| corpus_case["id"] == case_id }
    end

    def content_digest
      AssessmentCorpusLedger.corpus_digest(resolved_path)
    end

    # A changed corpus is a new evidence generation: the caller must start a
    # new evaluation rather than judge against a moving target.
    def matches_recorded_digest?
      return true if @digest.blank?

      content_digest == @digest
    end

    # Identity is read only after load_corpus's shape and identity validation
    # (corpus version, rubric version, rubric model) has passed, so a
    # malformed manifest surfaces as InvalidLedger instead of a KeyError.
    def identity
      normalized = cases.first
      {
        "corpus_version" => AssessmentCorpusLedger.corpus_version_of(resolved_path),
        "rubric_version" => normalized.fetch("rubric_version"),
        "model_version" => normalized.fetch("model_version")
      }
    end

    def resolved_path
      @resolved_path ||= begin
        candidate = File.expand_path(@path, Rails.root)
        candidate = File.expand_path(@path) unless File.exist?(candidate)
        raise MissingManifest, "corpus manifest #{@path.inspect} was not found" unless File.exist?(candidate)

        candidate
      end
    end
  end
end
