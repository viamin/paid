# frozen_string_literal: true

module DesignArtifactFindings
  # Queues one focused design-repair run for stale document linkage. The run,
  # not this request, produces the PR; reconciliation remains the verifier.
  # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
  class RepairDocumentLinks
    METADATA_KEY = "design_artifact_finding_id"

    def self.call(...) = new(...).call

    def initialize(finding:, user:, revision:)
      @finding = finding
      @user = user
      @revision = revision.to_s
    end

    def call
      finding.with_lock do
        validate!
        existing_run || create_run
      end
    end

    private

    attr_reader :finding, :revision, :user

    def validate!
      raise ArgumentError, "document-link repair is only available for stale metadata" unless finding.state == "stale_metadata"
      raise ArgumentError, "finding changed; reload before repairing links" unless finding.revision == revision
    end

    def existing_run
      finding.project.agent_runs.where(goal: "create_pr", status: AgentRun::DEDUP_BLOCKING_STATUSES).find do |run|
        run.external_metadata[METADATA_KEY].to_s == finding.id.to_s
      end
    end

    def create_run
      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: finding.project, goal: "create_pr")
      run = AgentRun.create!(
        project: finding.project, initiating_user: user, runner_id:, agent_type:, goal: "create_pr", status: "queued",
        trigger_type: "manual", custom_prompt: prompt, external_metadata: { METADATA_KEY => finding.id, "revision" => revision }
      )
      finding.update!(
        status: "assigned", resolution_state: "assigned", resolution_reason: "Queued design repair run ##{run.id} to repair document links.",
        resolution_actor: user, resolution_metadata: { "revision" => revision, "design_repair_run_id" => run.id, "decided_at" => Time.current.iso8601 }
      )
      ProcessRunQueueJob.perform_later
      run
    end

    def prompt
      <<~PROMPT
        Repair only the traceability links in `#{finding.artifact_path}` at revision `#{revision}`. Open a design PR that adds or corrects explicit qualified issue links. Do not infer implementation or change product behavior.

        Reconciliation evidence:
        #{finding.evidence.map { |item| "- #{item}" }.join("\n")}
      PROMPT
    end
  end
end
