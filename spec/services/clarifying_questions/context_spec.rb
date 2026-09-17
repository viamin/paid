# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::Context, :no_db do
  describe ".call" do
    context "when the comment has a Current Context section" do
      let(:body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Current context
          - The issue body mentions a flag toggle the repo already has.
          - Existing coverage lives in `app/services/foo.rb`.

          ## Clarifying questions
          1. What should the default value be?
          2. Should the toggle be exposed in the admin UI?
        COMMENT
      end

      it "returns the Current Context section's body, dropping the heading" do
        expect(described_class.call(comment_body: body)).to eq(
          "- The issue body mentions a flag toggle the repo already has.\n" \
          "- Existing coverage lives in `app/services/foo.rb`."
        )
      end

      it "ignores the numbered list and the clarifying heading" do
        result = described_class.call(comment_body: body)

        expect(result).not_to include("What should the default value be?")
        expect(result).not_to include("## Clarifying questions")
        expect(result).not_to include("1.")
      end
    end

    context "when the comment has a clarifying-questions preamble" do
      let(:body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions

          The issue references two existing flags; clarify which one to wire first.

          1. Should the new behavior reuse `flag_a` or `flag_b`?
          2. Is the rollout reversible without data loss?
        COMMENT
      end

      it "returns the prose that introduced the numbered list" do
        expect(described_class.call(comment_body: body)).to eq(
          "The issue references two existing flags; clarify which one to wire first."
        )
      end
    end

    context "when the comment has both the preamble and Current Context" do
      let(:body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions

          Need a quick call before implementation.

          1. Wire to which flag?

          ## Current context
          - The repo has two candidate flags.

          ## Proposed Change Intent Record
          This issue is canonical for X.
        COMMENT
      end

      it "joins preamble and Current Context with a blank line and stops at the next heading" do
        result = described_class.call(comment_body: body)

        expect(result).to eq(
          "Need a quick call before implementation.\n\n" \
          "- The repo has two candidate flags."
        )
      end

      it "drops the Proposed Change Intent Record section" do
        expect(described_class.call(comment_body: body)).not_to include("Proposed Change Intent Record")
        expect(described_class.call(comment_body: body)).not_to include("This issue is canonical for X.")
      end
    end

    context "when the comment uses a clarifying-questions heading variant" do
      let(:body) do
        <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Remaining clarifying questions

          ## Current context
          - Some context
        COMMENT
      end

      it "still recognizes the heading" do
        result = described_class.call(comment_body: body)

        expect(result).to eq("- Some context")
      end
    end

    context "when the comment has no recoverable context" do
      it "returns nil when the body has only numbered questions" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Clarifying questions
          1. What is the expected behavior?
        COMMENT

        expect(described_class.call(comment_body: body)).to be_nil
      end

      it "returns nil when neither section exists" do
        body = <<~COMMENT
          <!-- paid:enhance-issue -->

          ## Implementation context
          Some text
        COMMENT

        expect(described_class.call(comment_body: body)).to be_nil
      end
    end

    context "when the body is blank or missing" do
      it "returns nil for an empty string" do
        expect(described_class.call(comment_body: "")).to be_nil
      end

      it "returns nil for nil" do
        expect(described_class.call(comment_body: nil)).to be_nil
      end

      it "returns nil when only the enhancement marker is present" do
        expect(described_class.call(comment_body: "<!-- paid:enhance-issue -->")).to be_nil
      end
    end
  end
end
