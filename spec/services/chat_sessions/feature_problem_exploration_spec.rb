# frozen_string_literal: true

require "rails_helper"

# Representative evaluation scenarios for the optional problem-exploration step
# in feature-design chat (#4021). The semantic judgments — recognizing an
# exploration request, separating observed conditions from assumed causes,
# comparing framings — live in the model through the chat guidance. These
# specs pin the orchestration contract around those judgments: the guidance
# reaches the model through the persisted system prompt, the tools the guidance
# names stay inside the existing chat tool boundary, and exploration outcomes
# ("investigate first", "do not build") never trigger implementation work on
# their own.
# @spec FEATURE-CREATION-003
# @spec FEATURE-CREATION-006
RSpec.describe "Feature-design problem exploration in chat", type: :model do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:chat_session) { ChatSessions::Create.call(account: account, user: user, project_id: project.id) }
  let(:captured_conversations) { [] }

  let(:llm_client) do
    lambda do |conversation, **|
      captured_conversations << conversation
      { content: exploration_reply, tool_calls: [], tokens_input: 120, tokens_output: 80, model: "test-model" }
    end
  end

  let(:exploration_reply) do
    "Exploration summary:\n" \
      "- Observations and evidence: review requests sit unanswered for days; two reviewers handle most traffic.\n" \
      "- Affected stakeholders: requesters, reviewers.\n" \
      "- Chosen framing: overloaded reviewers (hypothesis — queue data would confirm).\n" \
      "- Assumptions: request volume, not notification gaps.\n" \
      "- Desired outcome: requests get timely answers.\n" \
      "- Reconsider if delay data shows requests cluster on one owner instead of spreading evenly."
  end

  describe "activation through existing chat orchestration" do
    it "delivers the exploration guidance inside the session's system prompt" do
      ChatSessions::SendMessage.call(
        chat_session: chat_session,
        content: "before designing anything, let's explore the problem behind slow reviews",
        llm_client: llm_client
      )

      system_content = captured_conversations.first
        .filter_map { |entry| entry[:content] if entry[:role] == "system" }
        .join("\n")

      expect(system_content).to match(/explore the problem/i)
      expect(system_content).to include('never run a fixed questionnaire')
      expect(system_content).to include('justify reconsidering')
    end

    it "keeps the user's exploration message and the model's summary in the same conversation" do
      message = ChatSessions::SendMessage.call(
        chat_session: chat_session,
        content: "can we reframe this feature around the real problem?",
        llm_client: llm_client
      )

      expect(message.role).to eq("assistant")
      expect(chat_session.messages.where(role: "user").order(:id).last.content)
        .to include("reframe this feature")
      expect(message.content).to include("Exploration summary")
    end
  end

  describe "no-build outcome scenario" do
    it "persists the summary without triggering an agent run or pausing for confirmation" do
      expect {
        ChatSessions::SendMessage.call(
          chat_session: chat_session,
          content: "given that framing, let's decide not to build this for now",
          llm_client: llm_client
        )
      }.not_to change(AgentRun, :count)

      expect(project.agent_runs).to be_empty
      expect(chat_session.messages.where(tool_status: "pending")).to be_empty
      expect(chat_session.messages.where(tool_name: "trigger_agent_run")).to be_empty
    end
  end

  describe "investigate-first outcome scenario" do
    let(:exploration_reply) do
      "Suggested observation: for two weeks, record how long each review request waits and who picks it up. " \
        "Share the numbers here and we can re-examine the framing then."
    end

    it "suggests the observation in chat without creating a run or an approval pause" do
      expect {
        ChatSessions::SendMessage.call(
          chat_session: chat_session,
          content: "should we investigate the queue before building?",
          llm_client: llm_client
        )
      }.not_to change(AgentRun, :count)

      expect(project.agent_runs).to be_empty
      expect(chat_session.messages.where(tool_status: "pending")).to be_empty
    end
  end

  describe "proceeding from exploration to a create_feature run" do
    let(:llm_client) do
      lambda do |conversation, **|
        captured_conversations << conversation
        {
          content: "Framing settled. Triggering the design run.",
          tool_calls: [
            {
              id: "proceed_1",
              name: "trigger_agent_run",
              arguments: { "project_id" => project.id, "goal" => "create_feature", "custom_prompt" => "brief" }
            }
          ],
          tokens_input: 120, tokens_output: 80, model: "test-model"
        }
      end
    end

    it "pauses on the existing write-tool confirmation boundary instead of running" do
      expect {
        ChatSessions::SendMessage.call(
          chat_session: chat_session,
          content: "that framing is right — go ahead and design it",
          llm_client: llm_client
        )
      }.not_to change(AgentRun, :count)

      pending_message = chat_session.messages.find_by(tool_status: "pending")
      expect(pending_message.tool_name).to eq("trigger_agent_run")
      expect(pending_message.tool_arguments).to include("goal" => "create_feature")
      expect(project.agent_runs).to be_empty
    end
  end

  describe "tool boundary" do
    it "advertises the repo-read and run-trigger tools the guidance relies on" do
      names = Tools::Registry.chat_definitions_for(user: user, session: chat_session).map { |d| d[:name] }

      expect(names).to include("search_code")
      expect(names).to include("read_repo_file")
      expect(names).to include("trigger_agent_run")
    end

    it "keeps run triggering a write operation behind the confirmation boundary" do
      expect(Tools::Registry.write_tool?("trigger_agent_run")).to be(true)
    end
  end
end
