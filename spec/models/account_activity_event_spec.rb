# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccountActivityEvent do
  describe ".actions_for_category" do
    it "returns actions for a given category" do
      project_actions = described_class.actions_for_category("project")
      expect(project_actions).to include("project.created", "project.updated", "project.deleted")
    end

    it "returns empty array for unknown category" do
      expect(described_class.actions_for_category("nonexistent")).to eq([])
    end
  end

  describe "#category" do
    it "returns the category for a known action" do
      event = described_class.new(action: "project.created")
      expect(event.category).to eq("project")
    end

    it "returns other for unknown action" do
      event = described_class.new(action: "custom.action")
      expect(event.category).to eq("other")
    end
  end

  describe "#description" do
    it "renders a human-friendly invitation message" do
      event = described_class.new(action: "membership.invited", metadata: {
        "email" => "person@example.com",
        "role" => "admin"
      })

      expect(event.description).to eq("Invited person@example.com as admin")
    end

    it "falls back to unknown values when metadata is missing" do
      event = described_class.new(action: "membership.role_changed", metadata: {})

      expect(event.description).to eq("Changed unknown from unknown to unknown")
    end

    it "describes project creation" do
      event = described_class.new(action: "project.created", metadata: { "name" => "my-repo" })
      expect(event.description).to eq("Created project my-repo")
    end

    it "describes project update" do
      event = described_class.new(action: "project.updated", metadata: { "name" => "my-repo" })
      expect(event.description).to eq("Updated project my-repo")
    end

    it "describes project deletion" do
      event = described_class.new(action: "project.deleted", metadata: { "name" => "my-repo" })
      expect(event.description).to eq("Deleted project my-repo")
    end

    it "describes runner creation" do
      event = described_class.new(action: "runner.created", metadata: { "runner_name" => "Claude" })
      expect(event.description).to eq("Added Claude runner")
    end

    it "describes agent run creation" do
      event = described_class.new(action: "agent_run.created", metadata: {
        "agent_run_id" => 42, "project_name" => "my-repo"
      })
      expect(event.description).to eq("Created agent run #42 on my-repo")
    end

    it "describes agent run cancellation" do
      event = described_class.new(action: "agent_run.cancelled", metadata: { "agent_run_id" => 42 })
      expect(event.description).to eq("Cancelled agent run #42")
    end

    it "describes agent run retry" do
      event = described_class.new(action: "agent_run.retried", metadata: {
        "agent_run_id" => 42, "new_agent_run_id" => 99
      })
      expect(event.description).to eq("Retried agent run #42 -> #99")
    end

    it "describes prompt approval" do
      event = described_class.new(action: "prompt_version.approved", metadata: {
        "prompt_slug" => "my-prompt", "version" => 3
      })
      expect(event.description).to eq("Approved prompt my-prompt v3")
    end

    it "describes prompt rejection" do
      event = described_class.new(action: "prompt_version.rejected", metadata: {
        "prompt_slug" => "my-prompt", "version" => 3
      })
      expect(event.description).to eq("Rejected prompt my-prompt v3")
    end

    it "describes auth sign in" do
      event = described_class.new(action: "auth.sign_in")
      expect(event.description).to eq("Signed in")
    end

    it "describes password change" do
      event = described_class.new(action: "auth.password_changed")
      expect(event.description).to eq("Changed password")
    end

    it "falls back to humanized action for unknown actions" do
      event = described_class.new(action: "custom.event")
      expect(event.description).to eq("Custom.event")
    end
  end

  describe "#detail_lines" do
    it "returns changed fields for project updates" do
      event = described_class.new(action: "project.updated", metadata: { "changed_fields" => %w[name owner] })
      expect(event.detail_lines).to eq([ "Name changed", "Owner changed" ])
    end

    it "returns notes for prompt approval" do
      event = described_class.new(action: "prompt_version.approved", metadata: { "notes" => "LGTM" })
      expect(event.detail_lines).to eq([ "Notes: LGTM" ])
    end

    it "returns notes for prompt rejection" do
      event = described_class.new(action: "prompt_version.rejected", metadata: { "notes" => "Needs work" })
      expect(event.detail_lines).to eq([ "Notes: Needs work" ])
    end

    it "returns empty array for run events" do
      event = described_class.new(action: "agent_run.created")
      expect(event.detail_lines).to eq([])
    end
  end

  describe "scopes" do
    let(:account) { Account.create!(name: "test-acct", plan: "free") }

    it "filters by action" do
      account.account_activity_events.create!(action: "project.created")
      account.account_activity_events.create!(action: "runner.created")

      expect(account.account_activity_events.by_action("project.created").count).to eq(1)
    end

    it "filters by category" do
      account.account_activity_events.create!(action: "project.created")
      account.account_activity_events.create!(action: "runner.created")
      account.account_activity_events.create!(action: "membership.invited", metadata: { email: "a@b.com" })

      expect(account.account_activity_events.by_category("project").count).to eq(1)
      expect(account.account_activity_events.by_category("runner").count).to eq(1)
      expect(account.account_activity_events.by_category("membership").count).to eq(1)
    end
  end
end
