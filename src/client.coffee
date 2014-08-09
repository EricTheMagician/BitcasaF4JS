BASEURL = 'https://developer.api.bitcasa.com/v1/'
RateLimiter = require('limiter').RateLimiter
Client = require('node-rest-client').Client;
dict = require 'dict'
pth = require 'path'
fs = require 'fs-extra'
memoize = require 'memoizee'
d = require('d');
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait

#wrap async files to sync mode using fibers
writeFile = Future.wrap(fs.writeFile)
open = Future.wrap(fs.open)
read = Future.wrap(fs.read)
#since fs.exists does not return an error, wrap it using an error
_exists = (path, cb) ->
  fs.exists path, (success)->
    cb(null,success)
exists = Future.wrap(_exists)

_close = (path,cb) ->
  fs.close path, (err) ->
    cb(err, true)
close = Future.wrap(_close)

#for mocha testing
if Object.keys( module.exports ).length == 0
  r = require './folder.coffee'
  BitcasaFolder = r.folder
else
  BitcasaFolder = module.exports.folder


memoizeMethods = require('memoizee/methods')
existsMemoized = memoize(fs.existsSync, {maxAge:5000})
class BitcasaClient
  constructor: (@id, @secret, @redirectUrl, @logger, @accessToken = null, @chunkSize = 1024*1024, @advancedChunks = 10, @cacheLocation = '/tmp/node-bitcasa') ->
    @rateLimit = new RateLimiter 175, 'minute'
    now = (new Date)
    root = new BitcasaFolder(@,'/', '', now, now, [])
    @folderTree = new dict({'/': root})
    @bitcasaTree = new dict({'/': '/'})
    @downloadTree = new dict()
    if @accessToken == null
      throw new Error "accessToken in the config file cannot be blank"
    else
      @setRest()

    @downloadLocation = pth.join @cacheLocation, "download"
    @uploadLocation = pth.join @cacheLocation, "upload"
    fs.ensureDirSync(@downloadLocation)
    fs.ensureDirSync(@uploadLocation)

  setRest: ->
    @client = new Client()
    @client.registerMethod 'getRootFolder', "#{BASEURL}folders/?access_token=#{@accessToken}", "GET"
    @client.registerMethod 'downloadChunk', "#{BASEURL}files/name.ext?path=${path}&access_token=#{@accessToken}", "GET"
    @client.registerMethod 'getFolder', "#{BASEURL}folders${path}?access_token=#{@accessToken}&depth=${depth}", "GET"
    @client.registerMethod 'getUserProfile', "#{BASEURL}user/profile?access_token=#{@accessToken}", "GET"

  loginUrl: ->
    "#{BASEURL}oauth2/authenticate?client_id=#{@id}&redirect_url=#{@redirectUrl}"

  authenticate: (code) ->
    url = "#{BASEURL}oauth2/access_token?secret=#{@secret}&code=#{code}"
    new Error("Not implemented")

  validateAccessToken: (cb) ->
    client = @;
    req = @client.methods.getUserProfile  (data, response) ->
      try
        data = JSON.parse(data)
      catch error
        @logger.log "debug", "when parsing validation, data was not json"
        cb error
        return
      if data.error
        cb data.error
    req.on 'error', (err) ->
      cb err

  # callback should take 3 parameters:
  #   a buffer, where to start and where to end.
  #   the buffer is where the data is located
  download: (client, path, name, start,end,maxSize, recurse, cb ) ->
    #round the amount of bytes to be downloaded to multiple chunks
    chunkStart = Math.floor((start)/client.chunkSize) * client.chunkSize
    end = Math.min(end,maxSize)
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file

    chunks = (chunkEnd - chunkStart)/client.chunkSize
    if chunks > 1 and (maxSize - start) > 65536
      client.logger.log("debug", "number chunks requested greater than 1 - (start,end) = (#{start}-#{end})")
      client.logger.log("debug", "number chunks requested greater than 1 - (chunkStart,chunkEnd) = (#{chunkStart}-#{chunkEnd})")

    Fiber( ->
      baseName = pth.basename path
      #save location
      location = pth.join(client.downloadLocation,"#{baseName}-#{chunkStart}-#{chunkEnd}")
      client.logger.log('silly',"cache location: #{location}")


      #check if the data has been cached or not
      #otherwise, download from the web

      if exists(location).wait()
        if recurse
          readSize = end - start;
          buffer = new Buffer(readSize+1)
          fd = open(location,'r').wait()
          bytesRead = read(fd,buffer,0,readSize+1, start-chunkStart).wait()
          close(fd)
          args =
            buffer: buffer
            start: 0
            end: readSize + 1
          client.logger.log('silly',"file exists: #{location}--#{buffer.slice(start,end).length}")
          return cb(null,args)
        else
          cb(null,null)
      else
        client.logger.log("debug", "#{name} - downloading #{chunkStart}-#{chunkEnd}")
        if client.rateLimit.tryRemoveTokens(1)
          client.logger.log "debug", "download requests: #{client.rateLimit.getTokensRemaining()}"
          args =
            timeout: 120000
            "path":
              "path": path
            headers:
              Range: "bytes=#{chunkStart}-#{chunkEnd}"
          client.logger.log "debug", "starting to download #{location}"
          _download = (_cb) ->
            req = client.client.methods.downloadChunk args, (data, response)->
              res = {data:data, response: response}
              _cb(null, res)

            req.on 'error', (err) ->
              client.logger.log("error","there was an error downloading: #{err}")
              _cb(err)
          download = Future.wrap(_download)
          try
            res = download().wait()
          catch error
            cb(error)

          data = res.data
          response = res.response

          failed = true #assume that the download failed
          client.logger.log("debug", "downloaded: #{location} - #{chunkEnd-chunkStart} -- limit #{client.rateLimit.getTokensRemaining()}")

          if not (data instanceof Buffer)
            client.logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type -- content-type: #{response.headers["content-type"]} -- encoding #{response.headers["content-encoding"]} - path : #{path}")
            client.logger.log("debug", data)
            if response.headers["content-type"] == "application/json; charset=UTF-8"
              res = JSON.parse(data)
              #if file not found,remove it from the tree.
              #this can happen if another client has deleted
              if res.error.code == 2003
                parentPath = client.bitcasaTree.get(pth.dirname(path))
                filePath = pth.join(parentPath,name)
                client.folderTree.delete(filePath)
          else if  data.length < (chunkStart - chunkEnd + 1)
            client.logger.log("debug", "failed to download #{location} -- #{data.length} - size mismatch")
          else
            client.logger.log("debug", "successfully downloaded #{location}")
            writeFile(location,data)
            failed = false


          if failed and res.error.code == 9006 #api limit
            fiber = Fiber.current
            fiberRun = ->
              fiber.run()
            setTimeout(fiberRun, 61000)
            Fiber.yield()
            cb(null,{buffer:new Buffer(0), start:0, end:0})
          else if recurse and failed  #let the fs decide what to do.
            args =
              buffer: new Buffer(0),
              start: 0,
              end : 0
            cb(null,args)
          else if (failed) and (not recurse)
            client.downloadTree.delete("#{baseName}-#{chunkStart}")
            cb(null, null)
          else if not failed
            args =
              buffer: data,
              start: start - chunkStart,
              end : end+1-chunkStart
            client.downloadTree.delete("#{baseName}-#{chunkStart}")
            cb(null, args )
        else #for not having enough tokens
          if recurse
            args =
              buffer: buffer
              start: 0
              end: readSize + 1
            client.logger.log "debug", "downloading file failed: out of tokens"
            cb null, args
          else
            cb null, null


    ).run()
Object.defineProperties(BitcasaClient.prototype, memoizeMethods({
  getFolders: d( (path,cb)->
    client = @
    object = client.folderTree.get(path)
    if object instanceof BitcasaFolder
      console.log "requests: #{client.rateLimit.getTokensRemaining()}"
      if @rateLimit.tryRemoveTokens(1)
        callback = (data,response) ->
          BitcasaFolder.parseFolder(data,response, client,null, cb)
        depth = 3
        if path == "/"
          depth = 1
        client.logger.log("debug", "getting folder info from bitcasa for #{path} -- depth #{depth}")
        url = "#{BASEURL}/folders#{object.bitcasaPath}?access_token=#{client.accessToken}&depth=#{depth}"
        client.client.get(url, callback)
      else
        client.logger.log("remaining requests too low: #{client.rateLimit.getTokensRemaining()}" )

  , { maxAge: 120000, length: 1 })
}));
module.exports.client = BitcasaClient
