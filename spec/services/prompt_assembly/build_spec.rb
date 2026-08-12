# frozen_string_literal: true

require "rails_helper"

# @spec PROMPT-ASSEMBLY-003, PROMPT-ASSEMBLY-004, PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-006
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
        section(key: :comments, content: "malicious", trust_level: :excluded, exclusion_reason: "author_not_in_allowlist")
      ]
    )

    expect(result.text).to eq("# Task")
    expect(result.text).not_to include("malicious")
    expect(result.skipped).to include(
      hash_including(key: :comments, trust_level: :excluded, reason: "author_not_in_allowlist")
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
end
