# frozen_string_literal: true

require "rails_helper"

RSpec.describe PreviewSessionPolicy do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:preview_session) { create(:preview_session, project: project) }

  describe "#show?" do
    it "permits account owners" do
      user = create(:user, account: account)

      expect(described_class.new(user, preview_session)).to be_show
    end

    it "permits account admins without project membership" do
      create(:user, account: account)
      user = create(:user, :admin, account: account)

      expect(described_class.new(user, preview_session)).to be_show
    end

    it "does not permit account members without project membership" do
      create(:user, account: account)
      user = create(:user, :member, account: account)

      expect(described_class.new(user, preview_session)).not_to be_show
    end

    it "permits project members" do
      create(:user, account: account)
      user = create(:user, :viewer, account: account)
      user.add_role(:project_member, project)

      expect(described_class.new(user, preview_session)).to be_show
    end

    it "permits project admins" do
      create(:user, account: account)
      user = create(:user, :viewer, account: account)
      user.add_role(:project_admin, project)

      expect(described_class.new(user, preview_session)).to be_show
    end
  end

  describe "Scope" do
    it "returns all account preview sessions for account admins" do
      create(:user, account: account)
      user = create(:user, :admin, account: account)
      other_preview = create(:preview_session, project: create(:project, account: account))
      outside_preview = create(:preview_session)

      scope = described_class::Scope.new(user, PreviewSession.all).resolve

      expect(scope).to include(preview_session, other_preview)
      expect(scope).not_to include(outside_preview)
    end

    it "returns only project-scoped preview sessions for project members" do
      create(:user, account: account)
      user = create(:user, :viewer, account: account)
      member_project_preview = preview_session
      other_project_preview = create(:preview_session, project: create(:project, account: account))
      user.add_role(:project_member, project)

      scope = described_class::Scope.new(user, PreviewSession.all).resolve

      expect(scope).to include(member_project_preview)
      expect(scope).not_to include(other_project_preview)
    end
  end
end
