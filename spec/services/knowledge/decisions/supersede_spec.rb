# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Decisions::Supersede do
  let(:project) { create(:project) }
  let(:original) { create(:decision_record, project: project) }
  let(:superseding) { create(:decision_record, project: project) }

  describe ".call" do
    it "marks the original as superseded" do
      described_class.call(original: original, superseding: superseding)

      original.reload
      expect(original.status).to eq("superseded")
      expect(original.superseded_by).to eq(superseding)
    end

    it "creates a reverts link on the superseding record" do
      described_class.call(original: original, superseding: superseding)

      link = superseding.decision_record_links.find_by(link_type: "reverts")
      expect(link).to be_present
      expect(link.linkable_type).to eq("DecisionRecord")
      expect(link.linkable_id).to eq(original.id.to_s)
    end

    it "raises when original and superseding are the same" do
      expect {
        described_class.call(original: original, superseding: original)
      }.to raise_error(ArgumentError, /must be different/)
    end

    it "raises when original is already superseded" do
      original.update!(status: "superseded")
      expect {
        described_class.call(original: original, superseding: superseding)
      }.to raise_error(ArgumentError, /must be draft or active/)
    end

    it "raises when original is reverted" do
      original.update!(status: "reverted")
      expect {
        described_class.call(original: original, superseding: superseding)
      }.to raise_error(ArgumentError, /must be draft or active/)
    end

    it "raises when records are not persisted" do
      unpersisted = build(:decision_record, project: project)
      expect {
        described_class.call(original: unpersisted, superseding: superseding)
      }.to raise_error(ArgumentError, /must be persisted/)
    end

    it "raises when records belong to different projects" do
      other_project = create(:project)
      other_record = create(:decision_record, project: other_project)
      expect {
        described_class.call(original: original, superseding: other_record)
      }.to raise_error(ArgumentError, /must belong to the same project/)
    end
  end
end
