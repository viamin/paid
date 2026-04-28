# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatSession do
  subject(:chat_session) { build(:chat_session) }

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:provider).optional }
    it { is_expected.to belong_to(:created_by).class_name("User").optional }
    it { is_expected.to have_many(:messages).class_name("ChatMessage").dependent(:destroy) }
    it { is_expected.to have_many(:chat_session_projects).dependent(:destroy) }
    it { is_expected.to have_many(:projects).through(:chat_session_projects) }
  end

  describe "validations" do
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_inclusion_of(:mode).in_array(described_class::MODES) }

    it "validates uniqueness of external_id" do
      create(:chat_session)
      expect(chat_session).to validate_uniqueness_of(:external_id).case_insensitive
    end

    it "rejects a provider from a different account" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_provider = other_user.providers.first

      session = build(:chat_session, provider: other_provider)
      expect(session).not_to be_valid
      expect(session.errors[:provider]).to include("must belong to the same account")
    end

    it "rejects a project from a different account" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)

      session = build(:chat_session, project: other_project)
      expect(session).not_to be_valid
      expect(session.errors[:project]).to include("must belong to the same account")
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }

    describe ".active" do
      it "returns only active sessions" do
        active = create(:chat_session, account: account, created_by: user)
        create(:chat_session, :closed, account: account, created_by: user)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".idle_expired" do
      it "returns active sessions past their idle timeout" do
        expired = create(:chat_session, account: account, created_by: user, idle_timeout_at: 1.hour.ago)
        create(:chat_session, account: account, created_by: user, idle_timeout_at: 1.hour.from_now)
        create(:chat_session, :closed, account: account, created_by: user, idle_timeout_at: 1.hour.ago)

        expect(described_class.idle_expired).to eq([ expired ])
      end
    end
  end
end
