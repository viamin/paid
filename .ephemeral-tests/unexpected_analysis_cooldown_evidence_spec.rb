# frozen_string_literal: true

# One-off native evidence capture for issue #4821 (remove before merge, see
# .ephemeral-tests/README.md). Reproduces the unexpected-analysis cooldown
# transition (@spec ISSUE-ANALYSIS-018) against the real
# Activities::MarkAgentRunFailedActivity, Issue model, and database, then
# records timing, structured logs, and result snapshots under
# tmp/validation-evidence/4821/ for attachment to the issue.

require "rails_helper"
require "paid/json_log_formatter"

RSpec.describe Activities::MarkAgentRunFailedActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, auto_pick_enabled: true) }
  let(:artifact_dir) { Rails.root.join("tmp/validation-evidence/4821") }

  before(:context) do
    dir = Rails.root.join("tmp/validation-evidence/4821")
    FileUtils.mkdir_p(dir)
    FileUtils.rm_f(Dir[dir.join("*.json*")])
  end

  # Tees Rails logging through the production Paid::JsonLogFormatter into the
  # captured-logs.jsonl artifact so the recorded lines are byte-shape identical
  # to structured production output (OBSERVABILITY-004). Returns only the JSON
  # lines appended by this invocation so examples stay order-safe.
  def with_structured_log_capture
    path = artifact_dir.join("captured-logs.jsonl")
    offset = File.exist?(path) ? File.size(path) : 0
    file = File.open(path, "a")
    file.sync = true
    capture = ActiveSupport::Logger.new(file)
    capture.formatter = Paid::JsonLogFormatter.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::BroadcastLogger.new(original_logger, capture)
    yield
    File.open(path, "r") do |sink|
      sink.seek(offset)
      sink.read.to_s.lines.filter_map { |line| JSON.parse(line) }
    end
  ensure
    Rails.logger = original_logger
    file.close
  end

  def backoff_recorded_lines(captured)
    captured.select { |payload| payload["message"] == "issue.issue_analysis_backoff_recorded" }
  end

  def record_artifact(name, payload)
    File.write(artifact_dir.join(name), JSON.pretty_generate(payload) << "\n")
  end

  describe "unexpected automatic analyze_issue failure cooldown transition" do
    it "records the transition with native timing, logs, and results" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        goal: "analyze_issue", auto_pick: true)

      state_before = issue.paid_state
      started_at = Time.current
      monotonic_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      captured = with_structured_log_capture do
        activity.execute(
          agent_run_id: agent_run.id,
          error: "wrong number of arguments (given 0, expected 1)",
          failure_type: "ArgumentError"
        )
      end

      monotonic_end = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      finished_at = Time.current

      agent_run.reload
      issue.reload
      duration_ms = ((monotonic_end - monotonic_start) * 1000).round(2)
      window_seconds = (issue.issue_analysis_next_attempt_at - issue.issue_analysis_backoff_set_at).to_i
      recorded_lines = backoff_recorded_lines(captured)

      expect(agent_run.error_message).to eq("wrong number of arguments (given 0, expected 1)")
      expect(agent_run.external_metadata.fetch("issue_analysis_failure")).to eq(
        "category" => "unexpected_application_error",
        "failure_type" => "ArgumentError"
      )
      expect(state_before).to eq("in_progress")
      expect(issue.paid_state).to eq("failed")
      expect(issue.issue_analysis_backoff_set_at).to be_between(started_at, finished_at)
      expect(window_seconds).to eq(300)
      expect(recorded_lines).not_to be_empty
      expect(recorded_lines.first.fetch("next_attempt_at")).to eq(issue.issue_analysis_next_attempt_at.iso8601)
      expect(recorded_lines.first.fetch("consecutive_failures")).to eq(1)

      record_artifact("trigger.json", {
        scenario: "automatic analyze_issue run fails with unexpected ArgumentError",
        spec: "ISSUE-ANALYSIS-018",
        activity: "Activities::MarkAgentRunFailedActivity#execute",
        timing: {
          started_at: started_at.utc.iso8601(3),
          finished_at: finished_at.utc.iso8601(3),
          trigger_duration_ms: duration_ms,
          first_failure_window_seconds: window_seconds
        },
        results: {
          issue_id: issue.id,
          agent_run_id: agent_run.id,
          paid_state_before: state_before,
          paid_state_after: issue.paid_state,
          error_message: agent_run.error_message,
          external_metadata: agent_run.external_metadata,
          issue_analysis_backoff_set_at: issue.issue_analysis_backoff_set_at.utc.iso8601(3),
          issue_analysis_next_attempt_at: issue.issue_analysis_next_attempt_at.utc.iso8601(3)
        },
        logs: recorded_lines
      })
    end

    it "suppresses auto-pick while the cooldown is active and re-includes after expiry" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        goal: "analyze_issue", auto_pick: true)

      with_structured_log_capture do
        activity.execute(
          agent_run_id: agent_run.id,
          error: "undefined method `analyze' for nil:NilClass",
          failure_type: "NoMethodError"
        )
      end
      issue.reload

      suppressed_at = nil
      eligible_ids_during_cooldown = nil
      eligible_ids_after_expiry = nil
      travel_to(issue.issue_analysis_next_attempt_at - 1.minute) do
        suppressed_at = Time.current
        eligible_ids_during_cooldown =
          Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).pluck(:id)
      end
      travel_to(issue.issue_analysis_next_attempt_at + 1.second) do
        eligible_ids_after_expiry =
          Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project).pluck(:id)
      end

      expect(issue.issue_analysis_backoff_active?(now: suppressed_at)).to be(true)
      expect(eligible_ids_during_cooldown).not_to include(issue.id)
      expect(eligible_ids_after_expiry).to include(issue.id)

      record_artifact("auto-pick-suppression.json", {
        scenario: "auto-pick exclusion while cooldown is active and re-inclusion after expiry",
        spec: "ISSUE-ANALYSIS-018",
        timing: {
          checked_during_cooldown_at: suppressed_at.utc.iso8601(3),
          next_attempt_at: issue.issue_analysis_next_attempt_at.utc.iso8601(3),
          checked_after_expiry_at: (issue.issue_analysis_next_attempt_at + 1.second).utc.iso8601(3)
        },
        results: {
          issue_id: issue.id,
          eligible_ids_during_cooldown: eligible_ids_during_cooldown,
          eligible_ids_after_expiry: eligible_ids_after_expiry,
          backoff_active_during_cooldown: true
        }
      })
    end

    it "exempts manual retries from the cooldown" do
      issue = create(:issue, :in_progress, project: project)
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        goal: "analyze_issue", auto_pick: false)

      with_structured_log_capture do
        activity.execute(
          agent_run_id: agent_run.id,
          error: "wrong number of arguments (given 0, expected 1)",
          failure_type: "ArgumentError"
        )
      end

      agent_run.reload
      issue.reload

      expect(issue.issue_analysis_next_attempt_at).to be_nil
      expect(issue.issue_analysis_backoff_set_at).to be_nil
      expect(agent_run.external_metadata["issue_analysis_failure"]).to be_nil

      record_artifact("manual-exemption.json", {
        scenario: "identical unexpected failure on a manual (non auto-pick) analyze_issue run",
        spec: "ISSUE-ANALYSIS-018",
        results: {
          issue_id: issue.id,
          agent_run_id: agent_run.id,
          auto_pick: false,
          issue_analysis_next_attempt_at: nil,
          issue_analysis_backoff_set_at: nil,
          failure_metadata_recorded: false
        }
      })
    end

    it "caps the cooldown at one hour for repeated unexpected failures" do
      issue = create(:issue, :in_progress, project: project)
      12.times do
        run = create(:agent_run, :failed, :automatic, project: project, issue: issue,
          goal: "analyze_issue", auto_pick: true, error_message: "wrong number of arguments")
        run.update!(external_metadata: { "issue_analysis_failure" => {
          "category" => "unexpected_application_error", "failure_type" => "ArgumentError"
        } })
      end
      agent_run = create(:agent_run, :running, project: project, issue: issue,
        goal: "analyze_issue", auto_pick: true)

      triggered_at = nil
      capped_line = nil
      travel_to(Time.current) do
        triggered_at = Time.current
        captured = with_structured_log_capture do
          activity.execute(
            agent_run_id: agent_run.id,
            error: "wrong number of arguments (given 0, expected 1)",
            failure_type: "ArgumentError"
          )
        end
        capped_line = backoff_recorded_lines(captured).last
      end
      issue.reload

      window_seconds = (issue.issue_analysis_next_attempt_at - issue.issue_analysis_backoff_set_at).to_i

      # The streak counter is bounded by ISSUE_ANALYSIS_BACKOFF_HISTORY_LIMIT
      # (12), so the 13th consecutive failure records the capped count.
      expect(window_seconds).to eq(3600)
      expect(capped_line.fetch("consecutive_failures")).to eq(12)

      record_artifact("cap.json", {
        scenario: "13th consecutive unexpected automatic analysis failure",
        spec: "ISSUE-ANALYSIS-018",
        timing: {
          triggered_at: triggered_at.utc.iso8601(3),
          capped_window_seconds: window_seconds
        },
        results: {
          issue_id: issue.id,
          prior_consecutive_failures: 12,
          recorded_consecutive_failures: capped_line.fetch("consecutive_failures"),
          issue_analysis_next_attempt_at: issue.issue_analysis_next_attempt_at.utc.iso8601(3)
        },
        logs: [ capped_line ]
      })
    end
  end

  after(:context) do
    dir = Rails.root.join("tmp/validation-evidence/4821")
    artifacts = Dir[dir.join("*.json")].sort.map do |path|
      { File.basename(path, ".json") => JSON.parse(File.read(path)) }
    end.reduce({}, :merge)
    File.write(dir.join("evidence.json"), JSON.pretty_generate({
      captured_at: Time.current.utc.iso8601(3),
      issue: 4821,
      spec: "ISSUE-ANALYSIS-018",
      artifacts: artifacts
    }) << "\n")
  end
end
