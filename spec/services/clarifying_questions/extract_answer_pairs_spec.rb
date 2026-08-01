# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::ExtractAnswerPairs do
  let(:project) { create(:project) }
  let(:trusted_login) { "viamin" }
  let(:enhancement_body) do
    <<~COMMENT
      <!-- paid:enhance-issue -->
      ## Clarifying questions
      1. What problem are we solving?
      2. When the redirect is invalid, what should happen?
    COMMENT
  end
  let(:answers_body) do
    <<~COMMENT
      <!-- paid:clarifying-answers -->

      ## Clarifying question answers

      **Q1: What problem are we solving?**
      **A1:** Users should never land on a broken redirect.

      **Q2: When the redirect is invalid, what should happen?**
      **A2:** The system should send them to `/dashboard`.
    COMMENT
  end
  let(:bot_login) { "paid-agents[bot]" }
  let(:enhancement_comment) do
    comment(
      body: enhancement_body,
      created_at: Time.zone.parse("2026-07-30 12:00:00 UTC"),
      login: bot_login
    )
  end
  let(:answer_comment) do
    comment(
      body: answers_body,
      created_at: Time.zone.parse("2026-07-30 13:00:00 UTC"),
      login: trusted_login
    )
  end
  let(:issue) { build_stubbed(:issue, github_updated_at: Time.zone.parse("2026-07-30 11:00:00 UTC")) }

  before do
    allow(project).to receive(:paid_bot_author?) { |login| login == bot_login }
  end

  def comment(body:, created_at:, login:)
    OpenStruct.new(body: body, created_at: created_at, user: OpenStruct.new(login: login))
  end

  it "returns paired questions and answers from the admitted comment flow" do
    result = described_class.call(project: project, issue_comments: [ enhancement_comment, answer_comment ], issue: issue)

    expect(result.qa_pairs).to eq(
      [
        {
          question: "What problem are we solving?",
          answer: "Users should never land on a broken redirect."
        },
        {
          question: "When the redirect is invalid, what should happen?",
          answer: "The system should send them to `/dashboard`."
        }
      ]
    )
    expect(result.answer_comment.body).to include("<!-- paid:clarifying-answers -->")
  end

  it "returns no pairs when the answers predate the questions" do
    result = described_class.call(
      project: project,
      issue: issue,
      issue_comments: [
        enhancement_comment.tap { |entry| allow(entry).to receive(:created_at).and_return(Time.zone.parse("2026-07-30 13:00:00 UTC")) },
        answer_comment.tap { |entry| allow(entry).to receive(:created_at).and_return(Time.zone.parse("2026-07-30 12:00:00 UTC")) }
      ]
    )

    expect(result.qa_pairs).to eq([])
    expect(result.answer_comment).to be_nil
  end

  it "returns no pairs when the issue was edited after the answers were posted" do
    issue.github_updated_at = Time.zone.parse("2026-07-30 14:00:00 UTC")

    result = described_class.call(
      project: project,
      issue: issue,
      issue_comments: [ enhancement_comment, answer_comment ]
    )

    expect(result.qa_pairs).to eq([])
    expect(result.answer_comment).to be_nil
  end
end
