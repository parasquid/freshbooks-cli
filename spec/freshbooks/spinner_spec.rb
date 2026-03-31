# frozen_string_literal: true

RSpec.describe FreshBooks::CLI::Spinner do
  describe ".spin" do
    before do
      # Remove the global stub so we test the real Spinner
      allow(FreshBooks::CLI::Spinner).to receive(:spin).and_call_original
    end

    it "returns the block result" do
      result = capture_stdout_spinner { FreshBooks::CLI::Spinner.spin("testing") { 42 } }
      expect(result).to eq(42)
    end

    it "returns complex block results" do
      result = capture_stdout_spinner { FreshBooks::CLI::Spinner.spin("loading") { { key: "value" } } }
      expect(result).to eq({ key: "value" })
    end
  end
end

def capture_stdout_spinner
  original = $stdout
  $stdout = StringIO.new
  yield
ensure
  $stdout = original
end
