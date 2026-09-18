# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Reviews::Verification::Pipeline do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, project: project, goal: "review",
      source_pull_request_number: 42, status: "running")
  end
  let(:client) { instance_double(GithubClient) }
  let(:head_sha) { "aaa111aaa111" }
  let(:files) do
    [
      {
        filename: "app/services/foo.rb", status: "modified", additions: 2, deletions: 0,
        patch: "@@ -1,2 +1,3 @@\n line one\n line two\n+new line three"
      }
    ]
  end
  let(:file_content) { "line one\nline two\nnew line three\n" }
  let(:poster) { class_double(Reviews::Verification::PostTrackedReview) }
  let(:candidate_payload) do
    {
      path: "app/services/foo.rb", line: 3, summary: "Missing nil guard",
      triggering_condition: "params[:id] absent", failure_scenario: "NoMethodError"
    }
  end

  def llm_double(output_hash, input_tokens: 100, output_tokens: 40)
    instance_double(AgentHarness::Response, success?: true,
      output: output_hash.to_json, input_tokens: input_tokens,
      output_tokens: output_tokens, model: "claude-sonnet-4-6")
  end

  # Dispatches consecutive AgentHarness calls in pipeline order:
  # find, then one verify per candidate, then synthesize.
  def stub_llm_sequence(find_output:, verify_outputs:, synthesize_output:)
    responses = [ find_output ] + Array(verify_outputs) + [ synthesize_output ]
    allow(AgentHarness).to receive(:send_message) { responses.shift }
  end

  # Files for two attempts: the first hunk adds line 3, the second adds line 7
  # (with the hunk widened to cover lines 1-7 so the new anchor is valid for
  # the new head's ChangedLines index).
  def stub_files_for_retry
    old_files = [ {
      filename: "app/services/foo.rb", status: "modified", additions: 2, deletions: 0,
      patch: patch_adding_line(3)
    } ]
    new_files = [ {
      filename: "app/services/foo.rb", status: "modified", additions: 2, deletions: 0,
      patch: patch_adding_line(7)
    } ]
    attempt_index = 0
    allow(client).to receive(:detailed_pull_request_files) do
      attempt_index += 1
      attempt_index == 1 ? old_files : new_files
    end
    allow(client).to receive(:file_content).and_return(
      "line one\nline two\nnew line three\nnew line four\nnew line five\nnew line six\nnew line seven\n"
    )
  end

  # Two find → verify → synthesize rounds with a stale comment for attempt 1
  # and a fresh one (anchored to the new head's valid line) for attempt 2.
  def stub_retry_llm_sequence
    responses = [
      llm_double({ candidates: [ candidate_payload ] }),                # find (attempt 1)
      llm_double(confirmed_verdict),                                     # verify (attempt 1)
      llm_double(synthesized_comment(line: 3, body: "Stale anchor.")),   # synthesize (attempt 1)
      llm_double({ candidates: [ candidate_payload.merge("summary" => "Updated candidate") ] }), # find (attempt 2)
      llm_double(confirmed_verdict),                                     # verify (attempt 2)
      llm_double(synthesized_comment(line: 7, body: "Fresh anchor."))    # synthesize (attempt 2)
    ]
    allow(AgentHarness).to receive(:send_message) { responses.shift }
  end

  def stub_pull_request_heads(heads)
    remaining = heads.dup
    allow(client).to receive(:pull_request) do
      sha = remaining.shift || heads.last
      OpenStruct.new(head: OpenStruct.new(sha: sha), title: "Add feature", body: "The body")
    end
  end

  def patch_adding_line(line)
    "@@ -1,2 +1,#{line} @@\n line one\n line two\n" +
      (3..line).map { |n| "+new line #{n == 3 ? 'three' : n}" }.join("\n") +
      "\n"
  end

  def confirmed_verdict(claim_key: "nil-guard")
    { verdict: "confirmed", claim_key: claim_key, evidence: "Line 3 is unguarded." }
  end

  def synthesized_comment(body: "Guard the nil call.", source_ids: [ 1 ], line: 3)
    {
      body: "One confirmed issue.",
      comments: [
        { path: "app/services/foo.rb", line: line, body: body, source_candidate_ids: source_ids }
      ]
    }
  end

  before do
    allow(project).to receive(:client).and_return(client)
    stub_pull_request_heads([ head_sha ])
    allow(client).to receive(:detailed_pull_request_files).and_return(files)
    allow(client).to receive(:file_content).and_return(file_content)
    allow(poster).to receive(:call).and_return(
      { review_id: 555, review_url: "https://github.com/o/r/pull/42#pullrequestreview-555", already_posted: false }
    )
    allow(TokenUsageTracker).to receive(:track)
    stub_llm_sequence(
      find_output: llm_double({ candidates: [ candidate_payload ] }),
      verify_outputs: [ llm_double(confirmed_verdict) ],
      synthesize_output: llm_double(synthesized_comment)
    )
  end

  def run_pipeline
    described_class.call(agent_run: agent_run, github_client: client, poster: poster)
  end

  describe ".call happy path" do
    # @spec REVIEW-VERIFY-006
    it "posts exactly one tracked review with verified inline comments at the pinned head" do
      result = run_pipeline

      expect(poster).to have_received(:call).once.with(
        agent_run: agent_run,
        body: a_string_including("One confirmed issue."),
        comments: [ hash_including(path: "app/services/foo.rb", line: 3, side: "RIGHT") ],
        commit_sha: head_sha
      )
      expect(result[:outcome]).to eq("posted_findings")
      expect(result[:comments_posted]).to eq(1)
      expect(result[:review_id]).to eq(555)
    end

    # @spec REVIEW-VERIFY-007
    it "fetches verification content at the pinned head SHA" do
      run_pipeline

      expect(client).to have_received(:file_content)
        .with(project.full_name, path: "app/services/foo.rb", ref: head_sha)
    end

    # @spec REVIEW-VERIFY-009
    it "records counts, outcome, latency, models, and token usage without repository content" do
      result = run_pipeline
      metrics = result[:metrics]

      expect(metrics[:outcome]).to eq("posted_findings")
      expect(metrics[:candidates]).to eq(1)
      expect(metrics[:verdicts]).to eq(confirmed: 1, plausible: 0, refuted: 0)
      expect(metrics[:confirmed_groups]).to eq(1)
      expect(metrics[:comments_posted]).to eq(1)
      expect(metrics[:llm_calls]).to eq(find: 1, verify: 1, synthesize: 1)
      expect(metrics[:models]).to eq([ "claude-sonnet-4-6" ])
      expect(metrics[:tokens_input]).to eq(300)
      expect(metrics[:tokens_output]).to eq(120)
      expect(metrics[:latency_ms]).to include(:find, :verify, :synthesize, :post, :total)
      expect(metrics[:cost_cents]).to be >= 0

      expect(TokenUsageTracker).to have_received(:track).exactly(3).times
    end
  end

  describe "verification outcomes" do
    # @spec REVIEW-VERIFY-004
    it "never posts a refuted candidate; all refuted yields the clean review" do
      stub_llm_sequence(
        find_output: llm_double({ candidates: [ candidate_payload ] }),
        verify_outputs: [ llm_double({ verdict: "refuted", claim_key: "nil-guard", evidence: "Guarded above." }) ],
        synthesize_output: llm_double({ body: "unused", comments: [] })
      )

      result = run_pipeline

      expect(poster).to have_received(:call).once.with(
        agent_run: agent_run,
        body: a_string_including("Generated no new comments.", "<!-- paid-review-clean -->"),
        comments: [],
        commit_sha: head_sha
      )
      expect(result[:outcome]).to eq("posted_clean")
      expect(result[:metrics][:verdicts]).to eq(confirmed: 0, plausible: 0, refuted: 1)
    end

    # @spec REVIEW-VERIFY-006
    it "posts the clean review when the finder returns no candidates" do
      stub_llm_sequence(
        find_output: llm_double({ candidates: [] }),
        verify_outputs: [],
        synthesize_output: llm_double({ body: "unused", comments: [] })
      )

      result = run_pipeline

      expect(poster).to have_received(:call).once
      expect(result[:outcome]).to eq("posted_clean")
      expect(result[:metrics][:candidates]).to eq(0)
    end

    # @spec REVIEW-VERIFY-004
    it "withholds plausible candidates from comments and mentions only their count" do
      stub_llm_sequence(
        find_output: llm_double({ candidates: [ candidate_payload ] }),
        verify_outputs: [ llm_double({ verdict: "plausible", claim_key: "nil-guard", evidence: "Likely but unproven." }) ],
        synthesize_output: llm_double({ body: "unused", comments: [] })
      )

      result = run_pipeline

      expect(poster).to have_received(:call).once.with(
        agent_run: agent_run,
        body: a_string_including("Generated no new comments.", "1 plausible-but-unverified"),
        comments: [],
        commit_sha: head_sha
      )
      expect(result[:outcome]).to eq("posted_clean")
      expect(result[:metrics][:plausible_withheld]).to eq(1)
    end

    # @spec REVIEW-VERIFY-005
    it "collapses duplicate confirmed claims into one comment" do
      stub_llm_sequence(
        find_output: llm_double({ candidates: [
          candidate_payload,
          candidate_payload.merge("summary" => "Nil guard missing (duplicate)")
        ] }),
        verify_outputs: [
          llm_double(confirmed_verdict),
          llm_double(confirmed_verdict)
        ],
        synthesize_output: llm_double(synthesized_comment(source_ids: [ 1, 2 ]))
      )

      result = run_pipeline

      expect(result[:metrics][:candidates]).to eq(2)
      expect(result[:metrics][:confirmed_groups]).to eq(1)
      expect(result[:comments_posted]).to eq(1)
      expect(poster).to have_received(:call).once.with(
        agent_run: agent_run, body: anything,
        comments: array_including(hash_including(
          path: "app/services/foo.rb", line: 3, source_candidate_ids: [ 1, 2 ])),
        commit_sha: head_sha
      )
    end
  end

  describe "failure handling" do
    # @spec REVIEW-VERIFY-003
    it "aborts without posting when the verifier fails (never a clean review)" do
      stub_llm_sequence(
        find_output: llm_double({ candidates: [ candidate_payload ] }),
        verify_outputs: [
          instance_double(AgentHarness::Response, success?: false, output: "", error: "provider down",
            input_tokens: 0, output_tokens: 0, model: "claude-sonnet-4-6")
        ],
        synthesize_output: llm_double({ body: "unused", comments: [] })
      )

      expect { run_pipeline }.to raise_error(Reviews::Verification::VerifyCandidates::Error)
      expect(poster).not_to have_received(:call)
      expect(agent_run.reload.review_posted_at).to be_blank
    end

    # @spec REVIEW-VERIFY-007
    it "retries once against the new head and posts comments anchored to the new head's changed lines" do
      new_head = "bbb222bbb222"
      stub_pull_request_heads([ head_sha, new_head ])
      stub_files_for_retry
      stub_retry_llm_sequence

      result = run_pipeline

      expect(result[:metrics][:attempts]).to eq(2)
      expect(client).to have_received(:detailed_pull_request_files).twice
      expect(poster).to have_received(:call).once.with(
        agent_run: agent_run, body: anything,
        comments: [ hash_including(path: "app/services/foo.rb", line: 7, body: "Fresh anchor.") ],
        commit_sha: new_head
      )
    end

    # @spec REVIEW-VERIFY-007
    it "fails without posting when the head keeps moving" do
      stub_pull_request_heads([ head_sha, "bbb2", "bbb2", "ccc3" ])
      # The pipeline now re-runs the full find → verify → synthesize loop on
      # attempt 2 (so it never posts stale line comments), so the LLM stub
      # has to cover both attempts.
      responses = [
        llm_double({ candidates: [ candidate_payload ] }), # find (attempt 1)
        llm_double(confirmed_verdict),                      # verify (attempt 1)
        llm_double(synthesized_comment),                    # synthesize (attempt 1)
        llm_double({ candidates: [ candidate_payload ] }),  # find (attempt 2)
        llm_double(confirmed_verdict),                      # verify (attempt 2)
        llm_double(synthesized_comment)                     # synthesize (attempt 2)
      ]
      allow(AgentHarness).to receive(:send_message) { responses.shift }

      expect { run_pipeline }.to raise_error(described_class::HeadMovedError)
      expect(poster).not_to have_received(:call)
    end

    # @spec REVIEW-VERIFY-009
    it "does not post a second review when the poster reports the run already posted" do
      allow(poster).to receive(:call).and_return(
        { review_id: 555, review_url: "https://example.com/r/555", already_posted: true }
      )

      result = run_pipeline

      expect(result[:outcome]).to eq("already_posted")
      # `comments_posted` has to reflect what GitHub actually received, not
      # what the discarded draft contained (REVIEW-VERIFY-009).
      expect(result[:comments_posted]).to eq(0)
      expect(result[:metrics][:comments_posted]).to eq(0)
    end
  end
end
