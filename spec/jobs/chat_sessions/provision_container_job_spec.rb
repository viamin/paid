# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-CONTAINER-PROVISIONING-002
# @spec CHAT-CONTAINER-PROVISIONING-003
# @spec CHAT-CONTAINER-PROVISIONING-004
# @spec CHAT-CONTAINER-PROVISIONING-006
RSpec.describe ChatSessions::ProvisionContainerJob, type: :job do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }
  let(:stream_name) { "chat_session:#{chat_session.id}" }

  before do
    # ProvisionForChat touches the Docker daemon; the job spec validates the
    # job's orchestration (guarding, broadcasting, error containment) without
    # standing up a real container, matching the ProcessMessageJob spec pattern.
    allow(Containers::ProvisionForChat).to receive(:call) do |kwargs|
      kwargs[:chat_session].update!(
        container_capability: "ready",
        container_id: "chat-container-1",
        container_ready_at: Time.current
      )
      Containers::Provision::Result.success(container_id: "chat-container-1")
    end
  end

  describe "#perform" do
    context "when the session is awaiting provisioning" do
      let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: "pending") }

      it "provisions the container and transitions to ready" do
        described_class.perform_now(chat_session_id: chat_session.id)

        expect(Containers::ProvisionForChat).to have_received(:call).with(chat_session: chat_session, seed_project: true)
        expect(chat_session.reload.container_capability).to eq("ready")
      end

      it "broadcasts the capability change to the chat stream" do
        allow(ActionCable.server).to receive(:broadcast).and_call_original

        described_class.perform_now(chat_session_id: chat_session.id)

        expect(ActionCable.server).to have_received(:broadcast).with(
          stream_name,
          hash_including(type: "capability_changed", container_capability: "ready")
        )
      end
    end

    context "when the session is already provisioning" do
      let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: "provisioning") }

      it "provisions the container" do
        described_class.perform_now(chat_session_id: chat_session.id)

        expect(Containers::ProvisionForChat).to have_received(:call)
      end
    end

    context "when reopening a previously provisioned workspace" do
      let(:chat_session) do
        create(:chat_session, account: account, created_by: user,
          container_capability: "pending",
          metadata: { "workspace_reopen_requested_at" => Time.current.iso8601 })
      end

      it "skips project seeding and restores the clone manifest" do
        allow(ChatSessions::RestoreCloneManifest).to receive(:call)

        described_class.perform_now(chat_session_id: chat_session.id)

        expect(Containers::ProvisionForChat).to have_received(:call)
          .with(hash_including(chat_session: chat_session, seed_project: false))
        expect(ChatSessions::RestoreCloneManifest).to have_received(:call)
      end

      it "moves the session to failed and persists a reopen-failure notice when restore raises" do
        allow(ChatSessions::RestoreCloneManifest).to receive(:call) do |_kwargs|
          raise "Workspace reset failed: permission denied"
        end

        expect {
          described_class.perform_now(chat_session_id: chat_session.id)
        }.not_to raise_error

        expect(chat_session.reload.container_capability).to eq("failed")

        notice = chat_session.messages.system.find_by("metadata ->> 'reopen_clone_failures' = 'true'")
        expect(notice).to be_present
        expect(notice.content).to include("Workspace reopen failed")
        expect(notice.content).to include("Workspace reset failed")
      end

      it "broadcasts the failed capability rather than ready when restore fails" do
        allow(ChatSessions::RestoreCloneManifest).to receive(:call) { raise "Workspace reset failed" }

        expect {
          described_class.perform_now(chat_session_id: chat_session.id)
        }.to have_broadcasted_to(stream_name)
          .with(hash_including(type: "capability_changed", container_capability: "failed"))
      end
    end

    [ "none", "ready", "failed", "stopped" ].each do |capability|
      context "when the session is #{capability}" do
        let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: capability) }

        it "does not provision or broadcast" do
          expect {
            described_class.perform_now(chat_session_id: chat_session.id)
          }.not_to have_broadcasted_to(stream_name)

          expect(Containers::ProvisionForChat).not_to have_received(:call)
        end
      end
    end

    context "when provisioning fails" do
      let(:chat_session) { create(:chat_session, account: account, created_by: user, container_capability: "pending") }

      it "broadcasts the failed capability without re-raising" do
        allow(Containers::ProvisionForChat).to receive(:call) do |kwargs|
          kwargs[:chat_session].update_columns(container_capability: "failed")
          raise Containers::ProvisionForChat::ProvisionError, "Docker error: image pull failed"
        end

        expect {
          described_class.perform_now(chat_session_id: chat_session.id)
        }.to have_broadcasted_to(stream_name)
          .with(hash_including(type: "capability_changed", container_capability: "failed"))

        expect(chat_session.reload.container_capability).to eq("failed")
      end

      it "contains a raw Docker error without re-raising" do
        allow(Containers::ProvisionForChat).to receive(:call) do |kwargs|
          kwargs[:chat_session].update_columns(container_capability: "failed")
          raise Docker::Error::DockerError, "daemon unavailable"
        end

        expect {
          described_class.perform_now(chat_session_id: chat_session.id)
        }.not_to raise_error

        expect(chat_session.reload.container_capability).to eq("failed")
      end

      it "broadcasts timeout failures before re-raising" do
        allow(Containers::ProvisionForChat).to receive(:call) do |kwargs|
          kwargs[:chat_session].update_columns(container_capability: "failed")
          raise ApplicationJob::PerformTimeoutError, "provisioning timed out"
        end

        expect {
          expect {
            described_class.perform_now(chat_session_id: chat_session.id)
          }.to raise_error(ApplicationJob::PerformTimeoutError)
        }.to have_broadcasted_to(stream_name)
          .with(hash_including(type: "capability_changed", container_capability: "failed"))
      end

      it "broadcasts unexpected provisioning failures before re-raising" do
        allow(Containers::ProvisionForChat).to receive(:call) do |kwargs|
          kwargs[:chat_session].update_columns(container_capability: "failed")
          raise StandardError, "unexpected provision failure"
        end

        expect {
          expect {
            described_class.perform_now(chat_session_id: chat_session.id)
          }.to raise_error(StandardError, "unexpected provision failure")
        }.to have_broadcasted_to(stream_name)
          .with(hash_including(type: "capability_changed", container_capability: "failed"))
      end
    end

    context "when the session no longer exists" do
      it "is discarded without raising" do
        expect {
          described_class.perform_now(chat_session_id: 999_999_999)
        }.not_to raise_error
      end
    end
  end

  describe ".good_job_concurrency_config" do
    it "limits provisioning to one job per chat session" do
      chat_session = create(:chat_session, account: account, created_by: user, container_capability: "pending")

      config = described_class.good_job_concurrency_config
      expect(config[:total_limit]).to eq(1)
      expect(config[:enqueue_limit]).to eq(1)
      expect(described_class.new(chat_session_id: chat_session.id).good_job_concurrency_key)
        .to eq(described_class.concurrency_key_for(chat_session.id))
    end
  end
end
