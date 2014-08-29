###
this program takes in one command line argument and that's the server number
###

fs = require 'fs-extra'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
ipc = require 'node-ipc'
config = require('./config.json')
winston = require 'winston'
pth = require 'path'
rest = require 'restler'

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

download = (path, name, start,end,maxSize, recurse, cb ) ->
  Fiber( ->
    baseName = pth.basename path
    #save location
    location = pth.join(config.cacheLoction, "download","#{baseName}-#{chunkStart}-#{chunkEnd}")

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
        return cb(null,args)
      else
        return cb(null,failedArguments)
    else
      logger.log("debug", "downloading #{name} - #{chunkStart}-#{chunkEnd}")

      _download = (_cb) ->
        called = false
        rest.get "#{BASEURL}files/name.ext?path=#{path}&access_token=#{config.accessToken}", {
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

      if not (data instanceof Buffer)
        logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type -- content-type: #{response.headers["content-type"]} -- encoding #{response.headers["content-encoding"]} - path : #{path}")
        logger.log("debug", data)
        return cb "unhandled data type while downloading"
      else if  data.length !=  (chunkEnd - chunkStart + 1)
        logger.log("debug", "failed to download #{location} -- #{data.length} -- #{chunkStart - chunkEnd + 1} -- size mismatch")
        return cb "data downloaded incorrectSize"
      else
        logger.log("debug", "successfully downloaded #{location}")
        args =
          buffer: data,
          start: start - chunkStart,
          end : end+1-chunkStart

        cb null, args
        return writeFile(location,data).wait()


  ).run()

ipc.serve ->
  ipc.server.on 'download', (inData, socket) ->
    callback = (err, data) ->
      Object.extend(data, inData)
      ipc.server.emit 'downloaded', data
    download( inData.path,  inData.name,  inData.start, inData.end, inData.maxSize,  inData.recurse, callback )

ipc.server.start()
