require 'dotenv'
Dotenv.load('.scc.env')
require_relative 'administrator'
require 'byebug'
require 'json'


class TestData
  include Administrator

  def add(number, board = backlog_address)
    number.times do |n|
      puts n
      sqs.send_message(
        queue_url: board,
        message_body: {
          identity: (0..100).to_a.sample,
          message: 'createInstance'
        }.to_json
      )
    end
  end

  def delete(board_name)
    poller(board_name).poll do |msg|
      puts "deleting #{msg}"
      poller(board_name).delete_message(msg)
    end
  end

  def creds
  @creds ||= Aws::Credentials.new(
    ENV['AWS_ACCESS_KEY_ID'],
    ENV['AWS_SECRET_ACCESS_KEY'])
  end

  def terminate_instances
    instance_ids = ec2.describe_instances(
      filters: [
        {
          name: 'key-name',
          values: ['crawlBot']
        }
      ]).reservations.map(&:instances).map { |i| i.map(&:instance_id) }.flatten
    byebug
    # ec2.terminate_instances(instance_ids: instance_ids)
  end
end


TestData.new.add(3)
# TestData.new.delete('counter')
# TestData.new.terminate_instances
