require 'dotenv'
Dotenv.load('.bot_maker.env')
require 'aws-sdk'
require 'date'
require_relative 'administrator'

class ComputeController
  include Administrator
  begin
    def initialize
      begin
        puts "Begining to poll at #{Time.now}.."
        poll
      rescue Exception => e
        puts "Fatal error durring polling #{Time.now}:\n#{e}"
      end
    end

     def poll
      loop do
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
        puts "#{Time.now}\n\tstart #{desired_instance_count} instances"
        max_request_size = 100 # safe maximum number of instances to request at once
        bot_ids = []

        chunks = (desired_instance_count.to_f / max_request_size).floor
        leftover = (desired_instance_count % max_request_size).floor
        begin
          chunks.times { bot_ids.concat(spin_up_instances(max_request_size)) }
          bot_ids.concat(spin_up_instances(leftover))

          puts "started #{bot_ids.count} instances:\ninstance ids:\n\t#{bot_ids}"
        rescue Aws::EC2::Errors::DryRunOperation => e
          puts e
        end
      else
        puts "#{Time.now}\n\treceived 0 requested instance count. starting 0 instances..."
      end
    end

    def spin_up_instances(request_size)
      response = ec2.run_instances(instance_config(request_size))
      ids = response.instances.map(&:instance_id)

      add_to_working_bots_count(ids)

      ec2.wait_until(:instance_running, instance_ids: ids) do
        puts "#{Time.now}\n\twaiting for #{ids.count} instances..."
      end

      ec2.create_tags(
        resources: ids,
        tags: [{
            key: 'Name',
            values: 'crawlBot-started'
          }, {
            key: 'AMI Name',
            values: "crawlBot_#{Time.now.to_i}"
          }
        ]
      )
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
  rescue => e
    puts e
    kill_everything
  end
end

ComputeController.new
