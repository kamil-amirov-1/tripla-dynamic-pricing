require "test_helper"

class Api::V1::RateCacheServiceTest < ActiveSupport::TestCase
  ALL_RATES = PricingCatalog::ALL_COMBINATIONS.map do |c|
    { 'period' => c[:period], 'hotel' => c[:hotel], 'room' => c[:room], 'rate' => '10000' }
  end

  def mock_response(rates)
    OpenStruct.new(success?: true, parsed_response: { 'rates' => rates })
  end

  def error_response(message)
    OpenStruct.new(success?: false, parsed_response: { 'error' => message })
  end

  # Stubs lock acquire/release so tests don't need a live Redis connection.
  # Lock correctness is an infrastructure concern tested separately; these
  # tests verify caching and API behavior.
  def with_lock
    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { true }) do
      Api::V1::RateCacheService.stub(:release_lock, ->(_) { nil }) do
        yield
      end
    end
  end

  test "warm_cache fetches all combinations and populates the cache" do
    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(ALL_RATES)) do
        Api::V1::RateCacheService.warm_cache
        assert_equal '10000', Rails.cache.read('pricing:rate:Summer:FloatingPointResort:SingletonRoom')
      end
    end
  end

  test "warm_cache is a no-op when another process holds the lock" do
    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { false }) do
      RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
        Api::V1::RateCacheService.warm_cache
      end
    end
  end

  test "returns cached rate without calling the API" do
    Rails.cache.write('pricing:rate:Summer:FloatingPointResort:SingletonRoom', '10000')

    RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
      assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "fetches from API on cache miss and returns the rate" do
    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(ALL_RATES)) do
        assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
  end

  test "sends all 36 combinations to the API in a single batch call" do
    captured = nil
    with_lock do
      RateApiClient.stub(:get_rates_batch, ->(combos) { captured = combos; mock_response(ALL_RATES) }) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
    assert_equal 36, captured.size
    assert_equal PricingCatalog::ALL_COMBINATIONS, captured
  end

  test "API is called only once for multiple requests within the TTL" do
    call_count = 0

    with_lock do
      RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(ALL_RATES) }) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        Api::V1::RateCacheService.get_rate(period: 'Autumn', hotel: 'GitawayHotel', room: 'BooleanTwin')
      end
    end

    assert_equal 1, call_count
  end

  test "cache expires after 5 minutes and API is called again" do
    call_count = 0

    with_lock do
      RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(ALL_RATES) }) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        travel 5.minutes + 1.second do
          Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
      end
    end

    assert_equal 2, call_count
  end

  test "raises RateApiError with upstream message when API returns an error response" do
    with_lock do
      RateApiClient.stub(:get_rates_batch, error_response('upstream error')) do
        error = assert_raises(RateApiError) do
          Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
        assert_match 'upstream error', error.message
      end
    end
  end

  test "raises RateApiError when API returns invalid response structure" do
    bad_response = OpenStruct.new(success?: true, parsed_response: { 'unexpected' => true })
    with_lock do
      RateApiClient.stub(:get_rates_batch, bad_response) do
        error = assert_raises(RateApiError) do
          Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
        assert_match 'Invalid response structure', error.message
      end
    end
  end

  test "returns nil for a combination missing from the API response" do
    partial_rates = ALL_RATES.reject { |r| r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' }

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(partial_rates)) do
        assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
  end

  test "other combinations remain available when one is missing from the API response" do
    partial_rates = ALL_RATES.reject { |r| r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' }
    call_count = 0

    with_lock do
      RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; mock_response(partial_rates) }) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Autumn', hotel: 'GitawayHotel', room: 'BooleanTwin')
      end
    end

    assert_equal 1, call_count
  end

  test "skips and returns nil for a row with a missing rate value" do
    rates_without_rate = ALL_RATES.map do |r|
      r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' ? r.except('rate') : r
    end

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(rates_without_rate)) do
        assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
  end

  test "skips and returns nil for a row with a blank rate value" do
    rates_with_blank_rate = ALL_RATES.map do |r|
      r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' ? r.merge('rate' => '') : r
    end

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(rates_with_blank_rate)) do
        assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
  end

  test "skips and returns nil for a row with a negative rate value" do
    rates_with_negative_rate = ALL_RATES.map do |r|
      r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' ? r.merge('rate' => '-1000') : r
    end

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(rates_with_negative_rate)) do
        assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end
  end

  test "waiter does not call the API when another process holds the refresh lock" do
    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { false }) do
      Api::V1::RateCacheService.stub(:wait_for_lock_release, -> {
        # Simulate the lock holder writing the rate to cache before releasing
        Rails.cache.write('pricing:rate:Summer:FloatingPointResort:SingletonRoom', '10000')
      }) do
        RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
          assert_equal '10000', Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
      end
    end
  end

  test "raises RateApiError when lock releases but neither rate nor missing key is written" do
    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { false }) do
      Api::V1::RateCacheService.stub(:wait_for_lock_release, -> { nil }) do
        error = assert_raises(RateApiError) do
          Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
        assert_match 'temporarily unavailable', error.message
      end
    end
  end

  test "returns nil without calling the API when combination is cached as missing" do
    partial_rates = ALL_RATES.reject { |r| r['period'] == 'Summer' && r['hotel'] == 'FloatingPointResort' && r['room'] == 'SingletonRoom' }

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(partial_rates)) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end

    RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
      assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
    end
  end

  test "waiter returns nil when lock holder marks combination as missing" do
    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { false }) do
      Api::V1::RateCacheService.stub(:wait_for_lock_release, -> {
        Rails.cache.write('pricing:rate:Summer:FloatingPointResort:SingletonRoom', Api::V1::RateCacheService::MISSING)
      }) do
        RateApiClient.stub(:get_rates_batch, ->(_) { flunk 'API should not be called' }) do
          assert_nil Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
        end
      end
    end
  end

  test "raises RateApiError when cache read fails" do
    Rails.cache.stub(:read, ->(_) { raise RuntimeError, 'Redis connection failed' }) do
      error = assert_raises(RateApiError) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
      assert_match 'Pricing cache unavailable', error.message
    end
  end

  test "raises RateApiError when cache write fails" do
    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(ALL_RATES)) do
        Rails.cache.stub(:write, ->(*) { false }) do
          error = assert_raises(RateApiError) do
            Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
          end
          assert_match 'Pricing cache unavailable', error.message
        end
      end
    end
  end

  test "does not cache rows for unknown combinations returned by the API" do
    rogue_rate = { 'period' => 'Summer', 'hotel' => 'UnknownHotel', 'room' => 'SingletonRoom', 'rate' => '99999' }

    with_lock do
      RateApiClient.stub(:get_rates_batch, mock_response(ALL_RATES + [rogue_rate])) do
        Api::V1::RateCacheService.get_rate(period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom')
      end
    end

    assert_nil Rails.cache.read('pricing:rate:Summer:UnknownHotel:SingletonRoom')
  end
end
