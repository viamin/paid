# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateMultipleIssuesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt,
      project: project, goal: "create_issue", status: "running", started_at: 1.minute.ago,
      custom_prompt: "Decompose feature into issues")
  end
  let(:github_client) { instance_double(GithubClient) }

  let(:tasks) do
    [
      { index: 0, title: "Add database migration", body: "Create users table", dependencies: [] },
      { index: 1, title: "Add User model", body: "Create ActiveRecord model", dependencies: [ 0 ] },
      { index: 2, title: "Add API endpoint", body: "Create controller action", dependencies: [ 1 ] }
    ]
  end

  def gh_issue_response(number:, id:, title:, body:)
    Struct.new(:number, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at, :html_url).new(
      number, id, title, body, "open",
      Struct.new(:login).new("paid-bot"),
      [], Time.current, Time.current,
      "https://github.com/#{project.full_name}/issues/#{number}"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)

    allow(github_client).to receive(:create_issue).and_return(
      gh_issue_response(number: 101, id: 200_001, title: "Add database migration", body: "body1"),
      gh_issue_response(number: 102, id: 200_002, title: "Add User model", body: "body2"),
      gh_issue_response(number: 103, id: 200_003, title: "Add API endpoint", body: "body3")
    )
  end

  describe "#execute" do
    it "creates GitHub issues for each task" do
      expect(github_client).to receive(:create_issue).exactly(3).times

      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)
    end

    it "creates issues in dependency order (leaves first)" do
      call_order = []
      allow(github_client).to receive(:create_issue) do |_repo, title:, **_opts|
        call_order << title
        gh_issue_response(
          number: 100 + call_order.size,
          id: 200_000 + call_order.size,
          title: title,
          body: "body"
        )
      end

      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      expect(call_order).to eq([
        "Add database migration",
        "Add User model",
        "Add API endpoint"
      ])
    end

    it "includes Depends on #N declarations in dependent issue bodies" do
      call_args = []
      allow(github_client).to receive(:create_issue) do |_repo, **opts|
        call_args << opts
        gh_issue_response(
          number: 100 + call_args.size,
          id: 200_000 + call_args.size,
          title: opts[:title],
          body: opts[:body]
        )
      end

      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      # First issue (no dependencies)
      expect(call_args[0][:body]).not_to include("Depends on")

      # Second issue depends on first (#101)
      expect(call_args[1][:body]).to include("Depends on #101")

      # Third issue depends on second (#102)
      expect(call_args[2][:body]).to include("Depends on #102")
    end

    it "includes a Dependencies section in dependent issues" do
      call_args = []
      allow(github_client).to receive(:create_issue) do |_repo, **opts|
        call_args << opts
        gh_issue_response(
          number: 100 + call_args.size,
          id: 200_000 + call_args.size,
          title: opts[:title],
          body: opts[:body]
        )
      end

      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      expect(call_args[1][:body]).to include("## Dependencies")
    end

    it "returns created issue details" do
      result = activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:created_issues].size).to eq(3)
      expect(result[:created_issues].map { |i| i[:github_number] }).to eq([ 101, 102, 103 ])
    end

    it "completes the agent run with the first created issue" do
      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.created_issue_number).to eq(101)
      expect(agent_run.created_issue_url).to include("/issues/101")
    end

    it "logs all created issue numbers" do
      activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)

      system_logs = agent_run.agent_run_logs.where(log_type: "system")
      combined = system_logs.map(&:content).join(" ")
      expect(combined).to include("#101")
      expect(combined).to include("#102")
      expect(combined).to include("#103")
    end

    context "when parent_issue_number is provided" do
      let(:parent_issue_response) do
        Struct.new(:body).new("# Feature Request\n\nOriginal description.")
      end

      before do
        allow(github_client).to receive(:issue).and_return(parent_issue_response)
        allow(github_client).to receive(:update_issue)
      end

      it "updates the parent issue with a sub-issues task list" do
        expect(github_client).to receive(:update_issue).with(
          project.full_name, 451,
          body: a_string_including("## Sub-issues")
            .and(a_string_including("- [ ] #101"))
            .and(a_string_including("- [ ] #102"))
            .and(a_string_including("- [ ] #103"))
        )

        activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: 451)
      end

      it "returns parent_issue_updated as true" do
        result = activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: 451)

        expect(result[:parent_issue_updated]).to be true
      end

      it "replaces existing Sub-issues section" do
        parent_issue_response = Struct.new(:body).new(
          "# Feature\n\nDesc.\n\n## Sub-issues\n\n- [ ] #99 — Old task"
        )
        allow(github_client).to receive(:issue).and_return(parent_issue_response)

        expect(github_client).to receive(:update_issue).with(
          project.full_name, 451,
          body: a_string_including("- [ ] #101")
            .and(satisfy { |b| !b.include?("- [ ] #99") })
        )

        activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: 451)
      end
    end

    context "when parent issue update fails" do
      before do
        allow(github_client).to receive(:issue).and_raise(StandardError, "Not found")
      end

      it "returns parent_issue_updated as false without failing the activity" do
        result = activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: 999)

        expect(result[:parent_issue_updated]).to be false
        expect(result[:created_issues].size).to eq(3)
      end
    end

    context "with partial failure" do
      it "raises a non-retryable error after partial success" do
        call_count = 0
        allow(github_client).to receive(:create_issue) do |*_args|
          call_count += 1
          if call_count <= 1
            gh_issue_response(number: 101, id: 200_001, title: "Add database migration", body: "body1")
          else
            raise StandardError, "GitHub API timeout"
          end
        end

        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)
        }.to raise_error(Temporalio::Error::ApplicationError, /Partial failure/) { |e|
          expect(e.non_retryable).to be true
        }
      end

      it "lets the error propagate when no issues were created" do
        allow(github_client).to receive(:create_issue).and_raise(StandardError, "GitHub API timeout")

        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)
        }.to raise_error(StandardError, "GitHub API timeout")
      end
    end

    context "with a CanceledError after partial success" do
      it "propagates the cancellation" do
        call_count = 0
        allow(github_client).to receive(:create_issue) do |*_args|
          call_count += 1
          if call_count == 1
            gh_issue_response(number: 101, id: 200_001, title: "Add database migration", body: "body1")
          else
            raise Temporalio::Error::CanceledError, "activity canceled"
          end
        end

        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)
        }.to raise_error(Temporalio::Error::CanceledError)
      end
    end

    context "with invalid input" do
      it "raises a non-retryable error when tasks is not an Array" do
        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: "not an array", parent_issue_number: nil)
        }.to raise_error(Temporalio::Error::ApplicationError, /must be a non-empty Array/)
      end

      it "raises a non-retryable error when tasks is empty" do
        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: [], parent_issue_number: nil)
        }.to raise_error(Temporalio::Error::ApplicationError, /must be a non-empty Array/)
      end

      it "raises a non-retryable error when a task has a blank title" do
        bad_tasks = [ { index: 0, title: "", body: "body", dependencies: [] } ]

        expect {
          activity.execute(agent_run_id: agent_run.id, tasks: bad_tasks, parent_issue_number: nil)
        }.to raise_error(Temporalio::Error::ApplicationError, /non-blank title/)
      end
    end

    context "with multiple dependencies" do
      let(:parallel_tasks) do
        [
          { index: 0, title: "Task A", body: "Foundation A", dependencies: [] },
          { index: 1, title: "Task B", body: "Foundation B", dependencies: [] },
          { index: 2, title: "Task C", body: "Depends on A and B", dependencies: [ 0, 1 ] }
        ]
      end

      it "includes multiple Depends on declarations" do
        call_args = []
        allow(github_client).to receive(:create_issue) do |_repo, **opts|
          call_args << opts
          gh_issue_response(
            number: 100 + call_args.size,
            id: 200_000 + call_args.size,
            title: opts[:title],
            body: opts[:body]
          )
        end

        activity.execute(agent_run_id: agent_run.id, tasks: parallel_tasks, parent_issue_number: nil)

        last_body = call_args.last[:body]
        expect(last_body).to include("Depends on #101")
        expect(last_body).to include("Depends on #102")
      end
    end

    context "when automation labels are enabled" do
      before { project.update!(automation_on_label_enabled: true) }

      it "adds the automation label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: a_collection_including(project.automation_label_name))
        ).exactly(3).times

        activity.execute(agent_run_id: agent_run.id, tasks: tasks, parent_issue_number: nil)
      end
    end
  end
end
