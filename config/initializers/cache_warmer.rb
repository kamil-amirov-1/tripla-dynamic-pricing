Sidekiq.configure_server do |config|
  config.on(:startup) do
    Sidekiq::Cron::Job.load_from_hash!(
      'cache_warmer' => {
        'cron'  => '*/4 * * * *',
        'class' => 'CacheWarmerWorker'
      }
    )
  end
end
