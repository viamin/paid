# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSessionProject do
  subject(:chat_session_project) { build(:chat_session_project) }

  describe "associations" do
    it { is_expected.to belong_to(:chat_session) }
    it { is_expected.to belong_to(:project) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:context_type).in_array(described_class::CONTEXT_TYPES) }

    it "validates uniqueness of project_id scoped to chat_session_id" do
      create(:chat_session_project)
      expect(chat_session_project).to validate_uniqueness_of(:project_id).scoped_to(:chat_session_id)
    end
  end
end
