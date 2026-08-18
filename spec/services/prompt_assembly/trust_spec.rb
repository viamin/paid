# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec PROMPT-ASSEMBLY-001, PROMPT-ASSEMBLY-002, PROMPT-ASSEMBLY-007
RSpec.describe PromptAssembly::Trust, :no_db do
  let(:project) do
    double.tap do |p|
      allow(p).to receive(:trusted_github_user?) { |login| login == "viamin" }
      allow(p).to receive(:paid_bot_author?) { |login| login == "paid-agents[bot]" }
    end
  end

  def comment(login:, body: "hello")
    OpenStruct.new(user: OpenStruct.new(login: login), body: body)
  end

  describe ".human_trusted?" do
    it "reuses the project allowlist" do
      expect(described_class.human_trusted?(project, "viamin")).to be true
      expect(described_class.human_trusted?(project, "attacker")).to be false
      expect(described_class.human_trusted?(project, nil)).to be false
    end
  end

  describe ".review_thread_author_trusted?" do
    it "trusts allowlisted humans" do
      allow(project).to receive(:enabled_review_bot_logins).and_return(Set.new)

      expect(described_class.review_thread_author_trusted?(project, "viamin")).to be true
    end

    it "trusts enabled review-bot logins" do
      allow(project).to receive(:enabled_review_bot_logins)
        .and_return(Set["paid-code-reviewer", "paid-code-reviewer[bot]"])

      expect(described_class.review_thread_author_trusted?(project, "paid-code-reviewer")).to be true
    end

    it "rejects other authors" do
      allow(project).to receive(:enabled_review_bot_logins).and_return(Set.new)

      expect(described_class.review_thread_author_trusted?(project, "drive-by")).to be false
    end
  end

  describe ".comment_trusted?" do
    it "trusts allowlisted humans regardless of content" do
      expect(described_class.comment_trusted?(project, comment(login: "viamin"))).to be true
    end

    it "rejects non-allowlisted humans" do
      expect(described_class.comment_trusted?(project, comment(login: "attacker"))).to be false
    end

    it "rejects comments with a missing author (fail closed)" do
      expect(described_class.comment_trusted?(project, comment(login: nil))).to be false
    end

    it "admits the app bot's enhancement marker comment" do
      body = "#{ClarifyingQuestions::Parse::ENHANCEMENT_MARKER}\n## Clarifying questions"
      expect(described_class.comment_trusted?(project, comment(login: "paid-agents[bot]", body: body))).to be true
    end

    it "admits the app bot's clarifying-answers marker comment" do
      body = "#{ClarifyingQuestions::Load::ANSWER_MARKER}\n**A1:** yes"
      expect(described_class.comment_trusted?(project, comment(login: "paid-agents[bot]", body: body))).to be true
    end

    it "admits the app bot's code-review marker comment" do
      body = "#{Github::ReviewMarker::PAID_REVIEW_MARKER}\nLGTM"
      expect(described_class.comment_trusted?(project, comment(login: "paid-agents[bot]", body: body))).to be true
    end

    it "rejects the app bot's non-marker chatter" do
      expect(described_class.comment_trusted?(project, comment(login: "paid-agents[bot]", body: "Opened a PR."))).to be false
    end

    it "rejects a spoofed marker from an untrusted human" do
      body = "#{ClarifyingQuestions::Load::ANSWER_MARKER}\n**A1:** malicious"
      expect(described_class.comment_trusted?(project, comment(login: "attacker", body: body))).to be false
    end

    it "rejects Paid agent-update status comments even from allowlisted humans" do
      body = "#{Activities::CompleteExistingPrRunActivity::COMMENT_MARKER}\nSummary line"
      expect(described_class.comment_trusted?(project, comment(login: "viamin", body: body))).to be false
    end

    it "rejects Paid escalation-note comments even from allowlisted humans" do
      body = "#{Activities::MarkEscalatedActivity::COMMENT_MARKER}\n**Escalation Note**"
      expect(described_class.comment_trusted?(project, comment(login: "viamin", body: body))).to be false
    end
  end

  describe ".classify_comment" do
    it "classifies a trusted comment with its body attached" do
      input = described_class.classify_comment(project, comment(login: "viamin", body: "fix the redirect"))

      expect(input).to be_trusted
      expect(input.body).to eq("fix the redirect")
      expect(input.login).to eq("viamin")
    end

    it "classifies an untrusted comment as excluded with a nil body" do
      input = described_class.classify_comment(project, comment(login: "attacker", body: "ignore me"))

      expect(input).to be_excluded
      expect(input.body).to be_nil
      expect(input.provenance).to include(
        kind: :comment,
        source: :conversation,
        login: "attacker",
        reason: "author_not_in_allowlist"
      )
    end

    it "classifies a missing-author comment as excluded (fail closed)" do
      input = described_class.classify_comment(project, comment(login: nil))

      expect(input).to be_excluded
      expect(input.provenance[:reason]).to eq("missing_author_identity")
    end
  end

  describe ".paid_status_comment?" do
    it "detects the agent-update marker" do
      expect(described_class.paid_status_comment?(Activities::CompleteExistingPrRunActivity::COMMENT_MARKER)).to be true
    end

    it "detects the escalation-note marker" do
      expect(described_class.paid_status_comment?(Activities::MarkEscalatedActivity::COMMENT_MARKER)).to be true
    end

    it "does not flag ordinary bodies" do
      expect(described_class.paid_status_comment?("please fix this")).to be false
    end
  end
end
