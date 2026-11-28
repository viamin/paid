# frozen_string_literal: true

require "rails_helper"

RSpec.describe MainCiState do
  # @spec MAIN-CI-007
  it "isolates rows and rejects a recovery run from another project at the database boundary" do
    project = create(:project)
    other_project = create(:project)
    foreign_run = create(:agent_run, project: other_project)
    state = described_class.create!(project: project, account: project.account)
    TenantContext.with(other_project.account) do
      expect(described_class.find_by(id: state.id)).to be_nil
    end
    TenantContext.with(project.account) do
      expect do
        state.update_columns(repair_run_id: foreign_run.id)
      end.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
    end
  end

  # @spec MAIN-CI-007
  it "removes recovery state when its owning project is deleted" do
    project = create(:project)
    state = described_class.create!(project: project, account: project.account)
    expect { project.destroy! }.to change { described_class.exists?(state.id) }.from(true).to(false)
  end
end
