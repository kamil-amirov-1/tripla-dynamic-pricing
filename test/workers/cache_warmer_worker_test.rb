require "test_helper"

class CacheWarmerWorkerTest < ActiveSupport::TestCase
  test "calls warm_cache on perform" do
    called = false
    Api::V1::RateCacheService.stub(:warm_cache, -> { called = true }) do
      CacheWarmerWorker.new.perform
    end
    assert called
  end

  test "re-raises and logs when warm_cache fails" do
    Api::V1::RateCacheService.stub(:warm_cache, -> { raise RateApiError, 'upstream error' }) do
      assert_raises(RateApiError) do
        CacheWarmerWorker.new.perform
      end
    end
  end
end
