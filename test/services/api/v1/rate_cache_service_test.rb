require "test_helper"

class Api::V1::RateCacheServiceTest < ActiveSupport::TestCase
  ALL_RATES = Api::V1::RateCacheService::ALL_COMBINATIONS.map do |c|
    { 'period' => c[:period], 'hotel' => c[:hotel], 'room' => c[:room], 'rate' => '10000' }
  end

  def mock_response(rates)
    OpenStruct.new(success?: true, parsed_response: { 'rates' => rates })
  end

  def error_response(message)
    OpenStruct.new(success?: false, parsed_response: { 'error' => message })
  end

  test "returns cached rate without calling the API" do
    Rails.cache.write('pricing:rate:Summer:FloatingPointResort:SingletonRoom', '10000')

    RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
      assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "fetches from API on cache miss and returns the rate" do
    RateApiClient.stub(:get_rates_batch, mock_response(ALL_RATES)) do
      assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "sends all 36 combinations to the API in a single batch call" do
    captured = nil
    RateApiClient.stub(:get_rates_batch, ->(combos) { captured = combos; mock_response(ALL_RATES) }) do
      Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
    assert_equal 36, captured.size
    assert_equal Api::V1::RateCacheService::ALL_COMBINATIONS, captured
  end

  test "API is called only once for multiple requests within the TTL" do
    call_count = 0

    RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(ALL_RATES) }) do
      Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      Api::V1::RateCacheService.get_rate(period: 'Autumn', hotel: 'GitawayHotel', room: 'BooleanTwin')
    end

    assert_equal 1, call_count
  end

  test "cache expires after 5 minutes and API is called again" do
    call_count = 0

    RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(ALL_RATES) }) do
      Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      travel 5.minutes + 1.second do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end

    assert_equal 2, call_count
  end

  test "raises RateApiError with upstream message when API returns an error response" do
    RateApiClient.stub(:get_rates_batch, error_response('upstream error')) do
      error = assert_raises(RateApiError) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
      assert_match 'upstream error', error.message
    end
  end

  test "raises RateApiError when API returns invalid response structure" do
    bad_response = OpenStruct.new(success?: true, parsed_response: { 'unexpected' => true })
    RateApiClient.stub(:get_rates_batch, bad_response) do
      error = assert_raises(RateApiError) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
      assert_match 'Invalid response structure', error.message
    end
  end

  test "returns nil for a combination missing from the API response" do
    partial_rates = ALL_RATES.reject { |r| r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' }

    RateApiClient.stub(:get_rates_batch, mock_response(partial_rates)) do
      assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "other combinations remain available when one is missing from the API response" do
    partial_rates = ALL_RATES.reject { |r| r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' }
    call_count = 0

    RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(partial_rates) }) do
      Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Autumn', hotel: 'GitawayHotel', room: 'BooleanTwin')
    end

    assert_equal 1, call_count
  end

  test "skips and returns nil for a row with a missing rate value" do
    rates_without_rate = ALL_RATES.map do |r|
      r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' ? r.except('rate') : r
    end

    RateApiClient.stub(:get_rates_batch, mock_response(rates_without_rate)) do
      assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end
end
