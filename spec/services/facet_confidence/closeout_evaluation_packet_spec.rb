# frozen_string_literal: true

require "rails_helper"

RSpec.describe FacetConfidence::CloseoutEvaluationPacket do
  describe ".call" do
    it "pins the shipped corpus identity and reports the exact unresolved prerequisite route" do # @spec FACET-CONFIDENCE-020
      blocker = Issues::CloseoutStatus::Blocker.new(code: "unresolved_prerequisites", message: "#4316 is open",
        evidence: "#4316", recovery: "Complete #4316, then refresh this closeout.")
      status = instance_double(Issues::CloseoutStatus::Result, blockers: [ blocker ], unresolved_prerequisites: [ "#4316" ])
      issue = instance_double(Issue, github_number: 4323, project: instance_double(Project, full_name: "acme/paid"))
      assessment = instance_double(PartialCloseouts::Assessment::Result, source_revision: "intent-sha")
      allow(PartialCloseouts::Assessment).to receive(:call).with(issue).and_return(assessment)

      packet = described_class.call(issue:, status:)

      expect(packet.ready?).to be(false)
      expect(packet.corpus_version).to eq("facet-confidence-corpus-v1")
      expect(packet.rubric_version).to eq("facet-confidence-v1")
      expect(packet.model_version).to eq("claude-sonnet-4-6")
      expect(packet.blockers).to contain_exactly(include(code: "unresolved_prerequisites", recovery: "Complete #4316, then refresh this closeout."))
    end
  end
end
