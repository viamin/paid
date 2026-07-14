# frozen_string_literal: true

require "rails_helper"

# RDR-002 alignment guard.
#
# PromptEvolutionWorkflow and KnowledgeEvolutionWorkflow are not poll
# workflows, so the worker (`bin/temporal_worker`) registers them on the
# agent task queue (default `paid-agent-tasks`). The jobs that start
# these workflows MUST route start calls to the same task queue or the
# worker will silently drop the workflow task.
#
# This spec fails loudly when:
#   1. Either job hard-codes a literal task queue name.
#   2. Either job reaches for the legacy `TEMPORAL_TASK_QUEUE` ENV
#      fallback (which defaults to `"paid-tasks"` — a queue no worker
#      polls today).
#   3. Either job references a queue that does not match the worker
#      registration in `bin/temporal_worker`.
RSpec.describe "Evolution task queue alignment", :no_db do # rubocop:disable RSpec/DescribeClass
  around do |example|
    original_agent = ENV["TEMPORAL_AGENT_TASK_QUEUE"]
    original_poll = ENV["TEMPORAL_POLL_TASK_QUEUE"]
    ENV.delete("TEMPORAL_AGENT_TASK_QUEUE")
    ENV.delete("TEMPORAL_POLL_TASK_QUEUE")
    example.run
  ensure
    ENV.delete("TEMPORAL_AGENT_TASK_QUEUE")
    ENV.delete("TEMPORAL_POLL_TASK_QUEUE")
    ENV["TEMPORAL_AGENT_TASK_QUEUE"] = original_agent
    ENV["TEMPORAL_POLL_TASK_QUEUE"] = original_poll
  end

  let(:job_files) do
    %w[
      app/jobs/prompt_evolution_job.rb
      app/jobs/knowledge_evolution_job.rb
    ].map { |path| Rails.root.join(path) }
  end

  let(:worker_file) { Rails.root.join("bin/temporal_worker") }
  let(:workflow_classes) do
    Workflows.constants.map { |constant| Workflows.const_get(constant) }
             .select { |constant| constant.is_a?(Class) && constant < Workflows::BaseWorkflow }
  end
  let(:agent_workflows) { workflow_classes.reject { |workflow| workflow == Workflows::GitHubPollWorkflow } }
  let(:poll_workflows) { workflow_classes.select { |workflow| workflow == Workflows::GitHubPollWorkflow } }

  it "registers PromptEvolutionWorkflow and KnowledgeEvolutionWorkflow on the agent queue" do
    worker_content = worker_file.read

    expect(worker_content).to include("workflows: agent_workflows")
    expect(worker_content).to include("task_queue: Paid.agent_task_queue"),
      "bin/temporal_worker must register non-poll workflows (including PromptEvolutionWorkflow " \
      "and KnowledgeEvolutionWorkflow) on Paid.agent_task_queue so agent_workflows actually polls them"
    expect(agent_workflows).to include(
      Workflows::PromptEvolutionWorkflow,
      Workflows::KnowledgeEvolutionWorkflow
    ), "agent_workflows must include PromptEvolutionWorkflow and KnowledgeEvolutionWorkflow so " \
       "their start_workflow calls reach a worker polling Paid.agent_task_queue"
    expect(poll_workflows).not_to include(
      Workflows::PromptEvolutionWorkflow,
      Workflows::KnowledgeEvolutionWorkflow
    ), "PromptEvolutionWorkflow and KnowledgeEvolutionWorkflow must not be routed to poll_workflows"
  end

  it "does not start evolution workflows on the poll queue" do
    job_files.each do |path|
      content = path.read
      expect(content).not_to match(/task_queue:\s*Paid\.poll_task_queue/),
        "#{path.basename} must not start workflows on Paid.poll_task_queue"
    end
  end

  it "does not reference the legacy TEMPORAL_TASK_QUEUE ENV var" do
    job_files.each do |path|
      content = path.read
      expect(content).not_to include("TEMPORAL_TASK_QUEUE"),
        "#{path.basename} must not fall back to the legacy TEMPORAL_TASK_QUEUE ENV var " \
        "(defaults to paid-tasks, which no worker polls). Use Paid.agent_task_queue instead."
    end
  end

  it "does not hard-code a literal task queue name" do
    job_files.each do |path|
      content = path.read
      expect(content).not_to match(/task_queue:\s*["'](?:paid-[a-z-]+|agent-harness)["']/),
        "#{path.basename} must not hard-code a task queue string. Use Paid.agent_task_queue " \
        "so the queue stays in sync with bin/temporal_worker and the ENV override."
    end
  end

  describe "PromptEvolutionJob#perform" do
    it "starts PromptEvolutionWorkflow on Paid.agent_task_queue" do
      env = ENV.to_h
      content = Rails.root.join("app/jobs/prompt_evolution_job.rb").read
      expect(content).to match(/task_queue:\s*Paid\.agent_task_queue/),
        "PromptEvolutionJob must start PromptEvolutionWorkflow on Paid.agent_task_queue so the " \
        "agent worker (which registers the workflow there) picks the task up"
    ensure
      ENV.replace(env) # rubocop:disable Rails/EnvironmentVariableAccess
    end
  end

  describe "KnowledgeEvolutionJob#perform" do
    it "starts KnowledgeEvolutionWorkflow on Paid.agent_task_queue" do
      env = ENV.to_h
      content = Rails.root.join("app/jobs/knowledge_evolution_job.rb").read
      expect(content).to match(/task_queue:\s*Paid\.agent_task_queue/),
        "KnowledgeEvolutionJob must start KnowledgeEvolutionWorkflow on Paid.agent_task_queue " \
        "so the agent worker (which registers the workflow there) picks the task up"
    ensure
      ENV.replace(env) # rubocop:disable Rails/EnvironmentVariableAccess
    end
  end

  describe "Paid.task_queue helpers" do
    it "aligns Paid.agent_task_queue defaults with bin/temporal_worker" do
      expect(Paid.agent_task_queue).to eq("paid-agent-tasks"),
        "bin/temporal_worker registers the agent worker on Paid.agent_task_queue — jobs " \
        "starting workflows there must agree"
    end

    it "aligns Paid.poll_task_queue defaults with bin/temporal_worker" do
      expect(Paid.poll_task_queue).to eq("paid-poll-tasks")
    end
  end
end
