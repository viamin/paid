# frozen_string_literal: true

require "rails_helper"

RSpec.describe FacetConfidence::CloseoutEvaluation::CompileReport do
  describe ".call" do
    it "records the originating closeout revision and an insufficient evidence disposition" do # @spec PARTIAL-CLOSEOUT-029
      account = create(:account)
      owner = create(:user, :owner, account:)
      project = create(:project, account:, created_by: owner)
      issue = create(:issue, project:, github_number: 3861)
      corpus = FacetConfidence::Corpus.new(path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH)
      identity = corpus.identity
      evaluation = FacetConfidenceEvaluation.create!(
        project:, issue:, created_by: owner, status: "frozen", labels_frozen_at: Time.current,
        source_revision: "closeout-revision", corpus_path: FacetConfidence::CloseoutEvaluationPacket::MANIFEST_PATH,
        corpus_digest: corpus.content_digest, corpus_version: identity.fetch("corpus_version"),
        rubric_version: identity.fetch("rubric_version"), model_version: identity.fetch("model_version")
      )

      result = described_class.call(evaluation:)

      expect(result).to be_success
      expect(result.report.fetch("closeout_evidence")).to include(
        "source_revision" => "closeout-revision",
        "disposition" => "insufficient",
        "provenance" => { "actor_id" => owner.id, "evaluation_id" => evaluation.id }
      )
      expect(result.report.dig("closeout_evidence", "reason")).to include("does not satisfy")
    end
  end
end
