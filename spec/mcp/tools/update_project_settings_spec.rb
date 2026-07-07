# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::UpdateProjectSettings do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  def call(settings:, confirmed: true, user: owner)
    described_class.new(user:, session:).call(project_id: project.id, settings:, confirmed:)
  end

  describe ".write_operation?" do
    it { expect(described_class.write_operation?).to be(true) }
  end

  describe ".available_to?" do
    it "is available to an owner with an updatable project" do
      project # ensure an updatable project exists in the account
      expect(described_class).to be_available_to(user: owner)
    end

    it "is not available to a viewer" do
      project
      viewer = create(:user, :viewer, account:)
      expect(described_class).not_to be_available_to(user: viewer)
    end

    it "is not available when the account has no projects" do
      expect(described_class).not_to be_available_to(user: owner)
    end
  end

  describe "#call" do
    it "updates permitted attributes and returns them" do
      result = call(settings: { "paused" => true, "auto_pick_enabled" => true })

      expect(result[:id]).to eq(project.id)
      expect(result[:paused]).to be true
      expect(result[:auto_pick_enabled]).to be true
      expect(project.reload).to have_attributes(paused: true, auto_pick_enabled: true)
    end

    it "raises when not confirmed" do
      expect {
        call(settings: { "paused" => true }, confirmed: false)
      }.to raise_error(ArgumentError, /Confirmation required/)
    end

    it "raises when settings is not an object" do
      expect {
        call(settings: "nope")
      }.to raise_error(ArgumentError, /settings must be an object/)
    end

    it "slices to permitted attributes, ignoring identity and credential fields" do
      original_name = project.name
      original_repo = project.repo

      call(settings: {
        "paused" => true,
        "name" => "Hacked",
        "repo" => "stolen",
        "github_token_id" => 999_999,
        "webhook_secret" => "leaked"
      })

      expect(project.reload).to have_attributes(paused: true, name: original_name, repo: original_repo)
    end

    it "records an activity event for changed fields" do
      expect {
        call(settings: { "paused" => true })
      }.to change(AccountActivityEvent, :count).by(1)

      event = account.account_activity_events.last
      expect(event).to have_attributes(
        action: "project.settings_changed",
        actor: owner,
        subject: project
      )
      expect(event.metadata["changed_fields"]).to include("paused")
    end

    it "does not record activity when nothing changed" do
      project.update!(paused: false)

      expect {
        call(settings: { "paused" => false })
      }.not_to change(AccountActivityEvent, :count)
    end

    it "rejects an unauthorized user" do
      viewer = create(:user, :viewer, account:)
      expect {
        call(settings: { "paused" => true }, user: viewer)
      }.to raise_error(Pundit::NotAuthorizedError)
    end

    it "rejects a project from another account" do
      other_project = create(:project)
      expect {
        described_class.new(user: owner, session:).call(
          project_id: other_project.id, settings: { "paused" => true }, confirmed: true
        )
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
