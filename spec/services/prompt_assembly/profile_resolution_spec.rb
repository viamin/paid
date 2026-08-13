# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-009
RSpec.describe PromptAssembly::ProfileResolution do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  before { create(:tenant_setting, account: account) }


  def set_account_profile(config)
    account.tenant_setting.update!(features: { "prompt_assembly_profile" => config })
  end

  def set_project_profile(config)
    project.update!(review_settings: { "prompt_assembly_profile" => config })
  end

  describe ".resolve" do
    it "returns the default profile when no overrides are configured" do
      profile = described_class.resolve(project: project)

      expect(profile.disabled_sections).to eq([])
      expect(profile.budget_for(:knowledge)).to eq({ tokens: 4000 })
    end

    it "applies account-level overrides" do
      set_account_profile("disabled_sections" => [ "knowledge" ])

      profile = described_class.resolve(project: project)

      expect(profile.disabled_sections).to include(:knowledge)
    end

    it "applies project-level overrides over account-level" do
      set_account_profile("disabled_sections" => [ "knowledge" ])
      set_project_profile("disabled_sections" => [ "style_guides" ])

      profile = described_class.resolve(project: project)

      expect(profile.disabled_sections).to include(:style_guides, :knowledge)
    end

    it "applies goal-specific overrides over project-level" do
      set_project_profile(
        "section_order" => [ "knowledge" ],
        "goals" => {
          "create_pr" => { "section_order" => [ "style_guides", "knowledge" ] }
        }
      )

      profile = described_class.resolve(project: project, goal: "create_pr")

      expect(profile.section_order).to eq([ :style_guides, :knowledge ])
    end

    it "falls back to project-level config when goal is not found" do
      set_project_profile(
        "section_order" => [ "knowledge" ],
        "goals" => {}
      )

      profile = described_class.resolve(project: project, goal: "unknown_goal")

      expect(profile.section_order).to eq([ :knowledge ])
    end

    it "applies inline overrides last" do
      set_project_profile("disabled_sections" => [ "knowledge" ])

      profile = described_class.resolve(
        project: project,
        overrides: { disabled_sections: [ "marketplace" ] }
      )

      expect(profile.disabled_sections).to include(:knowledge, :marketplace)
    end

    it "merges budgets at all levels" do
      set_account_profile("budgets" => { "knowledge" => { "tokens" => 1000 } })
      set_project_profile("budgets" => { "style_guides" => { "bytes" => 8000 } })

      profile = described_class.resolve(project: project)

      expect(profile.budget_for(:knowledge)).to eq({ "tokens" => 1000 })
      expect(profile.budget_for(:style_guides)).to eq({ "bytes" => 8000 })
    end

    it "is deterministic: same inputs produce same fingerprint" do
      set_project_profile("disabled_sections" => [ "knowledge" ])

      p1 = described_class.resolve(project: project)
      p2 = described_class.resolve(project: project)

      expect(p1.fingerprint).to eq(p2.fingerprint)
    end
  end
end
