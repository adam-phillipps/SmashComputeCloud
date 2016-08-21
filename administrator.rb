require 'aws-sdk'
Aws.use_bundled_cert!
require 'httparty'
require 'syslog/logger'
require 'logger'
require 'byebug'

module Administrator
  def self_id
    @id ||= HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
  end

  def poller(board)
    begin
      eval("#{board}_poller")
    rescue NameError => e
      unless board == ''
        logger.error("There isn't a '#{board}' poller available...\n#{e}")
      end
    end
  end

  def sqs
    @sqs ||= Aws::SQS::Client.new(credentials: creds)
  end

  def ec2
    @ec2 ||= Aws::EC2::Client.new(
      region: region,
      credentials: creds
    )
  end

  def errors
    $errors ||= { ruby: [], scraper: [], workflow: [] }
  end

  def backlog_address
    @backlog_address ||= ENV['BACKLOG_ADDRESS']
  end

  def wip_address
    @wip_address ||= ENV['WIP_ADDRESS']
  end

  def finished_address
    @finished_address ||= ENV['FINISHED_ADDRESS']
  end

  def bot_counter_address
    @bot_counter_address ||= ENV['BOT_COUNTER_ADDRESS']
  end

  def needs_attention_address
    @needs_attention_address ||= ENV['NEEDS_ATTENTION_ADDRESS']
  end

  def region
    @region ||= ENV['AWS_REGION']
  end

  def scraper
    Dir["#{File.expand_path(File.dirname(__FILE__))}/**/*.jar"].first
  end

  def jobs_ratio_denominator
    @jobs_ratio_denominator ||= ENV['RATIO_DENOMINATOR'].to_i
  end

  def get_count(board)
    sqs.get_queue_attributes(
      queue_url: board,
      attribute_names: ['ApproximateNumberOfMessages']
    ).attributes['ApproximateNumberOfMessages'].to_f
  end

  def filename
    @filename ||= ENV['LOG_FILE']
  end

  def logger
    @logger ||= create_logger
  end

  def create_logger
    logger = Logger.new(STDOUT)
    logger.datetime_format = '%Y-%m-%d %H:%M:%S'
    logger
  end

  def format_finished_body(body)
    body.split(' ')[0..25].join(' ') + '...'
  end

  def send_logs_to_s3
    File.open(filename) do |file|
      s3.put_object(
        bucket: log_bucket,
        key: self_id,
        body: file
      )
    end
  end

  def log_bucket
    @log_bucket ||= ENV['LOGS_BUCKET']
  end

  def die!
    notification_of_death

    poller('counter').poll(max_number_of_messages: 1) do |msg|
      poller('counter').delete_message(msg)
      throw :stop_polling
    end

    poller('wip').poll(max_number_of_messages: 1) do |msg|
      poller('wip').delete_message(msg)
      throw :stop_polling
    end

    send_logs_to_s3
    ec2.terminate_instances(ids: [self_id])
  end

  def notification_of_death
    blame = errors.sort_by(&:reverse).last.first
    logger.info("The cause for the shutdown is #{blame}")
  end

  private
  def backlog_poller
    @backlog_poller ||= Aws::SQS::QueuePoller.new(backlog_address)
  end

  def wip_poller
    @wip_poller ||= Aws::SQS::QueuePoller.new(wip_address)
  end

  def finished_poller
    @finished_poller ||= Aws::SQS::QueuePoller.new(finished_address)
  end

  def counter_poller
    @counter_poller ||= Aws::SQS::QueuePoller.new(bot_counter_address)
  end
end
