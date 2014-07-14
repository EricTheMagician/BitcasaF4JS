BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
dict = require 'dict'
pth = require 'path'
fs = require 'fs'

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
    root = new BitcasaFolder(@,'/', 'root', now, now, [])
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    if @accessToken != null
      @setRest()

    client = @;
    fs.exists @cacheLocation, (exists) ->
      if !exists
        fs.mkdirSync(client.cacheLocation)

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

    #save location
    location = pth.join(client.cacheLocation,"#{name}-#{start}-#{end}")

    #check if the data has been cached or not
    #otherwise, download from the web

    if fs.existsSync(location)
      fd = fs.openSync(location)
      size = end -start;
      buffer = new Buffer(size)
      data = fs.readSync(fd,buffer,0, size,0)
    else
      @rateLimit.removeToken 1, (err, remainingRequests) ->
        if err
          t = ->
            client.download(path, name, start,end,size,cb )
          setTimeout(t, 60000)
        else
          args =
            "path":
              "path": path
            headers:
              Range: "bytes=#{start}-#{Math.min(size,end)}"
          callback = (data,response) ->
            buf = response.client._buffer.pool

            fd = fs.createWriteStream(location)
            fd.end(buf,'binary')
            fd.on 'finish', ->
              if typeof(cb) ==  typeof(Function)
                cb()

          client.client.methods.downloadChunk args,callback

  getFolders: (cb) ->
    client = @
    children = client.folderTree.get('/').children
    console.log 'children', children
    if children.length == 0
      callback = ->
        client.getFolders(cb)
      @getRoot callback
    else
      for folder in children
        @rateLimit.removeTokens 1, (err,remainingRequests) ->
          f = folder;
          callback = (data,response) ->
            console.log "callback from folders #{f}"
            BitcasaFolder.parseFolder(data,response, client,cb)

          url = "#{BASEURL}/folders#{client.folderTree.get("/#{folder}").bitcasaPath}?access_token=#{client.accessToken}&depth=0"
          client.client.get(url, callback)

module.exports.client = BitcasaClient
