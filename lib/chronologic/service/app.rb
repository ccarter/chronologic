require "sinatra/base"
require "active_support/core_ext/class"
require "yajl"

# TODO: caching headers?
class Chronologic::Service::App < Sinatra::Base

  cattr_accessor :logger

  post "/object" do
    protocol.record(params["object_key"], params["data"])
    status 201
  end

  get "/object/:object_key" do
    # FIXME: stomping on Demeter here
    status 200
    json protocol.schema.object_for(params["object_key"])
  end

  delete "/object/:object_key" do
    protocol.unrecord(params["object_key"])
    status 204
  end

  post "/subscription" do
    protocol.subscribe(
      params["timeline_key"],
      params["subscriber_key"],
      params.fetch("backlink_key") { '' },
      params["backfill"] == "true"
    )
    status 201
  end

  delete "/subscription/:subscriber_key/:timeline_key" do
    protocol.unsubscribe(params["subscriber_key"], params["timeline_key"])
    status 204
  end

  get '/subscription/is_connected' do
    connection = protocol.connected?(
      params['subscriber_key'],
      params['timeline_backlink']
    )

    status(200)
    json(params['subscriber_key'] => connection)
  end

  post "/event" do
    fanout = params.fetch("fanout", "") == "1"
    uuid = protocol.publish(event, fanout)
    headers("Location" => "/event/#{params["key"]}/#{uuid}")
    status 201
  end

  delete "/event/:event_key" do
    raw_event = protocol.schema.event_for(params["event_key"])
    if raw_event.empty?
      status 204
      return
    end
    event = Chronologic::Event.load_from_columns(raw_event)
    event.key = params["event_key"]
    protocol.unpublish(event)
    status 204
  end

  get '/event/:event_key/:token' do
    event = protocol.fetch_event(params['event_key'])
    if event.empty?
      status 404
    else
      json(
        'event' => event.to_transport
      )
    end
  end

  put '/event/:event_key/:token' do
    update_timelines = if params.fetch('update_timelines', '') == "true"
      true
    else
      false
    end
    protocol.update_event(event, update_timelines)
    headers("Location" => "/event/#{event.key}/#{event.token}")
    status 204
  end

  get "/timeline/:timeline_key" do
    options = {
      :fetch_subevents => params["subevents"] == "true",
      :page => params["page"] || nil,
      :per_page => Integer(params["per_page"] || "20")
    }
    feed = protocol.feed(params["timeline_key"], options)

    status 200
    json(
      "feed" => feed.items,
      "count" => feed.count,
      "next_page" => feed.next_page
    )
  end

  helpers do

    def json(object)
      content_type("application/json")
      Yajl.dump(object)
    end

    def event
      Chronologic::Event.new(
        "key" => params["key"],
        "timestamp" => Time.parse(params["timestamp"]),
        "data" => JSON.load(params["data"]),
        "objects" => JSON.load(params["objects"]),
        "timelines" => JSON.load(params["timelines"])
      )
    end

    def protocol
      Chronologic::Service::Protocol
    end

  end

  before do
    @timer = Time.now
  end

  after do
    time = "%.3fs" % [Time.now - @timer]
    logger.info "#{request.request_method} #{request.path}: #{time}"
  end

  disable :dump_errors
  disable :show_exceptions

  error do
    exception = env["sinatra.error"]

    logger.error "Error: #{exception.message} (#{exception.class})"
    logger.error "Params: #{params.inspect}"
    logger.error exception.backtrace.join("\n  ")

    status 500
    json({
      "message" => exception.message,
      "backtrace" => exception.backtrace.take(20),
      "params" => params
    })
  end

end

