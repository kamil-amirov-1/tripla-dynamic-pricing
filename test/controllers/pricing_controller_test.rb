require "test_helper"

class Api::V1::PricingControllerTest < ActionDispatch::IntegrationTest
  test "should get pricing with all parameters" do
    Api::V1::RateCacheService.stub(:get_rate, '15000') do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_equal "15000", json_response["rate"]
    end
  end

  test "should return 404 when rate is not found" do
    Api::V1::RateCacheService.stub(:get_rate, nil) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :not_found
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "Rate not found"
    end
  end

  test "should return 503 when rate API fails" do
    Api::V1::RateCacheService.stub(:get_rate, ->(**) { raise RateApiError, 'upstream error' }) do
      get api_v1_pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :service_unavailable
      assert_equal "application/json", @response.media_type

      json_response = JSON.parse(@response.body)
      assert_includes json_response["error"], "upstream error"
    end
  end

  test "should return error without any parameters" do
    get api_v1_pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get api_v1_pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get api_v1_pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get api_v1_pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
  end

  test "upstream is called once and result is served from cache on second request" do
    call_count = 0
    all_rates = PricingCatalog::ALL_COMBINATIONS.map do |c|
      { 'period' => c[:period], 'hotel' => c[:hotel], 'room' => c[:room], 'rate' => '10000' }
    end
    batch_response = OpenStruct.new(success?: true, parsed_response: { 'rates' => all_rates })

    Api::V1::RateCacheService.stub(:acquire_lock, ->(_) { true }) do
      Api::V1::RateCacheService.stub(:release_lock, ->(_) { nil }) do
        RateApiClient.stub(:get_rates_batch, ->(_) { call_count += 1; batch_response }) do
          get api_v1_pricing_url, params: { period: 'Summer', hotel: 'FloatingPointResort', room: 'SingletonRoom' }
          assert_response :success
          assert_equal '10000', JSON.parse(@response.body)['rate']

          get api_v1_pricing_url, params: { period: 'Autumn', hotel: 'GitawayHotel', room: 'BooleanTwin' }
          assert_response :success
          assert_equal '10000', JSON.parse(@response.body)['rate']
        end
      end
    end

    assert_equal 1, call_count
  end
end
