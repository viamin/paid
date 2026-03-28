# frozen_string_literal: true

require "rails_helper"

RSpec.describe ScopeAnalysis::Analyze, :no_db do
  describe ".call" do
    subject(:result) { described_class.call(text: text) }

    context "with a simple bug report" do
      let(:text) do
        "The login button does not respond when clicked on mobile devices. " \
          "Expected: clicking the button should submit the form."
      end

      it "does not flag for decomposition" do
        expect(result.should_decompose?).to be false
      end

      it "returns low confidence" do
        expect(result.confidence).to be < 0.5
      end

      it "returns few sub-components" do
        expect(result.sub_components.size).to be <= 2
      end
    end

    context "with a small feature request" do
      let(:text) do
        "Add a tooltip to the settings page that explains the notification preferences."
      end

      it "does not flag for decomposition" do
        expect(result.should_decompose?).to be false
      end

      it "returns low confidence" do
        expect(result.confidence).to be < 0.3
      end
    end

    context "with a large multi-component feature" do
      let(:text) do
        <<~TEXT
          ## Feature: User Notification System

          Redesign the notification system to support multiple channels.

          ### Requirements

          1. Create a Notification model with polymorphic associations
          2. Add a NotificationsController with CRUD endpoints
          3. Build notification preference views for the user dashboard
          4. Create a NotificationService to handle delivery logic
          5. Write a migration to add the notifications table with proper indexes
          6. Add background jobs to process notification queues asynchronously
          7. Implement email notifications via ActionMailer
          8. Add API endpoints for mobile clients
          9. Update authentication to scope notifications per user
          10. Add comprehensive tests for all components

          ### Technical Notes

          This touches authentication, authorization, background jobs, the API layer,
          the UI dashboard, and the database schema. We need to refactor the existing
          user preferences to accommodate notification settings.
        TEXT
      end

      it "flags for decomposition" do
        expect(result.should_decompose?).to be true
      end

      it "returns high confidence" do
        expect(result.confidence).to be >= 0.7
      end

      it "extracts relevant sub-components" do
        expect(result.sub_components).to include("authentication")
        expect(result.sub_components).to include("authorization")
        expect(result.sub_components).to include("background jobs")
        expect(result.sub_components).to include("api endpoints")
        expect(result.sub_components).to include("database")
      end
    end

    context "with cross-cutting concerns" do
      let(:text) do
        <<~TEXT
          Add role-based access control across the application.

          1. Create a Role model and a migration for the roles and permissions tables
          2. Add authentication middleware for OAuth login
          3. Implement authorization checks in the controllers and services
          4. Update the dashboard views for permission-based UI rendering
          5. Add API endpoint protection with role validation
          6. Cache role lookups for performance
          7. Add tests for the authorization flow
        TEXT
      end

      it "flags for decomposition" do
        expect(result.should_decompose?).to be true
      end

      it "identifies cross-cutting concerns" do
        expect(result.sub_components).to include("authentication")
        expect(result.sub_components).to include("authorization")
        expect(result.sub_components).to include("api endpoints")
        expect(result.sub_components).to include("caching")
      end
    end

    context "with sequential phases" do
      let(:text) do
        <<~TEXT
          First, migrate the existing data to the new schema. Then update the
          models and controllers to use the new structure. After that, update
          the views. Finally, add integration tests to verify everything works.
        TEXT
      end

      it "detects phase signals" do
        expect(result.confidence).to be > 0.3
      end
    end

    context "with complexity markers" do
      let(:text) do
        <<~TEXT
          Redesign and refactor the payment processing module. This requires a
          migration of all existing payment records and an overhaul of the
          billing controller, service layer, and associated views.

          1. Restructure the payment model and write a data migration
          2. Refactor the billing controller and update the routes
          3. Update the service objects for the new payment flow
          4. Redesign the billing views
          5. Add comprehensive tests for the restructured code
        TEXT
      end

      it "flags for decomposition" do
        expect(result.should_decompose?).to be true
      end

      it "returns moderate-to-high confidence" do
        expect(result.confidence).to be >= 0.5
      end
    end

    context "with an empty string" do
      let(:text) { "" }

      it "does not flag for decomposition" do
        expect(result.should_decompose?).to be false
      end

      it "returns zero confidence" do
        expect(result.confidence).to eq(0.0)
      end

      it "returns no sub-components" do
        expect(result.sub_components).to be_empty
      end
    end

    context "with nil text" do
      let(:text) { nil }

      it "does not flag for decomposition" do
        expect(result.should_decompose?).to be false
      end

      it "returns zero confidence" do
        expect(result.confidence).to eq(0.0)
      end
    end

    context "with a configurable threshold" do
      let(:text) do
        "Add a new model with a migration and update the controller."
      end

      it "decomposes at a low threshold" do
        result = described_class.call(text: text, threshold: 0.1)
        expect(result.should_decompose?).to be true
      end

      it "does not decompose at a high threshold" do
        result = described_class.call(text: text, threshold: 0.9)
        expect(result.should_decompose?).to be false
      end

      it "accepts a string threshold" do
        result = described_class.call(text: text, threshold: "0.1")
        expect(result.should_decompose?).to be true
      end

      it "clamps threshold above 1.0 to 1.0" do
        result = described_class.call(text: text, threshold: 2.0)
        expect(result.should_decompose?).to be false
      end

      it "clamps threshold below 0.0 to 0.0" do
        result = described_class.call(text: text, threshold: -1.0)
        expect(result.should_decompose?).to be true
      end

      it "raises ArgumentError for non-numeric threshold" do
        expect { described_class.call(text: text, threshold: "abc") }
          .to raise_error(ArgumentError, /threshold must be numeric/)
      end

      it "raises ArgumentError for nil threshold" do
        expect { described_class.call(text: text, threshold: nil) }
          .to raise_error(ArgumentError, /threshold must be numeric/)
      end
    end
  end

  describe ScopeAnalysis::Analyze::Result do
    it "is immutable" do
      result = described_class.new(
        should_decompose: true,
        confidence: 0.75,
        sub_components: [ "auth", "UI" ]
      )

      expect(result.sub_components).to be_frozen
    end

    it "exposes all attributes" do
      result = described_class.new(
        should_decompose: true,
        confidence: 0.85,
        sub_components: [ "database" ]
      )

      expect(result.should_decompose?).to be true
      expect(result.confidence).to eq(0.85)
      expect(result.sub_components).to eq([ "database" ])
    end
  end
end
