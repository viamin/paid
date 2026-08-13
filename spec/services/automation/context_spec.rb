# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Context do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  describe ".build" do
    it "constructs a context with project, record, and empty metadata by default" do
      context = described_class.build(record: issue)

      expect(context.project).to eq(project)
      expect(context.record).to eq(issue)
      expect(context.metadata).to eq({})
    end

    it "accepts explicit metadata and freezes it" do
      context = described_class.build(record: issue, metadata: { phase: "draft" })

      expect(context.metadata).to eq(phase: "draft")
      expect(context.metadata).to be_frozen
    end

    it "allows overriding the project explicitly" do
      other_project = create(:project)
      context = described_class.build(record: issue, project: other_project)

      expect(context.project).to eq(other_project)
    end

    it "raises when no project can be resolved" do
      record = Object.new

      expect { described_class.build(record: record) }
        .to raise_error(ArgumentError, /requires a project/)
    end
  end

  describe "#metadata_fetch" do
    it "returns the stored value when present" do
      context = described_class.build(record: issue, metadata: { phase: "ready" })

      expect(context.metadata_fetch(:phase)).to eq("ready")
    end

    it "returns the default when the key is missing" do
      context = described_class.build(record: issue)

      expect(context.metadata_fetch(:phase, "draft")).to eq("draft")
    end
  end

  describe "#with_metadata" do
    it "returns a new context with merged metadata without mutating the original" do
      original = described_class.build(record: issue, metadata: { phase: "draft" })
      extended = original.with_metadata(scan: { pr_number: 42 })

      expect(extended.metadata).to eq(phase: "draft", scan: { pr_number: 42 })
      expect(original.metadata).to eq(phase: "draft")
    end
  end
end
