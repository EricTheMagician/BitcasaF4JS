###
this program takes in one command line argument and that's the server number
###

fs = require 'fs-extra'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
ipc = require 'node-ipc'
BitcasaClient = module.exports.client
config = require('./config.json')
pth = require 'path'

ipc.config =
  appspace        : 'bitcasaf4js.',
  socketRoot      : '/tmp/',
  id              : "download#{process.argv[2]}",
  networkHost     : 'localhost',
  networkPort     : 8000,
  encoding        : 'utf8',
  silent          : false,
  maxConnections  : 100,
  retry           : 500,
  maxRetries      : 5,
  stopRetrying    : false

logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/BitcasaF4JS.log', level:'debug' })
    ]
  })
client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)

download = (path, name, start,end,maxSize, recurse, cb ) ->
  Fiber( ->
    baseName = pth.basename path
    #save location
    location = pth.join(client.downloadLocation,"#{baseName}-#{chunkStart}-#{chunkEnd}")
    client.logger.log('silly',"cache location: #{location}")

    failedArguments =
      buffer: new Buffer(0)
      start: 0
      end: 0

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
        return cb(null,failedArguments)
    else
      client.logger.log("debug", "downloading #{name} - #{chunkStart}-#{chunkEnd}")
      if client.rateLimit.tryRemoveTokens(1)
        client.logger.log "silly", "download requests: #{client.rateLimit.getTokensRemaining()}"
        client.logger.log "silly", "starting to download #{location}"

        _download = (_cb) ->
          called = false
          rest.get "#{BASEURL}files/name.ext?path=#{path}&access_token=#{client.accessToken}", {
            decoding: "buffer"
            timeout: 300000
            headers:
              Range: "bytes=#{chunkStart}-#{chunkEnd}"
          }
          .on 'complete', (result, response) ->
            unless called
              called = true
              if result instanceof Error
                  _cb(null, {error: result})
              else
                  _cb(null, {error:null, data: response.raw, response: response})

        download = Future.wrap(_download)
        res = download().wait()

        if res.error
          cb(res.error.message,failedArguments)
          return

        data = res.data
        response = res.response

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
              client.folderTree.remove(filePath)
              client.ee.emit "downloaded", "file does not exist anymore","#{baseName}-#{chunkStart}", failedArguments
              return cb("file does not exist anymore", failedArguments)
            if res.error.code == 9006
              client.ee.emit "downloaded", "api rate limit reached while downloading","#{baseName}-#{chunkStart}", failedArguments
              return cb "api rate limit reached while downloading", failedArguments

            client.ee.emit "downloaded", "unhandled json error", "#{baseName}-#{chunkStart}", failedArguments
            return cb "unhandled json error"
          return cb "unhandled data type while downloading"
        else if  data.length !=  (chunkEnd - chunkStart + 1)
          client.logger.log("debug", "failed to download #{location} -- #{data.length} -- #{chunkStart - chunkEnd + 1} -- size mismatch")
          client.ee.emit "downloaded", "data downloaded incorrectSize", "#{baseName}-#{chunkStart}", failedArguments
          return cb "data downloaded incorrectSize"
        else
          client.logger.log("debug", "successfully downloaded #{location}")
          args =
            buffer: data,
            start: start - chunkStart,
            end : end+1-chunkStart

          client.ee.emit "downloaded", null,"#{baseName}-#{chunkStart}", args
          cb null, args
          return writeFile(location,data).wait()

      else #for not having enough tokens
        client.logger.log "debug", "downloading file failed: out of tokens"
        client.ee.emit "downloaded", "downloading file failed: out of tokens", "#{baseName}-#{chunkStart}", args
        return cb null, failedArguments


  ).run()

ipc.serve ->
  ipc.server.on 'download', (inData, socket) ->
    callback = (err, data) ->
      Object.extend(data, inData)
      ipc.server.emit 'downloaded', data
    download( inData.path,  inData.name,  inData.start, inData.end, inData.maxSize,  inData.recurse, callback )
