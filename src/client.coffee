BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
dict = require 'dict'
pth = require 'path'

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './folder.coffee'
  BitcasaFolder = r.folder
else
  BitcasaFolder = module.exports.folder

class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @accessToken = null, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 180, 'minute'
    now = (new Date).getTime()
    root = new BitcasaFolder(@,'/', 'root', now, now)
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    if @accessToken != null
      @setRest()

  setRest: ->
    @client = new Client
    @client.registerMethod 'getRootFolder', "#{BASEURL}folders/?access_token=#{@accessToken}", "GET"
    @client.registerMethod 'downloadChunk', "#{BASEURL}files/name.ext?path=${path}&access_token=#{@accessToken}", "GET"

    @client.on 'error', (err) ->
      console.log('There was an error connecting with bitcasa:', err)

  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (code) ->
    url = "#{BASEURL}oauth2/access_token?secret=#{@secret}&code=#{code}"
    new Error("Not implemented")

  getRoot: (cb) ->
    client = @
    callback = (data,response) ->
      BitcasaFolder.parseFolder(data,response, client,cb)
    @rateLimit.removeTokens 1, (err, remaining) ->
      client.client.methods.getRootFolder callback

  download: (path, name, start,end,size,cb ) ->
    client = @
    args =
      "path":
        "path": path
      headers:
        Range: "bytes=#{start}-#{Math.min(size,end)}"
    console.log args
    callback = (data,response) ->
      location = pth.join(client.cacheLocation,"#{name}-#{start}-#{end}")
      console.log response
      console.log data.length
      if typeof(cb) ==  typeof(Function)
        cb()

    client.client.methods.downloadChunk args,callback

  getFolders: (cb) ->
    client = @
    children = client.folderTree.get('/').children
    if children.length == 0
      callback = ->
        client.getFolders(cb)
      @getRoot callback
    else
      callback = (data,response) ->
        BitcasaFolder.parseFolder(data,response, client,cb)

      for folder in children
        @rateLimit.removeTokens 1, (err,remainingRequests) ->
          url = "#{BASEURL}/folders#{client.folderTree.get(folder).bitcasaPath}?access_token=#{client.accessToken}&depth=0"
          client.client.get(url, callback)

module.exports.client = BitcasaClient
