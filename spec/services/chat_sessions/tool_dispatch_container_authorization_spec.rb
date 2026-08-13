# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessions::ToolDispatch do
  let(:backend_class) do
    Class.new do
      def get_container(_id); end
    end
  end
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:denied_user) { create(:user, :member, account: create(:account)) }
  let(:session) do
    create(:chat_session, :workspace, account:, created_by: denied_user, clone_manifest: [
      { project_id: project.id, path: "/workspace/repo-one" }
    ])
  end
  let(:backend) { instance_spy(backend_class) }
  let(:dispatcher_class) do
    Class.new do
      include ChatSessions::ToolDispatch

      attr_reader :chat_session

      def initialize(chat_session)
        @chat_session = chat_session
      end

      def dispatch(name:, arguments:)
        dispatch_tool(name:, arguments:)
      end
    end
  end

  it "returns a structured unauthorized error without executing in the container" do
    previous_backend = Rails.application.config.x.container_backend
    Rails.application.config.x.container_backend = backend

    result = dispatcher_class.new(session).dispatch(name: "git_status", arguments: { "repo_path" => "/workspace/repo-one" })

    expect(result).to include(status: "error", error: "unauthorized")
    expect(backend).not_to have_received(:get_container)
  ensure
    Rails.application.config.x.container_backend = previous_backend
  end
end
