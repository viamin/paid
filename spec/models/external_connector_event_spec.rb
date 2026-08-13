# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExternalConnectorEvent do
  describe "validations" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "validates connector_key against the catalog" do
      event = build(:external_connector_event, project: project, connector_key: "jira")
      expect(event).to be_valid

      event.connector_key = "nonexistent"
      expect(event).not_to be_valid
      expect(event.errors[:connector_key]).to be_present
    end

    it "requires unique external_event_id per project and connector" do
      create(:external_connector_event, project: project, external_event_id: "evt-1", connector_key: "jira", event_type: "issue_created")
      dup = build(:external_connector_event, project: project, external_event_id: "evt-1", connector_key: "jira", event_type: "issue_updated")

      expect(dup).not_to be_valid
    end

    it "allows the same external_event_id across different connectors in one project" do
      create(:external_connector_event, project: project, external_event_id: "shared-evt", connector_key: "jira", event_type: "issue_created")

      other_connector_event = build(:external_connector_event, project: project, external_event_id: "shared-evt", connector_key: "linear", event_type: "issue_created")
      expect(other_connector_event).to be_valid
    end

    it "allows the same external_event_id across different projects" do
      other_project = create(:project, account: account)
      create(:external_connector_event, project: project, external_event_id: "shared-evt", connector_key: "jira", event_type: "issue_created")

      other = build(:external_connector_event, project: other_project, external_event_id: "shared-evt", connector_key: "jira", event_type: "issue_created")
      expect(other).to be_valid
    end

    it "auto-sets account from project" do
      event = build(:external_connector_event, project: project, account: nil)
      event.valid?
      expect(event.account).to eq(project.account)
    end
  end

  describe "#mark_processed!" do
    let(:event) { create(:external_connector_event) }

    it "updates status and sets processed_at" do
      freeze_time do
        event.mark_processed!
        expect(event.reload.status).to eq("processed")
        expect(event.processed_at).to eq(Time.current)
      end
    end
  end

  describe "#mark_failed!" do
    let(:event) { create(:external_connector_event) }

    it "updates status and stores error message" do
      event.mark_failed!(message: "Something went wrong")
      expect(event.reload.status).to eq("failed")
      expect(event.normalized_data["error"]).to eq("Something went wrong")
    end

    it "handles nil normalized_data when storing the error message" do
      event.update_column(:normalized_data, nil)

      event.mark_failed!(message: "Something went wrong")

      expect(event.reload.normalized_data).to eq({ "error" => "Something went wrong" })
    end
  end
end
