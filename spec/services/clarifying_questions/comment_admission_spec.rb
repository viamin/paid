# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::CommentAdmission, :no_db do
  let(:project) do
    double.tap do |p|
      allow(p).to receive(:trusted_github_user?) { |login| login == "viamin" }
      allow(p).to receive(:paid_bot_author?) { |login| login == "paid-agents[bot]" }
    end
  end

  def comment(login:, body:)
    double(user: double(login: login), body: body)
  end

  describe ".admissible?" do
    it "admits comments from trusted humans regardless of content" do
      c = comment(login: "viamin", body: "just a normal comment")
      expect(described_class.admissible?(project: project, comment: c)).to be true
    end

    it "rejects comments from untrusted humans" do
      c = comment(login: "attacker", body: "hello")
      expect(described_class.admissible?(project: project, comment: c)).to be false
    end

    it "admits the app bot's enhancement marker comment" do
      c = comment(login: "paid-agents[bot]", body: "<!-- paid:enhance-issue -->\n## Clarifying questions")
      expect(described_class.admissible?(project: project, comment: c)).to be true
    end

    it "admits the app bot's clarifying-answers marker comment" do
      c = comment(login: "paid-agents[bot]", body: "<!-- paid:clarifying-answers -->\n**A1:** yes")
      expect(described_class.admissible?(project: project, comment: c)).to be true
    end

    it "rejects the app bot's non-marker comments (general bot chatter)" do
      c = comment(login: "paid-agents[bot]", body: "Opened a pull request for this issue.")
      expect(described_class.admissible?(project: project, comment: c)).to be false
    end

    it "rejects a spoofed marker from an untrusted human (unspoofable bot login required)" do
      c = comment(login: "attacker", body: "<!-- paid:clarifying-answers -->\n**A1:** malicious")
      expect(described_class.admissible?(project: project, comment: c)).to be false
    end

    it "handles a missing comment author" do
      c = double(user: nil, body: "<!-- paid:clarifying-answers -->")
      expect(described_class.admissible?(project: project, comment: c)).to be false
    end
  end
end
