# A Connection manages a socket.io connection to a sharejs server.
#
# This class implements the client side of the protocol defined here:
# https://github.com/josephg/ShareJS/wiki/Wire-Protocol
#
# The equivalent server code is in src/server/socketio.coffee.
#
# This file is a bit of a mess. I'm dreadfully sorry about that. It passes all the tests,
# so I have hope that its *correct* even if its not clean.
#
# Most of Connection exists to support the open() method, which creates a new document
# reference.

if WEB?
	types ||= exports.types
	throw new Error 'Must load socket.io before this library' unless window.io
	io = window.io
else
	types = require '../types'
	io = require 'socket.io-client'
	Doc = require('./doc').Doc

class Connection
	constructor: (origin) ->
		@docs = {}
		@numDocs = 0

		# Map of docName -> map of type -> function(data, error)
		#
		# Once socket.io isn't buggy, this will be rewritten to use socket.io's RPC.
		@handlers = {}

		# We can't reuse connections because the socket.io server doesn't
		# emit connected events when a new connection comes in. Multiple documents
		# are already multiplexed over the connection by socket.io anyway, so it
		# shouldn't matter too much unless you're doing something particularly wacky.
		@socket = io.connect origin, 'force new connection': true

		@socket.on 'connect', @connected
		@socket.on 'disconnect', @disconnected
		@socket.on 'message', @onMessage
		@socket.on 'connect_failed', (error) =>
			error = 'forbidden' if error == 'unauthorized' # For consistency with the server
			@socket = null
			@emit 'connect failed', error
			# Cancel all hanging messages
			for docName, h of @handlers
				for t, callbacks of h
					callback null, error for callback in callbacks

		# This avoids a bug in socket.io-client (v0.7.9) which causes
		# subsequent connections on the same host to not fire a .connect event
		if @socket.socket.connected
			setTimeout (=> @connected()), 0

	disconnected: =>
		# Start reconnect sequence
		@emit 'disconnect'

	connected: =>
		# Stop reconnect sequence
		@emit 'connect'

	# Send the specified message to the server. The server's response will be passed
	# to callback. If the message is 'open', ops will be sent to follower()
	#
	# The callback is optional. It takes (data, error). Data might be missing if the
	# error was a connection error.
	send: (msg, callback) ->
		throw new Error 'Cannot send messages to a closed connection' if @socket == null

		docName = msg.doc

		if docName == @lastSentDoc
			delete msg.doc
		else
			@lastSentDoc = docName

		@socket.json.send msg
		
		if callback
			type = if msg.open == true then 'open'
			else if msg.open == false then 'close'
			else if msg.create then 'create'
			else if msg.snapshot == null then 'snapshot'
			else if msg.op then 'op response'

			#cb = (response) =>
				#	if response.doc == docName
				#	@removeListener type, cb
				#	callback response, response.error

			docHandlers = (@handlers[docName] ||= {})
			callbacks = (docHandlers[type] ||= [])
			callbacks.push callback

	onMessage: (msg) =>
		docName = msg.doc

		if docName != undefined
			@lastReceivedDoc = docName
		else
			msg.doc = docName = @lastReceivedDoc

		@emit 'message', msg

		# This should probably be rewritten to use socketio's message response stuff instead.
		# (it was originally written for socket.io 0.6)
		type = if msg.open == true or (msg.open == false and msg.error) then 'open'
		else if msg.open == false then 'close'
		else if msg.snapshot != undefined then 'snapshot'
		else if msg.create then 'create'
		else if msg.op then 'op'
		else if msg.v != undefined then 'op response'

		callbacks = @handlers[docName]?[type]
		if callbacks
			delete @handlers[docName][type]
			c msg, msg.error for c in callbacks

		if type == 'op'
			doc = @docs[docName]
			doc._onOpReceived msg if doc

	makeDoc: (params) ->
		name = params.doc
		throw new Error("Doc #{name} already open") if @docs[name]

		type = params.type
		type = types[type] if typeof type == 'string'
		doc = new Doc(@, name, params.v, type, params.snapshot)
		doc.created = !!params.create
		@docs[name] = doc
		@numDocs++

		doc.on 'closed', =>
			delete @docs[name]
			@numDocs--

		doc

	# Open a document that already exists
	# callback is passed a Doc or null
	# callback(doc, error)
	openExisting: (docName, callback) ->
		if @socket == null # The connection is perminantly disconnected
			callback null, 'connection closed'
			return

		return @docs[docName] if @docs[docName]?

		@send {'doc':docName, 'open':true, 'snapshot':null}, (response, error) =>
			if error
				callback null, error
			else
				# response.doc is used instead of docName to allow docName to be null.
				# In that case, the server generates a random docName to use.
				callback @makeDoc(response)

	# Open a document. It will be created if it doesn't already exist.
	# Callback is passed a document or an error
	# type is either a type name (eg 'text' or 'simple') or the actual type object.
	# Types must be supported by the server.
	# callback(doc, error)
	open: (docName, type, callback) ->
		if @socket == null # The connection is perminantly disconnected
			callback null, 'connection closed'
			return

		if typeof type == 'function'
			callback = type
			type = 'text'

		callback ||= ->

		type = types[type] if typeof type == 'string'

		throw new Error "OT code for document type missing" unless type

		if docName? and @docs[docName]?
			doc = @docs[docName]
			if doc.type == type
				callback doc
			else
				callback doc, 'Type mismatch'

			return

		@send {'doc':docName, 'open':true, 'create':true, 'snapshot':null, 'type':type.name}, (response, error) =>
			if error
				callback null, error
			else
				response.snapshot = type.create() unless response.snapshot != undefined
				response.type = type
				callback @makeDoc(response)

	# To be written. Create a new document with a random name.
	create: (type, callback) ->
		open null, type, callback

	disconnect: () ->
		if @socket
			@emit 'disconnected'
			@socket.disconnect()
			@socket = null

# Make connections event emitters.
unless WEB?
	MicroEvent = require './microevent'

MicroEvent.mixin Connection

exports.Connection = Connection