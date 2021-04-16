require "spec_helper"

RSpec.describe Sentry::Transaction do
  before do
    perform_basic_setup
  end

  subject do
    described_class.new(
      op: "sql.query",
      description: "SELECT * FROM users;",
      status: "ok",
      sampled: true,
      parent_sampled: true,
      name: "foo",
      hub: Sentry.get_current_hub
    )
  end

  describe ".from_sentry_trace" do
    let(:sentry_trace) { subject.to_sentry_trace }

    let(:configuration) do
      Sentry.configuration
    end

    context "when tracing is enabled" do
      before do
        configuration.traces_sample_rate = 1.0
      end

      it "returns correctly-formatted value" do
        child_transaction = described_class.from_sentry_trace(sentry_trace, op: "child")

        expect(child_transaction.trace_id).to eq(subject.trace_id)
        expect(child_transaction.parent_span_id).to eq(subject.span_id)
        expect(child_transaction.parent_sampled).to eq(true)
        # doesn't set the sampled value
        expect(child_transaction.sampled).to eq(nil)
        expect(child_transaction.op).to eq("child")
      end

      it "handles invalid values without crashing" do
        child_transaction = described_class.from_sentry_trace("dummy", op: "child")

        expect(child_transaction).to be_nil
      end
    end

    context "when tracing is disabled" do
      before do
        configuration.traces_sample_rate = 0.0
      end

      it "returns nil" do
        expect(described_class.from_sentry_trace(sentry_trace, op: "child")).to be_nil
      end
    end
  end

  describe "#deep_dup" do
    before do
      subject.start_child(op: "first child")
      subject.start_child(op: "second child")
    end

    it "copies all the values and spans from the original transaction" do
      copy = subject.deep_dup

      subject.set_op("foo")
      subject.set_description("bar")

      # the copy should have the same attributes, including span_id
      expect(copy.op).to eq("sql.query")
      expect(copy.description).to eq("SELECT * FROM users;")
      expect(copy.status).to eq("ok")
      expect(copy.trace_id).to eq(subject.trace_id)
      expect(copy.trace_id.length).to eq(32)
      expect(copy.span_id).to eq(subject.span_id)
      expect(copy.span_id.length).to eq(16)

      # child spans should also be copied
      expect(copy.span_recorder.spans.count).to eq(3)

      # but span recorder should have the correct first span (shouldn't be the subject)
      expect(copy.span_recorder.spans.first).to eq(copy)

      # child spans should have identical attributes
      expect(subject.span_recorder.spans[1].op).to eq("first child")
      expect(copy.span_recorder.spans[1].op).to eq("first child")
      expect(copy.span_recorder.spans[1].span_id).to eq(subject.span_recorder.spans[1].span_id)

      expect(subject.span_recorder.spans[2].op).to eq("second child")
      expect(copy.span_recorder.spans[2].op).to eq("second child")
      expect(copy.span_recorder.spans[2].span_id).to eq(subject.span_recorder.spans[2].span_id)

      # but they should not be the same
      expect(copy.span_recorder.spans[1]).not_to eq(subject.span_recorder.spans[1])
      expect(copy.span_recorder.spans[2]).not_to eq(subject.span_recorder.spans[2])

      # and mutations shouldn't be shared
      subject.span_recorder.spans[1].set_op("foo")
      expect(copy.span_recorder.spans[1].op).to eq("first child")
    end
  end

  describe "#start_child" do
    it "initializes a new child Span and assigns the 'transaction' attribute with itself" do
      # create subject span and wait for a sec for making time difference
      subject

      new_span = subject.start_child(op: "sql.query", description: "SELECT * FROM orders WHERE orders.user_id = 1", status: "ok")

      expect(new_span.op).to eq("sql.query")
      expect(new_span.description).to eq("SELECT * FROM orders WHERE orders.user_id = 1")
      expect(new_span.status).to eq("ok")
      expect(new_span.trace_id).to eq(subject.trace_id)
      expect(new_span.span_id).not_to eq(subject.span_id)
      expect(new_span.parent_span_id).to eq(subject.span_id)
      expect(new_span.sampled).to eq(true)

      expect(new_span.transaction).to eq(subject)
    end
  end

  describe "#set_initial_sample_decision" do
    let(:string_io) { StringIO.new }
    let(:logger) do
      ::Logger.new(string_io)
    end

    before do
      perform_basic_setup do |config|
        config.logger = logger
      end
    end

    context "when tracing is not enabled" do
      before do
        allow(Sentry.configuration).to receive(:tracing_enabled?).and_return(false)
      end

      it "sets @sampled to false and return" do
        allow(Sentry.configuration).to receive(:tracing_enabled?).and_return(false)

        transaction = described_class.new(sampled: true, hub: Sentry.get_current_hub)
        transaction.set_initial_sample_decision(sampling_context: {})
        expect(transaction.sampled).to eq(false)
      end
    end

    context "when tracing is enabled" do
      let(:subject) { described_class.new(op: "rack.request", hub: Sentry.get_current_hub) }

      before do
        allow(Sentry.configuration).to receive(:tracing_enabled?).and_return(true)
      end

      context "when the transaction already has a decision" do
        it "doesn't change it" do
          transaction = described_class.new(sampled: true, hub: Sentry.get_current_hub)
          transaction.set_initial_sample_decision(sampling_context: {})
          expect(transaction.sampled).to eq(true)

          transaction = described_class.new(sampled: false, hub: Sentry.get_current_hub)
          transaction.set_initial_sample_decision(sampling_context: {})
          expect(transaction.sampled).to eq(false)
        end
      end

      context "when traces_sampler is not set" do
        before do
          Sentry.configuration.traces_sample_rate = 0.5
        end

        it "prioritizes inherited decision over traces_sample_rate" do
          allow(Random).to receive(:rand).and_return(0.4)

          subject.set_initial_sample_decision(sampling_context: { parent_sampled: false })
          expect(subject.sampled).to eq(false)
        end

        it "uses traces_sample_rate for sampling (positive result)" do
          allow(Random).to receive(:rand).and_return(0.4)

          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(true)
          expect(string_io.string).to include(
            "[Tracing] Starting <rack.request> transaction"
          )
        end

        it "uses traces_sample_rate for sampling (negative result)" do
          allow(Random).to receive(:rand).and_return(0.6)

          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(false)
          expect(string_io.string).to include(
            "[Tracing] Discarding <rack.request> transaction because it's not included in the random sample (sampling rate = 0.5)"
          )
        end

        it "accepts integer traces_sample_rate" do
          Sentry.configuration.traces_sample_rate = 1

          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(true)
        end
      end

      context "when traces_sampler is provided" do
        it "prioritizes traces_sampler over traces_sample_rate" do
          Sentry.configuration.traces_sample_rate = 1.0
          Sentry.configuration.traces_sampler = -> (_) { false }

          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(false)
        end

        it "prioritizes traces_sampler over inherited decision" do
          Sentry.configuration.traces_sampler = -> (_) { false }

          subject.set_initial_sample_decision(sampling_context: { parent_sampled: true })
          expect(subject.sampled).to eq(false)
        end

        it "ignores the sampler if it's not callable" do
          Sentry.configuration.traces_sampler = ""

          expect do
            subject.set_initial_sample_decision(sampling_context: {})
          end.not_to raise_error
        end

        it "discards the transaction if generated sample rate is not valid" do
          Sentry.configuration.traces_sampler = -> (_) { "foo" }
          subject.set_initial_sample_decision(sampling_context: {})

          expect(subject.sampled).to eq(false)

          expect(string_io.string).to include(
            "[Tracing] Discarding <rack.request> transaction because of invalid sample_rate: foo"
          )
        end

        it "uses the genereted rate for sampling (positive)" do
          expect(Sentry.configuration.logger).to receive(:debug).exactly(3).and_call_original

          subject = described_class.new(hub: Sentry.get_current_hub)
          Sentry.configuration.traces_sampler = -> (_) { true }
          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(true)

          subject = described_class.new(hub: Sentry.get_current_hub)
          Sentry.configuration.traces_sampler = -> (_) { 1.0 }
          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(true)

          subject = described_class.new(hub: Sentry.get_current_hub)
          Sentry.configuration.traces_sampler = -> (_) { 1 }
          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(true)

          expect(string_io.string).to include(
            "[Tracing] Starting transaction"
          )
        end

        it "uses the genereted rate for sampling (negative)" do
          expect(Sentry.configuration.logger).to receive(:debug).exactly(2).and_call_original

          subject = described_class.new(hub: Sentry.get_current_hub)
          Sentry.configuration.traces_sampler = -> (_) { false }
          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(false)

          subject = described_class.new(hub: Sentry.get_current_hub)
          Sentry.configuration.traces_sampler = -> (_) { 0.0 }
          subject.set_initial_sample_decision(sampling_context: {})
          expect(subject.sampled).to eq(false)

          expect(string_io.string).to include(
            "[Tracing] Discarding transaction because traces_sampler returned 0 or false"
          )
        end
      end
    end
  end

  describe "#to_hash" do
    it "returns correct data" do
      hash = subject.to_hash

      expect(hash[:op]).to eq("sql.query")
      expect(hash[:description]).to eq("SELECT * FROM users;")
      expect(hash[:status]).to eq("ok")
      expect(hash[:trace_id].length).to eq(32)
      expect(hash[:span_id].length).to eq(16)
      expect(hash[:sampled]).to eq(true)
      expect(hash[:parent_sampled]).to eq(true)
      expect(hash[:name]).to eq("foo")
    end
  end

  describe "#finish" do
    let(:events) do
      Sentry.get_current_client.transport.events
    end

    let(:another_hub) do
      Sentry.get_current_hub.clone
    end

    it "finishes the transaction, converts it into an Event and send it" do
      subject.finish

      expect(events.count).to eq(1)
      event = events.last.to_hash

      # don't contain itself
      expect(event[:spans]).to be_empty
    end

    describe "hub selection" do
      it "prioritizes the optional hub argument and uses it to submit the transaction" do
        expect(another_hub).to receive(:capture_event)

        subject.finish(hub: another_hub)
      end

      it "submits the event with the transaction's hub by default" do
        subject.instance_variable_set(:@hub, another_hub)

        expect(another_hub).to receive(:capture_event)

        subject.finish
      end
    end

    context "if the transaction is not sampled" do
      subject { described_class.new(sampled: false, hub: Sentry.get_current_hub) }

      it "doesn't send it" do
        subject.finish

        expect(events.count).to eq(0)
      end
    end

    context "if the transaction doesn't have a name" do
      subject { described_class.new(sampled: true, hub: Sentry.get_current_hub) }

      it "adds a default name" do
        subject.finish

        expect(subject.name).to eq("<unlabeled transaction>")
      end
    end
  end
end
