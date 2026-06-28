# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaidAgentHarnessAnthropicRefreshTokenReusedPatch do
  let(:base_patterns) do
    {
      auth_expired: [ /oauth.*token.*expired/i, /unauthorized/i ],
      quota_exceeded: [ /quota.*exceeded/i ]
    }
  end

  let(:base_class) do
    patterns = base_patterns
    Class.new do
      define_method(:error_classification_patterns) { patterns }
    end
  end

  let(:patched_class) do
    Class.new(base_class).tap do |klass|
      klass.prepend(described_class)
    end
  end

  let(:provider) { patched_class.new }

  describe "#error_classification_patterns" do
    it "adds refresh_token_reused to the auth_expired patterns" do
      patterns = provider.error_classification_patterns
      auth_patterns = patterns[:auth_expired]

      expect(auth_patterns).to include(/refresh_token_reused/i)
    end

    it "preserves upstream auth_expired patterns" do
      patterns = provider.error_classification_patterns
      auth_patterns = patterns[:auth_expired]

      expect(auth_patterns).to include(/oauth.*token.*expired/i)
      expect(auth_patterns).to include(/unauthorized/i)
    end

    it "does not alter non-auth_expired categories" do
      patterns = provider.error_classification_patterns
      expect(patterns[:quota_exceeded]).to eq(base_patterns[:quota_exceeded])
    end

    it "classifies refresh_token_reused as auth_expired" do
      auth_patterns = provider.error_classification_patterns[:auth_expired]
      expect(auth_patterns.any? { |p| "refresh_token_reused".match?(p) }).to be true
    end

    it "classifies REFRESH_TOKEN_REUSED (uppercase) as auth_expired" do
      auth_patterns = provider.error_classification_patterns[:auth_expired]
      expect(auth_patterns.any? { |p| "REFRESH_TOKEN_REUSED".match?(p) }).to be true
    end
  end

  describe "idempotent prepend guard" do
    it "is not applied twice to the same class" do
      klass = Class.new(base_class).tap do |k|
        k.prepend(described_class)
        k.prepend(described_class)
      end
      instance = klass.new
      auth_patterns = instance.error_classification_patterns[:auth_expired]
      refresh_patterns = auth_patterns.select { |p| p.inspect.include?("refresh_token_reused") }

      expect(refresh_patterns.length).to eq(1)
    end
  end
end
