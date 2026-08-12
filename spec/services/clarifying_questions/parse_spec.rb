# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Parse, :no_db do
  describe ".call" do
    context "when comment has clarifying questions" do
      it "parses numbered questions from the clarifying section" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior for edge case X?
          2. Should the feature be behind a feature flag?
          3. What databases need to be updated?

          ## Current context
          - The issue mentions a new feature
        COMMENT

        questions = described_class.call(comment_body: body)

        expect(questions).to eq([
          "What is the expected behavior for edge case X?",
          "Should the feature be behind a feature flag?",
          "What databases need to be updated?"
        ])
      end

      it "handles multi-line questions by joining them" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior for the edge case where the user
             has not yet confirmed their email address?
          2. Should this be enabled by default?

          ## Current context
          - Some context
        COMMENT

        questions = described_class.call(comment_body: body)

        expect(questions.size).to eq(2)
        expect(questions[0]).to eq("What is the expected behavior for the edge case where the user has not yet confirmed their email address?")
        expect(questions[1]).to eq("Should this be enabled by default?")
      end

      it "parses heading variants such as remaining clarifying questions" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Remaining clarifying questions
          1. Which scope should ship first?
        COMMENT

        questions = described_class.call(comment_body: body)

        expect(questions).to eq([ "Which scope should ship first?" ])
      end
    end

    context "when comment has sufficient context (no clarifying questions)" do
      it "returns empty array" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Implementation context
          ### Relevant files
          - app/models/user.rb
        COMMENT

        questions = described_class.call(comment_body: body)

        expect(questions).to eq([])
      end
    end

    context "when comment does not have the enhancement marker" do
      it "returns empty array" do
        body = "Some random comment"

        questions = described_class.call(comment_body: body)

        expect(questions).to eq([])
      end
    end

    context "when comment body is nil" do
      it "returns empty array" do
        questions = described_class.call(comment_body: nil)

        expect(questions).to eq([])
      end
    end

    context "when clarifying section has no numbered items" do
      it "returns empty array" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions

          ## Current context
          - Some context
        COMMENT

        questions = described_class.call(comment_body: body)

        expect(questions).to eq([])
      end
    end
  end
end
