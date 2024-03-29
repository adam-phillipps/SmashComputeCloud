require 'dotenv'
# Dotenv.load("/home/ubuntu/crawler/.crawl_bot.env")
Dotenv.load(".scc.env")
require 'aws-sdk'
Aws.use_bundled_cert!
require 'httparty'
require 'syslog/logger'
require 'logger'
require 'json'
require 'byebug'

module Administrator
  def boot_time
    # @boot_time ||= Time.now.to_i # comment the code below for development mode
    @instance_boot_time ||=
      ec2.describe_instances(instance_ids:[self_id]).
        reservations[0].instances[0].launch_time.to_i
  end

  def self_id
    # @self_id ||= 'test-id' # comment the below line for development mode
    @id ||= HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id').parsed_response
  end

  def url
    # @url ||= 'https://test-url.com'
    @url ||= HTTParty.get('http://169.254.169.254/latest/meta-data/hostname').parsed_response
  end

  def identity
    @identity
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

  def sqs
    @sqs ||= Aws::SQS::Client.new(credentials: creds)
  end

  def ec2
    @ec2 ||= Aws::EC2::Client.new(
      region: region,
      credentials: creds
    )
  end

  def kinesis
    @kinesis ||= Aws::Kinesis::Client.new(
      region: region,
      credentials: creds,
    )
  end

  def errors
    $errors ||= { ruby: [], workflow: [] }
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

  def status_address
    @status_address ||= ENV['STATUS_ADDRESS']
  end

  def status_stream_name
    @status_stream_name ||= ENV['STATUS_STREAM_NAME']
  end

  def region
    @region ||= ENV['AWS_REGION']
  end

  def scraper
    Dir["#{File.expand_path(File.dirname(__FILE__))}/**/*.jar"].first
  end

  def jobs_ratio_denominator
    @jobs_ratio_denominator ||= 1 # ENV['RATIO_DENOMINATOR'].to_i
  end

  def get_count(board)
    count = sqs.get_queue_attributes(
      queue_url: board,
      attribute_names: ['ApproximateNumberOfMessages']
    ).attributes['ApproximateNumberOfMessages'].to_f

    message = update_message_body(
     instanceID: self_id,
     url:          url,
     type:        'SitRep',
     content:     'board-count',
     extraInfo:   { board => count }
    )

    update_status_checks(self_id, message)
    count
  end

  def ami_name
    @ami_name ||= ENV['AMI_NAME'] || 'crawlbotprod'
  end

  def log_file
    @log_file ||= ENV['LOG_FILE']
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
    File.open(log_file) do |file|
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
    Thread.kill(@status_thread) unless @status_thread.nil?
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
    message = update_message_body(
      url:          url,
      type:         'status-update',
      content:      'dying',
      extraInfo:    { cause: blame, stack_trace: errors[blame] }
    )

    update_status_checks(self_id, message)
    sqs.send_message(
      queue_url: status_address,
      message_body: message
    )
    sqs.send_message(
      queue_url: needs_attention_address,
      message_body: message
    )
    send_status_to_stream(self_id, message)
    logger.info("The cause for the shutdown is #{blame}")
  end

  def update_status_checks(ids, status)
    ids = ids.kind_of?(Array) ? ids : [ids.to_s]
    for_each_id_send_message_to(
      status_address,
      ids,
      status
    )
  end

  def send_status_to_stream(ids, message)
    ids = ids.kind_of?(Array) ? ids : [ids.to_s]
    it_worked = false

    until it_worked
      begin
        if ids.count == 1
          resp = kinesis.put_record(
            stream_name: status_stream_name,
            data: message,
            partition_key: ids.first.to_s
          )

          unless resp[:sequence_number] && resp[:shard_id]
            send_status_to_stream(ids, message)
          end

          it_worked = true
        elsif ids.count > 1
          resp = kinesis.put_records(
            stream_name: status_stream_name,
            records: ids.map { |id| { data: message, partition_key: id.to_s } }
          )

          if resp.failed_record_count > 0
            logger.info "Failed stream update count: #{resp.failed_record_count}\n" +
              "Error(s):\n#{resp.records.map(&:error_message).join("\n")}"
            failed_resps = resp.records.select { |r| r.body unless r.successful? }
            logger.info "failed to start: #{failed_resps.join("\n")}"
          end

          @last_sequence_number = resp.records.map(&:sequence_number).sort.last

          # TODO:
          # get the ids and send_status_to_stream again

          it_worked = true
        end
        it_worked
      rescue Aws::Kinesis::Errors::ResourceNotFoundException => e
        create_stream
      end
    end
  end

  def create_stream(opts = {})
    begin
      config = {
        stream_name: status_stream_name,
        shard_count: 1
      }.merge(opts)

      @status_stream ||= kinesis.create_stream(config)
      kinesis.wait_until(:stream_exists, stream_name: config[:stream_name])

      logger.info "Created stream named #{config[:stream_name]}"
    rescue Exception => e
      if e.kind_of? Aws::Kinesis::Errors::ResourceInUseException
        logger.info "Stream already created"
      else
        errors[:ruby] << format_error_message(e)
      end
    end
  end

  def status_stream
    @status_stream
  end

  def add_to_working_bots_count(ids)
    for_each_id_send_message_to(
      bot_counter_address,
      ids,
      Time.now
    )
  end

  def send_frequent_status_updates(opts = {})
    sleep_time = opts.delete(:interval) || 5
    while true
      # status = 'Testing' # comment the lines below for development mode
      status = ec2.describe_instances(instance_ids: [self_id]).
        reservations[0].instances[0].state.name
      updated = update_message_body(opts)
      logger.info "Status update: #{updated}"

      send_status_to_stream(self_id, updated)
      update_status_checks(self_id, updated)
      sleep sleep_time
    end
  end

  def stream_message_body(opts = {})
    {
      stream_name:      opts[:stream_name] || status_stream_name,
      data:             opts[:data] || update_message_body(opts),
      partition_key:    opts[:partition_key] || self_id
    }
  end

  def update_message_body(opts = {})
    msg = {
      instanceId:       self_id,
      identity:         identity || 'none-aquired',
      url:              url,
      type:             'status-update',
      content:          'running',
      extraInfo:        {}
    }.merge(opts)
    msg.to_json
  end

  def format_error_message(error)
    begin
      [error.message, error.backtrace.join("\n")].join("\n")
    rescue Exception => e
      error
    end
  end

  def for_each_id_send_message_to(board, ids, message)
    ids.each do |id|

      sqs.send_message(
        queue_url: board,
        message_body: { "#{id}": "#{message}" }.to_json
      )
      # TODO:
      # resend unsuccessful messages
    end
    true
  end

  def creds
    @creds ||= Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'],
      ENV['AWS_SECRET_ACCESS_KEY'])
  end
end
