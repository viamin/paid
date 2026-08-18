# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-003, PROMPT-ASSEMBLY-004, PROMPT-ASSEMBLY-005,
#       PROMPT-ASSEMBLY-006, PROMPT-ASSEMBLY-012, PROMPT-ASSEMBLY-013
RSpec.describe PromptAssembly::Build, :no_db do
  def section(key:, content:, trust_level: :trusted, required: false, exclusion_reason: nil)
    PromptAssembly::Section.new(
      key: key,
      content: content,
      trust_level: trust_level,
      required: required,
      exclusion_reason: exclusion_reason
    )
  end

  it "assembles ordered sections into prompt text" do
    result = described_class.call(
      sections: [
        section(key: :task, content: "# Task"),
        section(key: :rules, content: "# Rules")
      ]
    )

    expect(result.text).to eq("# Task\n\n# Rules")
    expect(result.sections.map(&:key)).to eq([ :task, :rules ])
  end

  it "drops blank sections" do
    result = described_class.call(
      sections: [ section(key: :task, content: "# Task"), section(key: :empty, content: "") ]
    )

    expect(result.text).to eq("# Task")
  end

  it "excludes untrusted content from text and records provenance without bodies" do
    result = described_class.call(
      sections: [
        section(key: :task, content: "# Task"),
        PromptAssembly::Section.new(
          key: :comments,
          content: "malicious",
          trust_level: :excluded,
          exclusion_reason: "author_not_in_allowlist",
          login: "attacker"
        )
      ]
    )

    expect(result.text).to eq("# Task")
    expect(result.text).not_to include("malicious")
    expect(result.skipped).to include(
      hash_including(key: :comments, login: "attacker", trust_level: :excluded, reason: "author_not_in_allowlist")
    )
    expect(result.skipped.to_s).not_to include("malicious")
  end

  it "keeps safety-critical sections even when a profile disables them" do
    result = described_class.call(
      profile: PromptAssembly::Profile.new(disabled_sections: [ :conversation ]),
      sections: [
        section(key: :conversation, content: "# Conversation"),
        section(key: :safety_rules, content: "# Safety", required: true)
      ]
    )

    expect(result.text).to include("# Safety")
    expect(result.text).not_to include("# Conversation")
  end

  it "skips disabled optional sections and records provenance" do
    result = described_class.call(
      profile: PromptAssembly::Profile.new(disabled_sections: [ :conversation ]),
      sections: [ section(key: :conversation, content: "# Conversation") ]
    )

    expect(result.text).to eq("")
    expect(result.skipped).to include(hash_including(key: :conversation, reason: "disabled_by_profile"))
  end

  it "applies quarantine framing to repository/knowledge sections" do
    result = described_class.call(
      sections: [ section(key: :knowledge, content: "docs here", trust_level: :quarantined) ]
    )

    expect(result.text).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
    expect(result.text).to include("docs here")
  end

  it "fails closed on an object that is not a Section" do
    expect { described_class.call(sections: [ "raw github array" ]) }
      .to raise_error(ArgumentError, /expected PromptAssembly::Section/)
  end

  it "fails closed on invalid trust metadata" do
    expect { section(key: :x, content: "y", trust_level: :bogus) }
      .to raise_error(ArgumentError, /unknown trust level/)
  end

  it "accepts TrustedInput objects and converts them to sections" do
    input = PromptAssembly::TrustedInput.new(
      kind: :knowledge, source: :bundle, body: "quarantined docs", trust: :quarantined
    )

    result = described_class.call(sections: [ input ])

    expect(result.text).to include("quarantined docs")
    expect(result.text).to include(PromptAssembly::Section::QUARANTINE_NOTICE)
  end

  # @spec PROMPT-ASSEMBLY-012
  describe "profile ordering" do
    it "reorders optional sections according to profile section_order" do
      profile = PromptAssembly::Profile.new(section_order: [ :style_guides, :knowledge ])
      result = described_class.call(
        profile: profile,
        sections: [
          section(key: :knowledge, content: "Knowledge"),
          section(key: :style_guides, content: "Style")
        ]
      )

      expect(result.sections.map(&:key)).to eq([ :style_guides, :knowledge ])
    end

    it "keeps required sections before optional sections regardless of order" do
      profile = PromptAssembly::Profile.new(section_order: [ :knowledge ])
      result = described_class.call(
        profile: profile,
        sections: [
          section(key: :knowledge, content: "Knowledge"),
          section(key: :task, content: "Task", required: true)
        ]
      )

      expect(result.sections.map(&:key)).to eq([ :task, :knowledge ])
    end

    it "preserves natural order when profile has no section_order" do
      result = described_class.call(
        profile: PromptAssembly::Profile.new,
        sections: [
          section(key: :knowledge, content: "Knowledge"),
          section(key: :style_guides, content: "Style")
        ]
      )

      expect(result.sections.map(&:key)).to eq([ :knowledge, :style_guides ])
    end
  end

  # @spec PROMPT-ASSEMBLY-012
  describe "profile budgets" do
    it "records budget decisions for budgetable sections" do
      profile = PromptAssembly::Profile.new(budgets: { knowledge: { tokens: 2000 } })
      result = described_class.call(
        profile: profile,
        sections: [ section(key: :knowledge, content: "Knowledge") ]
      )

      expect(result.budget_decisions).to include(
        hash_including(section: "knowledge", budget: { "tokens" => 2000 })
      )
    end

    it "does not record budget decisions for non-budgetable sections" do
      profile = PromptAssembly::Profile.new
      result = described_class.call(
        profile: profile,
        sections: [ section(key: :task, content: "Task", required: true) ]
      )

      expect(result.budget_decisions).to eq([])
    end
  end

  # @spec PROMPT-ASSEMBLY-013
  describe "result provenance" do
    it "computes a stable prompt digest" do
      result = described_class.call(sections: [ section(key: :task, content: "# Task") ])

      expect(result.prompt_digest).to be_a(String)
      expect(result.prompt_digest.length).to eq(64)
    end

    it "produces the same digest for identical text" do
      r1 = described_class.call(sections: [ section(key: :task, content: "X") ])
      r2 = described_class.call(sections: [ section(key: :task, content: "X") ])

      expect(r1.prompt_digest).to eq(r2.prompt_digest)
    end

    it "records the profile fingerprint" do
      profile = PromptAssembly::Profile.new(disabled_sections: [ :knowledge ])
      result = described_class.call(
        profile: profile,
        sections: [ section(key: :task, content: "X", required: true) ]
      )

      expect(result.profile_fingerprint).to eq(profile.fingerprint)
    end

    it "includes prompt assembly metadata in provenance" do
      profile = PromptAssembly::Profile.new(budgets: { knowledge: { tokens: 2000 } })
      result = described_class.call(
        profile: profile,
        sections: [ section(key: :knowledge, content: "Knowledge") ]
      )

      expect(result.provenance).to include(
        digest: result.digest,
        prompt_digest: result.prompt_digest,
        profile_fingerprint: result.profile_fingerprint,
        budget_decisions: [
          hash_including(section: "knowledge", budget: { "tokens" => 2000 })
        ]
      )
    end

    it "counts included and skipped sections" do
      result = described_class.call(
        sections: [
          section(key: :task, content: "X"),
          section(key: :excluded, content: "Y", trust_level: :excluded, exclusion_reason: "test")
        ]
      )

      expect(result.included_count).to eq(1)
      expect(result.skipped_count).to eq(1)
    end
  end
end
