# frozen_string_literal: true

module Reviews
  module Verification
    # Find → Verify → Synthesize orchestrator (#3898). Pins the PR head, runs
    # the three staged LLM sessions against that head, then asks
    # +PostTrackedReview+ to post one review through the paid-code-reviewer
    # bot identity. Each stage is delegated to its own service object so
    # prompts, error classes, and token accounting stay separate; this class
    # owns only the cross-stage mechanics:
    #
    # - pin the PR head SHA before finding, re-check immediately before
    #   posting, retry once against the new head if it moved, and fail the
    #   run if it moves again (REVIEW-VERIFY-007);
    # - group confirmed candidates by (path, claim_key) into one deduplicated
    #   finding per claim (REVIEW-VERIFY-005);
    # - replace the synthesis body with the clean-review contract when no
    #   comment survives the anchor/citation guards (REVIEW-VERIFY-004,
    #   REVIEW-VERIFY-006), and surface withheld plausible findings only as a
    #   count;
    # - track tokens per stage and accumulate metrics without repository
    #   content (REVIEW-VERIFY-009).
    #
    # @spec REVIEW-VERIFY-004 REVIEW-VERIFY-005 REVIEW-VERIFY-006 REVIEW-VERIFY-007 REVIEW-VERIFY-009
    class Pipeline
      Error = Class.new(StandardError)
      HeadMovedError = Class.new(Error)

      MAX_ATTEMPTS = 2
      CLEAN_MARKER = "<!-- paid-review-clean -->"

      # @param agent_run [AgentRun]
      # @param github_client [GithubClient]
      # @param poster [#call] anything responding to +call(agent_run:, body:, comments:, commit_sha:)+
      # @return [Hash] :outcome, :review_id, :review_url, :comments_posted, :metrics
      def self.call(agent_run:, github_client:, poster:)
        new(agent_run:, github_client:, poster:).call
      end

      def initialize(agent_run:, github_client:, poster:)
        @agent_run = agent_run
        @project = agent_run.project
        @github_client = github_client
        @poster = poster
        @verdicts_summary = { confirmed: 0, plausible: 0, refuted: 0 }
        @llm_calls = { find: 0, verify: 0, synthesize: 0 }
        @models = []
        @tokens_input = 0
        @tokens_output = 0
        @latency = { find: 0, verify: 0, synthesize: 0, post: 0 }
        @started_at = monotonic_now
        @attempt = 0
        @comments_posted = 0
        @confirmed_groups = 0
        @unanchored_findings = 0
        @outcome = nil
        @review_id = nil
        @review_url = nil
      end

      def call
        attempt = 0
        loop do
          attempt += 1
          @attempt = attempt
          pr = pull_request
          @head_sha = pr.head.sha

          if attempt == 1
            files = fetch_files
            changed_lines = ChangedLines.from_files(files)
            candidates = run_find(files, pr)
            verdicts = run_verify(candidates, files)
            findings = group_confirmed(candidates, verdicts, changed_lines)
            @confirmed_groups = findings.size
            @unanchored_findings = findings.count { |f| f.anchor_line.nil? }
            @draft = run_synthesize(findings, changed_lines)
          end

          break if head_stable?
          raise HeadMovedError, "head moved before posting on attempt #{attempt}" if attempt >= MAX_ATTEMPTS
        end

        post_review
        build_result
      end

      private

      def pull_request
        @github_client.pull_request(@project.full_name, @agent_run.source_pull_request_number)
      end

      def fetch_files
        @github_client.detailed_pull_request_files(@project.full_name, @agent_run.source_pull_request_number)
      end

      def head_stable?
        pull_request.head.sha == @head_sha
      end

      def run_find(files, pr)
        timed(:find) do
          @llm_calls[:find] += 1
          FindCandidates.call(
            project: @project, pr_number: @agent_run.source_pull_request_number,
            files: files, pr_title: pr.title, pr_body: pr.body, on_usage: method(:record_usage)
          )
        end
      end

      def run_verify(candidates, files)
        return [] if candidates.empty?

        timed(:verify) do
          loader = ->(path) { @github_client.file_content(@project.full_name, path: path, ref: @head_sha) }
          verdicts = VerifyCandidates.call(
            project: @project, head_sha: @head_sha, candidates: candidates,
            files: files, content_loader: loader, on_usage: method(:record_usage)
          )
          @llm_calls[:verify] += verdicts.size
          verdicts
        end
      end

      def group_confirmed(candidates, verdicts, changed_lines)
        confirmed = []
        candidates.zip(verdicts).each do |candidate, verdict|
          @verdicts_summary[verdict.verdict] += 1
          next unless verdict.confirmed?

          path = verdict.corrected_path || candidate.path
          line = verdict.corrected_line || candidate.line
          anchored = changed_lines.valid_line?(path, line)
          confirmed << ConfirmedFinding.new(
            id: candidate.id, anchor_path: path,
            anchor_line: anchored ? line : nil,
            claim_key: verdict.claim_key,
            members: [ { candidate: candidate, verdict: verdict } ]
          )
        end
        collapse_groups(confirmed)
      end

      def collapse_groups(findings)
        findings.group_by { |finding| [ finding.anchor_path, finding.claim_key ] }.values.map do |group|
          first = group.first
          ConfirmedFinding.new(
            id: first.id, anchor_path: first.anchor_path, anchor_line: first.anchor_line,
            claim_key: first.claim_key,
            members: group.flat_map(&:members)
          )
        end
      end

      def run_synthesize(findings, changed_lines)
        timed(:synthesize) do
          @llm_calls[:synthesize] += 1
          SynthesizeReview.call(
            project: @project, findings: findings,
            changed_lines: changed_lines, on_usage: method(:record_usage)
          )
        end
      end

      def post_review
        result = timed(:post) do
          @poster.call(
            agent_run: @agent_run, body: review_body,
            comments: @draft.comments, commit_sha: @head_sha
          )
        end
        @comments_posted = @draft.comments.size
        @review_id = result[:review_id]
        @review_url = result[:review_url]
        @outcome = if result[:already_posted]
          "already_posted"
        elsif @draft.comments.empty?
          "posted_clean"
        else
          "posted_findings"
        end
      end

      def review_body
        return draft_with_bullets if @confirmed_groups.positive?

        withheld = @verdicts_summary[:plausible]
        parts = [ "Generated no new comments." ]
        parts << "#{withheld} plausible-but-unverified observation#{'s' unless withheld == 1}." if withheld.positive?
        parts << CLEAN_MARKER
        parts.join(" ")
      end

      def draft_with_bullets
        return @draft.body if @draft.unanchored_bullets.empty?

        [ @draft.body.presence, *@draft.unanchored_bullets ].compact.join("\n\n")
      end

      def record_usage(usage)
        @tokens_input += usage[:tokens_input].to_i
        @tokens_output += usage[:tokens_output].to_i
        @models << usage[:llm_model] if usage[:llm_model]
        TokenUsageTracker.track(
          tracked_run: @agent_run,
          usage: usage.merge(request_type: "agent", metadata: { operation: usage[:operation].to_s })
        )
      end

      def timed(stage)
        started = monotonic_now
        result = yield
        @latency[stage] = ((monotonic_now - started) * 1000).round
        result
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def build_result
        {
          outcome: @outcome,
          review_id: @review_id,
          review_url: @review_url,
          comments_posted: @comments_posted,
          metrics: {
            attempts: @attempt,
            outcome: @outcome,
            candidates: @verdicts_summary.values.sum,
            verdicts: @verdicts_summary.dup,
            confirmed_groups: @confirmed_groups,
            comments_posted: @comments_posted,
            unanchored_findings: @unanchored_findings,
            plausible_withheld: @verdicts_summary[:plausible],
            llm_calls: @llm_calls.dup,
            latency_ms: @latency.merge(total: ((monotonic_now - @started_at) * 1000).round),
            models: @models.uniq,
            tokens_input: @tokens_input,
            tokens_output: @tokens_output,
            cost_cents: TokenUsageTracker.calculate_cost(
              @tokens_input, @tokens_output, llm_model: @models.first
            )
          }
        }
      end
    end
  end
end
