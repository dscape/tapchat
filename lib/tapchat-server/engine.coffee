Path         = require('path')
Fs           = require('fs')
WorkingQueue = require('capisce').WorkingQueue
Http         = require('http')
Express      = require('express')
Url          = require('url')
WebSocket    = require('faye-websocket')
PasswordHash = require('password-hash')
CoffeeScript = require('coffee-script')
Util         = require('util')
Daemon       = require('daemon')

Config     = require './config'
B          = require './message_builder'
Buffer     = require './buffer'
Connection = require './connection'
BacklogDB  = require './backlog_db'

{starts, ends, compact, count, merge, extend, flatten, del, last} = CoffeeScript.helpers

class Engine
  constructor: (config, callback) ->
    @connections = []
    @clients     = []

    @password = config.password
    @port     = config.port

    throw 'No password set!' unless PasswordHash.isHashed(@password)

    @db = new BacklogDB this, =>
      @startServer(@port)
      callback(this) if callback

      @db.selectConnections (conns) =>
        @addConnection connInfo for connInfo in conns

  daemonize: ->
    logfile = Path.join(Config.getDataDirectory(), 'tapchat.log')
    pidfile = Path.join(Config.getDataDirectory(), 'tapchat.pid')

    @pid = Daemon.daemonize(logfile, pidfile)
    console.log('Daemon started successfully with pid:', @pid);

  startServer: (port) ->
    #@app = Express.createServer(Express.logger())
    @app = Express.createServer
      key:  Fs.readFileSync(Config.getCertFile())
      cert: Fs.readFileSync(Config.getCertFile())

    @app.use(Express.static(__dirname + '/../../web'));

    @app.addListener 'upgrade', (request, socket, head) =>
      query = Url.parse(request.url, true).query
      unless PasswordHash.verify(query.password, @password)
        # FIXME: Return proper HTTP error
        console.log 'bad password'
        request.socket.end('foo')
        return

      ws = new WebSocket(request, socket, head)
      console.log 'websocket client: connected'
      @addClient(ws)

    @app.listen(port)

    console.log "\nTapChat ready at https://localhost:#{port}\n"

  addClient: (client) ->
    client.sendQueue = new WorkingQueue(1)
    @clients.push(client)

    client.onmessage = (event) =>
      message = JSON.parse(event.data)
      console.log "Got message: #{Util.inspect(message)}"

      callback = (reply) =>
        @send client,
          _reqid: message._reqid
          msg:    merge(reply, success: true)

      if handler = @messageHandlers[message._method]
        try
          handler.apply(this, [ client, message, callback ])
        catch error
          console.log "Error handling message", error, event
          client.close()
      else
        console.log "No handler for #{message._method}"

    client.onclose = (event) =>
      console.log 'websocket client: disconnected', event.code, event.reason
      index = @clients.indexOf(client)
      @clients.splice(index, 1)

    @sendBacklog(client)

  send: (client, message, cb) ->
    message = @prepareMessage(message)
    #console.log 'CLIENT SEND:', JSON.stringify(message)
    client.sendQueue.perform (over) =>
      client.send JSON.stringify(message),
        cb() if cb
        over()
    return message

  prepareMessage: (message) ->
    message.time      = Date.now() unless message.time
    message.highlight = false      unless message.highlight
    message.eid       = -1         unless message.eid
    return message

  addConnection: (options) ->
    new Connection this, options, (conn) =>
      @connections.push conn
      conn.addListener 'event', (event) =>
        @broadcast event
      conn.sendBacklog null, =>
        conn.connect() if conn.autoConnect

  removeConnection: (conn, cb) ->
    conn.delete =>
      @connections.splice(@connections.indexOf(conn), 1)
      @broadcast B.connectionDeleted(conn)
      cb()

  findConnection: (cid) ->
    for conn in @connections
      return conn if conn.id == cid
    return null

  broadcast: (message, cb) ->
    queue = new WorkingQueue(@clients.length)

    #console.log 'BROADCAST', JSON.stringify(message)

    for client in @clients
      do (client) =>
        queue.perform (over) =>
          @send client, message, over

    queue.whenDone => cb() if cb
    queue.doneAddingJobs()

    return message

  sendBacklog: (client) ->
    queue = new WorkingQueue(1)

    queue.perform (over) =>
      @send client,
        type: 'header'
        idle_interval: 29000, # FIXME
        over

    for conn in @connections
      do (conn) =>
        queue.perform (over) =>
          conn.sendBacklog client, over

    queue.whenDone =>
      @send client,
        type: 'backlog_complete'

    queue.doneAddingJobs()

  messageHandlers:
    # FIXME
    # heartbeat: (client, messaage, callback) ->

    say: (client, message, callback) ->
      conn = @findConnection(message.cid)
      to   = message.to
      text = message.msg

      if text
        # selfMessage event will take care of opening the buffer.
        conn.say(to, text)
        return

      # No message, so just open the buffer.
      conn.getOrCreateBuffer to, Buffer::TYPE_QUERY, (buffer, created) ->
        callback
          name: to
          cid:  conn.id
          type: 'open_buffer'

    join: (client, message, callback) ->
      chan = message.channel
      conn = @findConnection(message.cid)

      conn.join(chan)

      callback
        name: chan
        cid:  conn.id
        type: 'open_buffer'

    part: (client, message, callback) ->
      conn = @findConnection(message.cid)
      conn.part(message.channel)
      callback()

    disconnect: (client, message, callback) ->
      @findConnection(message.cid).disconnect ->
        callback()

    reconnect: (client, message, callback) ->
      @findConnection(message.cid).reconnect =>
        callback()

    'add-server': (client, message, callback) ->
      @db.insertConnection message, (info) =>
        @addConnection info
        callback()

    'edit-server': (client, message, callback) ->
      conn = @findConnection(message.cid)
      conn.edit(message, callback)

    'delete-connection': (client, message, callback) ->
      conn = @findConnection(message.cid)
      @removeConnection(conn, callback)

module.exports = Engine
