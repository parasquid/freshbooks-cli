# frozen_string_literal: true

require "rspec/given"
require "webmock/rspec"
require "tmpdir"
require "freshbooks"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.around(:each) do |example|
    Dir.mktmpdir("fb_test_") do |tmpdir|
      FreshBooks::CLI::Auth.data_dir = tmpdir
      example.run
    end
    FreshBooks::CLI::Auth.data_dir = nil
  end

  config.before(:each) do
    allow(FreshBooks::CLI::Spinner).to receive(:spin) do |_msg, &block|
      block.call
    end
  end
end
