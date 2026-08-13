# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::ProvisionDefaults do
  let(:account) { create(:account) }

  describe ".call" do
    it "creates default prompts for the account" do
      described_class.call(account: account)

      prompts = account.prompts.reload
      expect(prompts.count).to eq(4)
      expect(prompts.pluck(:category).sort).to eq(%w[coding planning review testing])
    end

    it "creates prompt versions for each prompt" do
      described_class.call(account: account)

      account.prompts.each do |prompt|
        expect(prompt.current_version).to be_present
        expect(prompt.prompt_versions.count).to eq(1)
      end
    end

    it "creates a default style guide" do
      described_class.call(account: account)

      guides = account.style_guides.reload
      expect(guides.count).to eq(1)
      expect(guides.first.name).to eq("General Coding Standards")
    end

    it "is idempotent - does not create duplicates" do
      described_class.call(account: account)
      described_class.call(account: account)

      expect(account.prompts.count).to eq(4)
      expect(account.style_guides.count).to eq(1)
    end
  end
end
