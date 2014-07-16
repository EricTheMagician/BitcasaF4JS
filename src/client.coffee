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
  constructor: (@id, @secret, @redirectUrl, @accessToken = null, @chunkSize = 1024*1024, @cacheLocation = '/tmp/node-bitcasa') ->
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
    @client.registerMethod 'getFolder', url = "#{BASEURL}/folders${path}?access_token=#{@accessToken}", "GET"

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

  # callback should take 3 parameters:
  #   a buffer, where to start and where to end.
  #   the buffer is where the data is located
  download: (path, name, start,end,size, recurse, cb ) ->
    client = @

    #round the amount of bytes to be downloaded to multiple chunks
    chunkStart = Math.floor(start/client.chunkSize) * client.chunkSize
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, size) #and make sure that it's not bigger than the actual file
    chunks = (chunkEnd - chunkStart)/client.chunkSize

    if chunks > 1
      throw new Error('number of chunks requested needs to be 1')

    #save locations
    locations = pth.join(client.cacheLocation,"#{name}-#{chunkStart}-#{chunkEnd}")

    #check if the data has been cached or not
    #otherwise, download from the web

    if fs.existsSync(location)
      fd = fs.openSync(location)
      size = end -start;
      buffer = new Buffer(size)
      data = fs.readSync(fd,buffer,0, size,0)
      cb(buffer, start - chunkStart, end-chunkStart)
    else
      @rateLimit.removeToken 1, (err, remainingRequests) ->
        if err
          t = ->
            client.download(path, name, start,end,size, true,cb )
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
              cb(buf, start - chunkStart, end - chunkStart)
          client.client.methods.downloadChunk args,callback
    if recurse
      callback = ->
      client.download(path, name, start + client.chunkSize,end + client.chunkSize,size, false, callback )

  getFolders: (path..., cb) ->
    if path.length == 0
      path = '/'
    console.log path
    client = @
    parent = client.folderTree.get(path)
    children = parent.children
    console.log 'children', children
    if children.length == 0 and parent.name == 'root'
      callback = ->
        client.getFolders(cb)
      @getRoot callback
    else
      for child in children
        object = client.folderTree.get(pth.join(path,child))
        if object instanceof BitcasaFolder
          @rateLimit.removeTokens 1, (err,remainingRequests) ->
            callback = (data,response) ->
              BitcasaFolder.parseFolder(data,response, client,cb)

            url = "#{BASEURL}/folders#{object.bitcasaPath}?access_token=#{client.accessToken}"
            client.client.get(url, callback)

module.exports.client = BitcasaClient
