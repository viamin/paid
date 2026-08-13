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
end
