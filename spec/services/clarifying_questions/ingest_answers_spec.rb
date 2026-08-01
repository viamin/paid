# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClarifyingQuestions::IngestAnswers do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, github_updated_at: 10.minutes.ago) }
  let(:github_client) { instance_double(GithubClient) }
  let(:trusted_login) { "viamin" }
  let(:enhancement_body) do
    <<~COMMENT
      <!-- paid:enhance-issue -->
      ## Clarifying questions
      1. What constitutes premium settings?
      2. Should this be behind a feature flag?

      ## Current context
      - Some context
    COMMENT
  end
  let(:answers_body) do
    <<~COMMENT
      <!-- paid:clarifying-answers -->

      ## Clarifying question answers

      **Q1: What constitutes premium settings?**
      **A1:** Premium settings include custom themes, advanced analytics, and priority support.

      **Q2: Should this be behind a feature flag?**
      **A2:** Yes, use the `premium_features` flag from `config/features.yml`.
    COMMENT
  end

  before do
    allow(project.github_token).to receive(:client).and_return(github_client)
  end

  def trusted_comment(body:, created_at: Time.current, login: trusted_login)
    double(body: body, user: double(login: login), created_at: created_at, id: rand(100_000))
  end

  describe ".call" do
    context "when issue comments are injected" do
      it "uses the injected comments instead of fetching from GitHub" do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments)

        described_class.call(project: project, issue: issue, issue_comments: [ enhancement, answers ])

        expect(github_client).not_to have_received(:issue_comments)
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair").count).to eq(2)
      end
    end

    context "when a trusted user posts answers" do
      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "creates knowledge artifacts for each Q&A pair" do
        described_class.call(project: project, issue: issue)

        artifacts = KnowledgeArtifact.for_project(project)
                                     .active
                                     .by_type("qa_pair")
        expect(artifacts.count).to eq(2)
      end

      it "creates knowledge chunks with chunk_type qa_pair" do
        described_class.call(project: project, issue: issue)

        chunks = KnowledgeChunk.where(project: project, chunk_type: "qa_pair")
        expect(chunks.count).to eq(2)
        expect(chunks.map(&:chunk_type).uniq).to eq([ "qa_pair" ])
      end

      it "stores Q and A in chunk content" do
        described_class.call(project: project, issue: issue)

        chunks = KnowledgeChunk.where(project: project, chunk_type: "qa_pair")
        contents = chunks.map(&:content).join("\n")
        expect(contents).to include("What constitutes premium settings")
        expect(contents).to include("include custom themes")
        expect(contents).to include("Should this be behind a feature flag")
        expect(contents).to include("premium_features")
      end

      it "sets scope_tags on chunks" do
        described_class.call(project: project, issue: issue)

        chunks = KnowledgeChunk.where(project: project, chunk_type: "qa_pair")
        chunks.each do |chunk|
          expect(chunk.scope_tags).to include("qa_pair")
          expect(chunk.scope_tags).to include("issue_#{issue.github_number}")
        end
      end

      it "sets metadata on artifacts with issue provenance" do
        described_class.call(project: project, issue: issue)

        artifact = KnowledgeArtifact.for_project(project).active.by_type("qa_pair").first
        expect(artifact.metadata["issue_id"]).to eq(issue.id)
        expect(artifact.metadata["issue_number"]).to eq(issue.github_number)
        expect(artifact.metadata["comment_id"]).to be_an(Integer)
        expect(artifact.metadata["question"]).to be_present
      end

      it "creates a collector run" do
        described_class.call(project: project, issue: issue)

        run = CollectorRun.find_by(collector_type: "clarifying_question_answers")
        expect(run).to be_present
        expect(run.status).to eq("completed")
      end

      it "generates content_hash for idempotent dedup" do
        described_class.call(project: project, issue: issue)

        chunks = KnowledgeChunk.where(project: project, chunk_type: "qa_pair")
        chunks.each do |chunk|
          expected = Digest::SHA256.hexdigest(chunk.content)
          expect(chunk.content_hash).to eq(expected)
        end
      end
    end

    context "when re-ingesting the same answer comment" do
      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "is idempotent and does not create duplicate chunks" do
        described_class.call(project: project, issue: issue)
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair").count).to eq(2)

        described_class.call(project: project, issue: issue)
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair").count).to eq(2)
      end
    end

    context "when another project has already ingested the same answers" do
      let(:other_project) { create(:project) }
      let(:other_issue) { create(:issue, project: other_project, github_updated_at: 10.minutes.ago) }
      let(:other_github_client) { instance_double(GithubClient) }

      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)

        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
        allow(other_project.github_token).to receive(:client).and_return(other_github_client)
        allow(other_github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "ingests matching qa pairs for each project" do
        described_class.call(project: other_project, issue: other_issue)
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: other_project, chunk_type: "qa_pair").count).to eq(2)
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair").count).to eq(2)
      end
    end

    context "when a non-allowlisted user posts answers" do
      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago, login: "attacker")
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when the answer comment is older than the enhancement comment" do
      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 2.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 5.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when the issue was edited after the answer comment" do
      before do
        issue.update!(github_updated_at: 1.minute.ago)
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when no enhancement comment exists" do
      before do
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        regular = trusted_comment(body: "Just a regular comment", created_at: 5.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ regular, answers ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when no answer comment exists" do
      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when GitHub is not configured" do
      before do
        allow(project).to receive(:github_token).and_return(nil)
      end

      it "does not create any chunks and returns nil" do
        result = described_class.call(project: project, issue: issue)

        expect(result).to be_nil
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when GitHub returns an error" do
      before do
        allow(github_client).to receive(:issue_comments).and_raise(GithubClient::Error, "GitHub down")
      end

      it "returns nil without creating chunks" do
        result = described_class.call(project: project, issue: issue)

        expect(result).to be_nil
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "with partial answers" do
      let(:partial_answers_body) do
        <<~COMMENT
          <!-- paid:clarifying-answers -->

          ## Clarifying question answers

          **Q1: What constitutes premium settings?**
          **A1:** Premium settings include custom themes.

          **Q2: Should this be behind a feature flag?**
          **A2:**
        COMMENT
      end

      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: partial_answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "only ingests the answered question" do
        described_class.call(project: project, issue: issue)

        chunks = KnowledgeChunk.where(project: project, chunk_type: "qa_pair")
        expect(chunks.count).to eq(1)
        expect(chunks.first.content).to include("What constitutes premium settings")
        expect(chunks.first.content).not_to include("Should this be behind a feature flag")
      end
    end

    context "when enhancement comment has no clarifying questions section" do
      let(:context_enhancement) do
        <<~COMMENT
          <!-- paid:enhance-issue -->
          ## Implementation context
          ### Relevant files
          - app/models/user.rb
        COMMENT
      end

      before do
        enhancement = trusted_comment(body: context_enhancement, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "does not create any chunks" do
        described_class.call(project: project, issue: issue)

        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair")).to be_empty
      end
    end

    context "when reusing an existing collector run" do
      let!(:project_version) { create(:project_version, project: project) }
      let!(:collector_run) do
        create(:collector_run, :completed,
               project_version: project_version,
               collector_type: "clarifying_question_answers")
      end

      before do
        enhancement = trusted_comment(body: enhancement_body, created_at: 5.minutes.ago)
        answers = trusted_comment(body: answers_body, created_at: 2.minutes.ago)
        allow(github_client).to receive(:issue_comments).and_return([ enhancement, answers ])
      end

      it "reuses the existing collector run" do
        described_class.call(project: project, issue: issue)

        expect(collector_run.reload.status).to eq("completed")
        expect(KnowledgeChunk.where(project: project, chunk_type: "qa_pair").count).to eq(2)
      end
    end
  end
end
