require 'dotenv'
Dotenv.load('.scc.env')
require 'aws-sdk'
require 'date'
require_relative './administrator'

class ComputeController
  include Administrator

  begin
    def initialize
      begin
        logger.info "Begining to poll at #{Time.now}.."
        @status_thread = Thread.new { send_frequent_status_updates(15) }
        poll
      rescue Exception => e
        logger.info "Fatal error durring polling #{Time.now}:\n" +
          "#{[e.message, e.backtrace.join("\n")].join("\n")}"
      end
    end

     def poll
      loop do
        message = {
          instanceId: self_id,
          type: 'status_update',
          content: 'Polling...',
        }.to_json
        send_status_to_stream(self_id, message)
        run_program(adjusted_spawning_ratio)
        sleep 5 # slow the polling
      end
    end

    def adjusted_spawning_ratio
      backlog = get_count(backlog_address)
      wip = get_count(bot_counter_address)

      (((1.0 / jobs_ratio_denominator) * backlog) - wip).ceil
    end

    def run_program(desired_instance_count)
      if desired_instance_count > 0
        logger.info "#{Time.now}\n\tstart #{desired_instance_count} instances"
        max_request_size = 100 # safe maximum number of instances to request at once
        bot_ids = []

        chunks = (desired_instance_count.to_f / max_request_size).floor
        leftover = (desired_instance_count % max_request_size).floor

        begin
          chunks.times { bot_ids.concat(spin_up_instances(max_request_size)) }
          bot_ids.concat(spin_up_instances(leftover))

          logger.info "started #{bot_ids.count} instances:\ninstance ids:\n\t#{bot_ids}"
        rescue Aws::EC2::Errors::DryRunOperation => e
          logger.info e.message
        end
      else
        logger.info "Received 0 requested instance count. starting 0 instances..."
      end
    end

    def spin_up_instances(request_size)
      response = ec2.run_instances(instance_config(request_size))
      ids = response.instances.map(&:instance_id)

      add_to_working_bots_count(ids)
      update_status_checks(ids, 'Starting...')

      ec2.wait_until(:instance_running, instance_ids: ids) do
        logger.info "#{Time.now}\n\twaiting for #{ids.count} instances..."
      end
      ids
    end

    def add_to_working_bots_count(ids)
      ids.each do |id|
        sqs.send_message(
          queue_url: bot_counter_address,
          message_body: { id: id, time: Time.now }.to_json
        )
      end
    end

    def bot_image_tag_filter(tag_name)
      bot_image.tags.find { |t| t.key.include?(tag_name) }.value.split(',')
    end

    def bot_image
      @bot_image ||= ec2.describe_images(
        filters: [{ name: 'tag:aminame', values: [ENV['AMI_NAME']] }]
      ).images.first
    end

    def bot_image_id
      @bot_image_id ||= bot_image.image_id
    end

    def instance_config(desired_instance_count)
      count = desired_instance_count.to_i
      {
        image_id:                 bot_image_id,
        instance_type:            instance_type,
        min_count:                count,
        max_count:                count,
        key_name:                 'crawlBot',
        security_groups:          ['webCrawler'],
        security_group_ids:       ['sg-940edcf2'],
        placement:                { availability_zone: availability_zone },
        disable_api_termination:  'false',
        instance_initiated_shutdown_behavior: 'terminate'
      }
    end

    def creds
      @creds ||= Aws::Credentials.new(
        ENV['AWS_ACCESS_KEY_ID'],
        ENV['AWS_SECRET_ACCESS_KEY'])
    end

    def availability_zone
      @availability_zone ||= ENV['AVAILABILITY_ZONE']
    end

    def instance_type
      @instance_type ||= ENV['INSTANCE_TYPE']
    end
  rescue Exception => e
    msg = [e.message, e.backtrace.join("\n")].join("\n")
    message = {
    instanceId: self_id,
    type: 'status_update',
    content: 'Exploding...',
    extraInfo: msg
   }.to_json
    logger.fatal message
    send_status_to_stream(self_id, msg)
  end
end

ComputeController.new
