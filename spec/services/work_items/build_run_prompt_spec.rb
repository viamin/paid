# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::BuildRunPrompt do
  let(:project) { create(:project) }
  let(:account) { project.account }

  before { account.tenant_setting!.update!(features: { "unified_work_items" => true }) }

  describe "prompt composition" do
    it "embeds the ticket title and body" do
      work_item = create(:work_item, account:, title: "Fix login redirect", body: "Users bounce back to /login.")

      prompt = described_class.call(work_item:, project:)

      expect(prompt).to include("Fix login redirect")
      expect(prompt).to include("Users bounce back to /login.")
    end
  end

  describe "trusted-comment admission" do
    it "admits a comment from an account-trusted provider identity" do
      # @spec UNIFIED-WORK-ITEMS-005
      work_item = create(:work_item, account:)
      create(:trusted_provider_identity, account:, provider: "linear", identity_type: "user", external_id: "user-1")

      prompt = described_class.call(work_item:, project:, comments: [
        { author_external_id: "user-1", author_identity_type: "user", body: "Ship it Monday" }
      ])

      expect(prompt).to include("Ship it Monday")
    end

    it "admits a comment authored by an explicitly mapped Paid user" do
      # @spec UNIFIED-WORK-ITEMS-005
      work_item = create(:work_item, account:)
      create(:provider_identity_mapping, account:, provider: "linear", external_id: "user-2")

      prompt = described_class.call(work_item:, project:, comments: [
        { author_external_id: "user-2", author_identity_type: "user", body: "Regression is fixed" }
      ])

      expect(prompt).to include("Regression is fixed")
    end

    it "omits comments from untrusted identities" do
      work_item = create(:work_item, account:)

      prompt = described_class.call(work_item:, project:, comments: [
        { author_external_id: "stranger", author_identity_type: "user", body: "Untrusted text" }
      ])

      expect(prompt).not_to include("Untrusted text")
    end

    it "refuses a GitHub-provider work item so its title and body never reach the prompt" do
      # @spec UNIFIED-WORK-ITEMS-005
      work_item = create(:work_item, account:, provider: "github",
        title: "Untrusted GitHub title", body: "Untrusted GitHub body")

      expect { described_class.call(work_item:, project:, comments: []) }
        .to raise_error(WorkItems::BuildRunPrompt::UntrustedProviderError)
    end

    it "admits comments retained in the raw payload" do
      work_item = create(:work_item, account:, raw_payload: {
        "comments" => [ { "author" => { "id" => "user-1", "type" => "user" }, "body" => "From payload" } ]
      })
      create(:trusted_provider_identity, account:, provider: "linear", identity_type: "user", external_id: "user-1")

      prompt = described_class.call(work_item:, project:)

      expect(prompt).to include("From payload")
    end

    it "renders no conversation section when nothing is admitted" do
      work_item = create(:work_item, account:)

      prompt = described_class.call(work_item:, project:, comments: [
        { author_external_id: "stranger", author_identity_type: "user", body: "Untrusted text" }
      ])

      expect(prompt).not_to include("Conversation Comments")
    end
  end
end
