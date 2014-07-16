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
  constructor: (@id, @secret, @redirectUrl, @logger, @accessToken = null, @chunkSize = 1024*1024, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 180, 'minute'
    now = (new Date).getTime()
    root = new BitcasaFolder(@,'/', 'root', now, now, [])
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    @downloadTree = new dict()
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
  download: (path, name, start,end,maxSize, recurse, cb ) ->
    client = @
    #round the amount of bytes to be downloaded to multiple chunks
    chunkStart = Math.floor((start+1)/client.chunkSize) * client.chunkSize
    end = Math.min(end,maxSize)
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file
    chunks = (chunkEnd - chunkStart)/client.chunkSize

    if chunks > 1
      throw new Error('number of chunks requested needs to be 1')

    #save locations
    location = pth.join(client.cacheLocation,"#{name}-#{chunkStart}-#{chunkEnd}")
    client.logger.log('debug',"cache location: #{location}")
    #check if the data has been cached or not
    #otherwise, download from the web

    if fs.existsSync(location)
      readSize = end - start;
      fd = fs.openSync(location,'r')
      buffer = new Buffer(readSize+1)
      bytesRead = fs.readSync(fd,buffer,0,readSize+1, start-chunkStart)
      console.log "#{start}-#{end} -- #{start-chunkStart}-#{start-chunkStart + readSize} -- bytes read, #{bytesRead}"
      cb(buffer, 0, readSize)
      fs.closeSync(fd)
    else
      @rateLimit.removeTokens 1, (err, remainingRequests) ->
        if err
          t = ->
            client.download(path, name, start,end,maxSize, true,cb )
          setTimeout(t, 60000)
        else
          args =
            "path":
              "path": path
            headers:
              Range: "bytes=#{chunkStart}-#{chunkEnd}"
          callback = (data,response) ->
            buf = response.client._buffer.pool
            bufOffset = response.client._buffer.offset

            writeBuffer = buf.slice(bufOffset - (chunkEnd-chunkStart + start - chunkStart)-1, bufOffset )
            fs.writeFileSync(location, writeBuffer)
            cb(buf, bufOffset - (chunkEnd-chunkStart + start - chunkStart)-1, bufOffset )

          client.client.methods.downloadChunk args,callback
    if recurse and  chunkEnd < maxSize
      callback = ->
      # client.download(path, name, start + client.chunkSize,end + client.chunkSize,maxSize, false, callback )

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
            if not err
              url = "#{BASEURL}/folders#{object.bitcasaPath}?access_token=#{client.accessToken}"
              client.client.get(url, callback)

module.exports.client = BitcasaClient
