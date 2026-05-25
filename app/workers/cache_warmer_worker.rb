class CacheWarmerWorker
  include Sidekiq::Job
  sidekiq_options retry: false

  def perform
    Api::V1::RateCacheService.warm_cache
  rescue => e
    Rails.logger.error("event=cache_warmer_error message=#{e.class}:#{e.message}")
    raise
  end
end
