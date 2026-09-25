# frozen_string_literal: true

module DesignAmendments
  # Applies a merged design amendment's revision impact across the feature's
  # branches (RDR-067 §Revision impact):
  #
  # - open PRs and unstarted issues mapped `affected` are held, plus their
  #   dependency closure (transitive dependents);
  # - `uncertain` branches are held and explained to a human (blocking
  #   notification with the cited claims);
  # - `unaffected` branches receive nothing and keep running;
  # - merged PRs mapped `affected` (or uncertain) become follow-up decisions
  #   for a human — never an automatic rollback;
  # - a failed review fails closed: every branch is held uncertain and every
  #   merged PR gets a follow-up.
  # @spec INTENT-AMENDMENT-005 @spec INTENT-AMENDMENT-006
  # @spec INTENT-AMENDMENT-007 @spec INTENT-AMENDMENT-008
  class EvaluateImpact
    UNCERTAIN_NOTIFICATION_SOURCE = "design_amendment.uncertain_impact"
    FOLLOW_UP_NOTIFICATION_SOURCE = "design_amendment.merged_follow_up"

    Result = Data.define(:paused, :follow_ups, :review_failed)

    # Sentinel distinguishing "no review supplied yet, compute one" (the
    # default) from "a review was already attempted and failed" (`nil`,
    # passed explicitly). Without this, a nil review from a failed
    # .review_for call would look identical to an uncomputed one and
    # #call would silently retry the LLM request.
    REVIEW_NOT_COMPUTED = Object.new.freeze
    private_constant :REVIEW_NOT_COMPUTED

    def self.call(...)
      new(...).call
    end

    # Runs the LLM impact review ahead of time, outside of any open
    # transaction, so callers that wrap `call` in a DB transaction (e.g.
    # DesignAmendments::Complete) aren't holding locks open for the
    # network round trip. Returns nil when there are no branches to assess
    # or when the review fails.
    def self.review_for(amendment)
      candidates = new(amendment: amendment).branch_candidates
      return if candidates.empty?

      ImpactReview.call(amendment: amendment, branches: candidates)
    end

    def initialize(amendment:, review: REVIEW_NOT_COMPUTED)
      @amendment = amendment
      @review = review
    end

    def call
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return empty_result if branch_candidates.empty?

      review_result = review.equal?(REVIEW_NOT_COMPUTED) ? ImpactReview.call(amendment: amendment, branches: branch_candidates) : review
      mapping = review_result ? review_result.mapping : fail_closed_mapping

      paused = apply_pause_set(mapping)
      follow_ups = record_merged_follow_ups(mapping)

      amendment.update!(impact: impact_snapshot(mapping, paused, follow_ups), evaluated_at: Time.current)
      log_completion(paused, follow_ups, review_result, started_at)

      Result.new(paused:, follow_ups:, review_failed: review_result.nil?)
    end

    # Public so .review_for can gather branches ahead of #call, before any
    # DB transaction is open.
    def branch_candidates
      open_prs.map { |issue| { issue: issue, kind: "open_pr" } } +
        unstarted_issues.map { |issue| { issue: issue, kind: "unstarted_issue" } } +
        merged_prs.map { |issue| { issue: issue, kind: "merged_pr" } }
    end

    private

    attr_reader :amendment, :review

    def empty_result
      amendment.update!(impact: {}, evaluated_at: Time.current)
      Result.new(paused: {}, follow_ups: [], review_failed: false)
    end

    def linked_issues
      amendment.feature_intent.issues
    end

    def open_prs
      linked_issues.where(is_pull_request: true, github_state: "open")
    end

    def unstarted_issues
      linked_issues.where(is_pull_request: false, github_state: "open")
    end

    def merged_prs
      linked_issues.where(is_pull_request: true, pr_review_phase: "merged")
    end

    def runnable_branches
      @runnable_branches ||= open_prs.to_a + unstarted_issues.to_a
    end

    def merged_issues
      @merged_issues ||= merged_prs.to_a
    end

    # Reviewer failure is uncertain for every branch (fail closed).
    def fail_closed_mapping
      uncertain = { impact: "uncertain", cited_claims: [], explanation: "Impact review failed; held for a human decision." }
      (runnable_branches + merged_issues).to_h { |issue| [ issue.id, uncertain ] }
    end

    def apply_pause_set(mapping)
      affected_ids = runnable_branches
        .select { |issue| mapping.dig(issue.id, :impact) == "affected" }
        .map(&:id)
      closure = PauseSet.build(
        affected_issue_ids: affected_ids,
        adjacency: IssueDependency.project_adjacency(amendment.project)
      )

      paused = {}
      # The closure may include dependents outside the feature tree; they
      # pause with their affected dependency, so pause records are created
      # from the closure itself, not only from feature-linked branches.
      closure_issues_by_id = Issue.where(id: closure.keys).index_by(&:id)
      closure.each do |issue_id, reason_code|
        issue = closure_issues_by_id[issue_id]
        next unless issue

        create_pause(issue, reason_code, closure_evidence(mapping, issue_id, reason_code))
        paused[issue_id] = reason_code
      end

      runnable_branches.each do |issue|
        next if paused.key?(issue.id)
        next unless uncertain_reason(mapping, issue)

        create_pause(issue, "uncertain", mapping[issue.id] || {})
        paused[issue.id] = "uncertain"
      end

      paused
    end

    def closure_evidence(mapping, issue_id, reason_code)
      return { impact: "dependent", cited_claims: [], explanation: "Depends on a branch paused by the design amendment." } if reason_code == "dependent"

      mapping[issue_id] || {}
    end

    def uncertain_reason(mapping, issue)
      mapping.dig(issue.id, :impact) == "uncertain" ? "uncertain" : nil
    end

    def create_pause(issue, reason_code, assessment)
      DesignAmendmentPause.find_or_create_by!(design_amendment: amendment, issue: issue) do |pause|
        pause.reason_code = reason_code
        pause.status = "held"
        pause.evidence = evidence_for(assessment, reason_code)
      end
      return unless reason_code == "uncertain"

      Notifications::Publish.call(
        account: issue.project.account,
        source: UNCERTAIN_NOTIFICATION_SOURCE,
        subject: issue,
        severity: :error,
        title: "Design amendment impact is uncertain for #{issue.title}",
        description: assessment[:explanation].to_s,
        blocking: true,
        metadata: {
          "design_amendment_id" => amendment.id,
          "cited_claims" => Array(assessment[:cited_claims]),
          "explanation" => assessment[:explanation].to_s,
          "recommended_action" => "Review the amended design, then release or repoint the held branch."
        }
      )
    end

    def record_merged_follow_ups(mapping)
      merged_issues
        .select { |issue| mapping.dig(issue.id, :impact).in?(%w[affected uncertain]) }
        .map do |issue|
          assessment = mapping[issue.id] || {}
          DesignAmendmentFollowUp.find_or_create_by!(design_amendment: amendment, issue: issue) do |follow_up|
            follow_up.status = "open"
            follow_up.evidence = evidence_for(assessment, "merged_follow_up")
          end
          notify_follow_up(issue, assessment)
          issue.id
        end
    end

    def notify_follow_up(issue, assessment)
      Notifications::Publish.call(
        account: issue.project.account,
        source: FOLLOW_UP_NOTIFICATION_SOURCE,
        subject: issue,
        severity: :error,
        title: "Design amendment affects merged work: #{issue.title}",
        description: assessment[:explanation].to_s,
        blocking: true,
        metadata: {
          "design_amendment_id" => amendment.id,
          "follow_up" => true,
          "cited_claims" => Array(assessment[:cited_claims]),
          "explanation" => assessment[:explanation].to_s,
          "recommended_action" => "Decide whether the merged work needs a follow-up change; nothing is rolled back automatically."
        }
      )
    end

    def evidence_for(assessment, reason_code)
      {
        "impact" => assessment[:impact].to_s,
        "cited_claims" => Array(assessment[:cited_claims]),
        "explanation" => assessment[:explanation].to_s,
        "reason_code" => reason_code
      }
    end

    def impact_snapshot(mapping, paused, follow_ups)
      mapping.to_h do |issue_id, assessment|
        action = if follow_ups.include?(issue_id)
          "follow_up"
        elsif paused[issue_id]
          "paused"
        else
          "none"
        end
        [ issue_id.to_s, assessment.merge("action" => action) ]
      end
    end

    def log_completion(paused, follow_ups, review_result, started_at)
      Rails.logger.info(
        message: "design_amendments.impact_evaluated",
        project_id: amendment.project_id,
        design_amendment_id: amendment.id,
        paused_count: paused.size,
        follow_up_count: follow_ups.size,
        review_confidence: review_result&.confidence,
        review_failed: review_result.nil?,
        duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      )
    end
  end
end
