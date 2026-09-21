# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-TRANSFER-005
RSpec.describe AppleVerification::ArtifactIngestion::Storage do
  let(:storage) { described_class.new }

  describe ".namespace_prefix" do
    it "returns a per-account/per-project/per-attempt prefix" do
      prefix = described_class.namespace_prefix(account_id: 1, project_id: 2, attempt_id: 3)
      expect(prefix).to eq("apple-verification/1/2/3/")
    end
  end

  describe ".bundle_key" do
    it "returns the standard source bundle key" do
      expect(described_class.bundle_key(account_id: 1, project_id: 2, attempt_id: 3))
        .to eq("apple-verification/1/2/3/source.tar")
    end
  end

  describe ".artifact_key" do
    it "returns the per-kind per-name artifact key" do
      expect(described_class.artifact_key(account_id: 1, project_id: 2, attempt_id: 3, kind: "xcresult", name: "App.xcresult"))
        .to eq("apple-verification/1/2/3/xcresult/App.xcresult")
    end

    it "rejects unsupported artifact kinds" do
      expect {
        described_class.artifact_key(account_id: 1, project_id: 2, attempt_id: 3, kind: "raw_shell", name: "shell.sh")
      }.to raise_error(ArgumentError, /unsupported artifact kind/)
    end
  end

  describe ".content_type_for" do
    it "maps each supported kind to a content type" do
      expect(described_class.content_type_for("xcresult")).to eq("application/x-xcresult")
      expect(described_class.content_type_for("build_log")).to eq("text/plain")
      expect(described_class.content_type_for("screenshot")).to eq("image/png")
      expect(described_class.content_type_for("diagnostics")).to eq("application/json")
      expect(described_class.content_type_for("manifest")).to eq("application/json")
    end
  end
end
