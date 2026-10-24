# frozen_string_literal: true

require "rails_helper"

RSpec.describe LayeredVerification::Obligations::ResolveFramework do
  # @spec LAYERED-VERIFY-001
  it "uses the persisted LID mode without inspecting the checkout" do
    project = create(:project, lid_mode: "scoped", lid_mode_overridden: true)

    result = described_class.call(project:, repo_path: Rails.root.join("spec/fixtures/files").to_s)

    expect(result.framework).to eq("lid")
    expect(result.offers).to be_empty
  end

  # @spec LAYERED-VERIFY-002
  it "uses an OKF bundle only when no persisted LID mode exists" do
    Dir.mktmpdir do |repo_path|
      FileUtils.mkdir_p(File.join(repo_path, ".okf"))
      File.write(File.join(repo_path, ".okf", "checkout.md"), "---\ntitle: Checkout\n---\nIntent")
      project = create(:project, lid_mode: nil)

      result = described_class.call(project:, repo_path:)

      expect(result.framework).to eq("okf")
      expect(result.external_identity).to eq(".okf/checkout.md")
      expect(result.external_revision).to be_present
    end
  end

  # @spec LAYERED-VERIFY-003
  it "offers repository-persisted CIR and LID when no framework is present" do
    Dir.mktmpdir do |repo_path|
      project = create(:project, lid_mode: nil)

      result = described_class.call(project:, repo_path:)

      expect(result.framework).to eq("paid_offered_cir")
      expect(result.offers).to contain_exactly("okf_compatible_cir", "lid")
    end
  end
end
