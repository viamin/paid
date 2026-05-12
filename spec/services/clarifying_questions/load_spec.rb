# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Load do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, :needs_input, project: project, body: issue_body) }
  let(:issue_body) { "Original issue body" }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(project.github_token).to receive(:client).and_return(github_client)
  end

  describe ".call" do
    context "when the issue body already contains clarifying questions" do
      let(:issue_body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What should happen next?
        COMMENT
      end

      it "returns questions from the issue body without fetching comments" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([ "What should happen next?" ])
        expect(github_client).not_to have_received(:issue_comments)
      end
    end

    context "when clarifying questions only exist in GitHub comments" do
      before do
        comment = double(body: <<~COMMENT)
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
          2. Should this be behind a flag?

          ## Current context
          - Some context
        COMMENT
        allow(github_client).to receive(:issue_comments).and_return([ comment ])
      end

      it "loads questions from the latest enhancement comment" do
        questions = described_class.call(project: project, issue: issue)

        expect(questions).to eq([
          "What is the expected behavior?",
          "Should this be behind a flag?"
        ])
      end
    end

    context "when no clarifying questions are available" do
      before do
        allow(github_client).to receive(:issue_comments).and_return([])
      end

      it "returns an empty array" do
        expect(described_class.call(project: project, issue: issue)).to eq([])
      end
    end
  end
end
