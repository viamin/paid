# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectPolicy do
  subject { described_class }

  describe "permissions" do
    describe "#index?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account, created_by: owner)

        expect(described_class.new(owner, project)).to be_index
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).to be_index
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).to be_index
      end

      it "permits viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).to be_index
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_index
      end
    end

    describe "#show?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account)

        expect(described_class.new(owner, project)).to be_show
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).to be_show
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).to be_show
      end

      it "permits viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).to be_show
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_show
      end
    end

    describe "#create?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account)

        expect(described_class.new(owner, project)).to be_create
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).to be_create
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).not_to be_create
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).not_to be_create
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_create
      end
    end

    describe "#update?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account)

        expect(described_class.new(owner, project)).to be_update
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).to be_update
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).not_to be_update
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).not_to be_update
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_update
      end
    end

    describe "#destroy?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account)

        expect(described_class.new(owner, project)).to be_destroy
      end

      it "does not permit admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).not_to be_destroy
      end

      it "does not permit member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).not_to be_destroy
      end

      it "does not permit viewer" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).not_to be_destroy
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_destroy
      end
    end

    describe "#run_agent?" do
      it "permits owner" do
        account = create(:account)
        owner = create(:user, account: account)
        project = create(:project, account: account)

        expect(described_class.new(owner, project)).to be_run_agent
      end

      it "permits admin" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        admin = create(:user, :admin, account: account)
        project = create(:project, account: account)

        expect(described_class.new(admin, project)).to be_run_agent
      end

      it "permits member" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        member = create(:user, :member, account: account)
        project = create(:project, account: account)

        expect(described_class.new(member, project)).to be_run_agent
      end

      it "does not permit viewer without project role" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)

        expect(described_class.new(viewer, project)).not_to be_run_agent
      end

      it "permits viewer with project admin role" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)
        viewer.add_role(:admin, project)

        expect(described_class.new(viewer, project)).to be_run_agent
      end

      it "permits viewer with project member role" do
        account = create(:account)
        create(:user, account: account) # absorb owner role
        viewer = create(:user, :viewer, account: account)
        project = create(:project, account: account)
        viewer.add_role(:member, project)

        expect(described_class.new(viewer, project)).to be_run_agent
      end

      it "does not permit users from different account" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)

        expect(described_class.new(other_user, project)).not_to be_run_agent
      end

      it "does not permit users from different account even with project role" do
        account = create(:account)
        create(:user, account: account)
        project = create(:project, account: account)
        other_account = create(:account)
        other_user = create(:user, account: other_account)
        other_user.add_role(:member, project)

        expect(described_class.new(other_user, project)).not_to be_run_agent
      end
    end
  end

  describe "Scope" do
    it "returns projects for the user's account" do
      account = create(:account)
      owner = create(:user, account: account)
      project_in_account = create(:project, account: account)
      other_account = create(:account)
      create(:user, account: other_account)
      project_in_other_account = create(:project, account: other_account)

      scope = described_class::Scope.new(owner, Project).resolve

      expect(scope).to include(project_in_account)
      expect(scope).not_to include(project_in_other_account)
    end

    it "raises error when user is not logged in" do
      expect {
        described_class::Scope.new(nil, Project).resolve
      }.to raise_error(Pundit::NotAuthorizedError, "must be logged in")
    end
  end
end
