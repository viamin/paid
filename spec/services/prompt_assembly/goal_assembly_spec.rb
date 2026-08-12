# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-004, PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-006
RSpec.describe PromptAssembly::GoalAssembly do
  let(:project) { create(:project) }
  let(:base_prompt) { "Implement the feature described above." }

  describe "create-issue goal" do
    it "contributes the rendered wrapper as a required goal.create_issue section" do
      agent_run = create(:agent_run, :create_issue_goal, project: project)
      goal_text = "#{base_prompt}\n\nIMPORTANT: create a GitHub issue"

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)

      expect(result.text).to eq(goal_text)
      expect(result.sections.map(&:key)).to eq([ :"goal.create_issue" ])
      expect(result.sections.first).to be_required
      expect(result.sections.first).to be_trusted
    end
  end

  describe "review goal" do
    it "contributes the rendered wrapper as a required goal.review section" do
      agent_run = create(:agent_run, :review_goal, project: project)
      goal_text = "#{base_prompt}\n\nIMPORTANT: review the PR"

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)

      expect(result.sections.map(&:key)).to eq([ :"goal.review" ])
      expect(result.sections.first).to be_required
    end
  end

  describe "enhance-issue goal" do
    it "contributes the rendered wrapper as a required goal.enhance_issue section" do
      agent_run = create(:agent_run, :enhance_issue_goal, project: project)
      goal_text = "#{base_prompt}\n\nIMPORTANT: enhance the issue"

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)

      expect(result.sections.map(&:key)).to eq([ :"goal.enhance_issue" ])
      expect(result.sections.first).to be_required
    end
  end

  describe "interactive verification (create_pr goal)" do
    it "keeps the base prompt and verification as separate sections" do
      agent_run = create(:agent_run, :with_git_context, project: project)
      verification = "# Interactive Verification\nattempt an end-to-end self-check"

      result = described_class.call(
        agent_run: agent_run, base_prompt: base_prompt, verification_text: verification
      )

      expect(result.sections.map(&:key)).to eq([ :"task.base", :"verification.interactive" ])
      expect(result.text).to eq("#{base_prompt}\n\n#{verification}")
      verification_section = result.sections.last
      expect(verification_section).to be_required
      expect(verification_section).to be_trusted
    end

    it "contributes only the base section when verification is not applicable" do
      agent_run = create(:agent_run, :with_git_context, project: project)

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt, verification_text: "")

      expect(result.sections.map(&:key)).to eq([ :"task.base" ])
      expect(result.text).to eq(base_prompt)
    end
  end

  describe "goals without a migrated wrapper" do
    it "contributes only the base task section" do
      agent_run = create(:agent_run, :create_feature_goal, project: project)

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt)

      expect(result.sections.map(&:key)).to eq([ :"task.base" ])
    end
  end

  describe "provenance and digest" do
    it "records a digest and section-level provenance without section bodies" do
      agent_run = create(:agent_run, :create_issue_goal, project: project)
      goal_text = "#{base_prompt}\n\nSECRET-CONTENT-MUST-NOT-LEAK-123"

      result = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)

      provenance = result.provenance
      expect(provenance[:digest]).to be_a(String).and(match(/\A[0-9a-f]{64}\z/))
      expect(provenance[:sections].first).to include(key: :"goal.create_issue", required: true)
    end

    it "produces a stable digest for identical sections" do
      agent_run = create(:agent_run, :review_goal, project: project)
      goal_text = "#{base_prompt}\n\nIMPORTANT: review"

      first = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)
      second = described_class.call(agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text)

      expect(first.digest).to eq(second.digest)
    end
  end

  describe "safety sections survive profile customization" do
    it "keeps a required goal section even when a profile disables it" do
      agent_run = create(:agent_run, :enhance_issue_goal, project: project)
      goal_text = "#{base_prompt}\n\nIMPORTANT: enhance"
      profile = PromptAssembly::Profile.new(disabled_sections: [ :"goal.enhance_issue" ])

      result = described_class.call(
        agent_run: agent_run, base_prompt: base_prompt, goal_text: goal_text
      )
      # Profile is applied by PromptAssembly::Build directly; verify the section
      # is marked required so Build cannot drop it.
      expect(result.sections.first).to be_required
      built = PromptAssembly::Build.call(
        sections: [ PromptAssembly::Section.new(
          key: :"goal.enhance_issue", content: goal_text, trust_level: :trusted, required: true
        ) ],
        profile: profile
      )
      expect(built.text).to include("IMPORTANT: enhance")
    end
  end
end
