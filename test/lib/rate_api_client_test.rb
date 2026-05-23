require "test_helper"

class RateApiClientTest < ActiveSupport::TestCase
  COMBINATIONS = [
    { period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom' }
  ].freeze

  test "get_rates_batch returns raw HTTParty response on success" do
    mock_response = OpenStruct.new(success?: true)
    RateApiClient.stub(:post, mock_response) do
      assert_equal mock_response, RateApiClient.get_rates_batch(COMBINATIONS)
    end
  end

  test "get_rates_batch posts to /pricing" do
    captured_path = nil
    mock_response = OpenStruct.new(success?: true)
    RateApiClient.stub(:post, ->(path, _opts) { captured_path = path; mock_response }) do
      RateApiClient.get_rates_batch(COMBINATIONS)
    end
    assert_equal '/pricing', captured_path
  end

  test "get_rates_batch sends combinations as attributes JSON body" do
    captured_body = nil
    mock_response = OpenStruct.new(success?: true)
    RateApiClient.stub(:post, ->(_path, opts) { captured_body = opts[:body]; mock_response }) do
      RateApiClient.get_rates_batch(COMBINATIONS)
    end
    assert_equal({ 'attributes' => [{ 'period' => 'Summer', 'hotel' => 'FloatingPointResort', 'room' => 'SingletonRoom' }] },
                 JSON.parse(captured_body))
  end

  test "get_rate delegates to get_rates_batch with a single combination" do
    expected = [{ period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom' }]
    mock_response = OpenStruct.new(success?: true)
    RateApiClient.stub(:get_rates_batch, ->(combos) { assert_equal expected, combos; mock_response }) do
      assert_equal mock_response, RateApiClient.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "get_rates_batch raises RateApiError on timeout" do
    RateApiClient.stub(:post, ->(*) { raise Net::ReadTimeout }) do
      error = assert_raises(RateApiError) { RateApiClient.get_rates_batch(COMBINATIONS) }
      assert_match 'timed out', error.message
    end
  end

  test "get_rates_batch raises RateApiError on connection failure" do
    RateApiClient.stub(:post, ->(*) { raise Errno::ECONNREFUSED }) do
      error = assert_raises(RateApiError) { RateApiClient.get_rates_batch(COMBINATIONS) }
      assert_match 'Unable to connect', error.message
    end
  end

  test "get_rates_batch raises RateApiError on HTTParty error" do
    RateApiClient.stub(:post, ->(*) { raise HTTParty::Error, 'downstream failure' }) do
      error = assert_raises(RateApiError) { RateApiClient.get_rates_batch(COMBINATIONS) }
      assert_match 'downstream failure', error.message
    end
  end
end
