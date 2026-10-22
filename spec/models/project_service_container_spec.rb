# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectServiceContainer do
  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:service_container) }
  end

  describe "validations" do
    subject { build(:project_service_container) }

    it { is_expected.to validate_uniqueness_of(:service_container_id).scoped_to(:project_id) }
  end

  describe "readiness re-evaluation" do
    # @spec PROJECT-READINESS-006
    it "queues a readiness evaluation when the association is created" do
      project = create(:project)

      expect { create(:project_service_container, project: project) }
        .to have_enqueued_job(EvaluateProjectReadinessJob).with(project.id)
    end

    it "queues a readiness evaluation when the association is destroyed" do
      association = create(:project_service_container)

      expect { association.destroy }
        .to have_enqueued_job(EvaluateProjectReadinessJob).with(association.project_id)
    end

    it "queues readiness evaluations for both projects when the association moves" do
      service = create(:service_container)
      source = create(:project, account: service.account)
      target = create(:project, account: service.account)
      association = create(:project_service_container, project: source, service_container: service)

      expect { association.update!(project: target) }
        .to have_enqueued_job(EvaluateProjectReadinessJob).with(source.id)
        .and have_enqueued_job(EvaluateProjectReadinessJob).with(target.id)
    end
  end
end
