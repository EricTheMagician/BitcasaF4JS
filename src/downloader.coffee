###
this program takes in one command line argument and that's the server number
###
BASEURL = 'https://developer.api.bitcasa.com/v1/'
fs = require 'fs-extra'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait
ipc = require 'node-ipc'
config = require('./config.json')
winston = require 'winston'
pth = require 'path'
rest = require 'restler'

writeFile = Future.wrap(fs.writeFile)
open = Future.wrap(fs.open,2)
read = Future.wrap(fs.read,5)
#since fs.exists does not return an error, wrap it using an error
_exists = (path, cb) ->
  fs.exists path, (success)->
    cb(null,success)
exists = Future.wrap(_exists,1)

_close = (path,cb) ->
  fs.close path, (err) ->
    cb(err, true)
close = Future.wrap(_close,1)

ipc.config =
  appspace        : 'bitcasaf4js.',
  socketRoot      : '/tmp/',
  id              : "download#{process.argv[2]}",
  networkHost     : 'localhost',
  networkPort     : 8000,
  encoding        : 'utf8',
  silent          : true,
  maxConnections  : 100,
  retry           : 500,
  maxRetries      : 5,
  stopRetrying    : false

logger = new (winston.Logger)({
    transports: [
      new (winston.transports.File)({ filename: '/tmp/BitcasaF4JS.log', level:'debug' })
    ]
  })

failedArguments =
  buffer: new Buffer(0)
  start: 0
  end: 0

download = (path, name, start,end,maxSize, cb ) ->
  #round the amount of bytes to be downloaded to multiple chunks
  chunkStart = Math.floor((start)/config.chunkSize) * config.chunkSize
  end = Math.min(end,maxSize)
  chunkEnd = Math.min( Math.ceil(end/config.chunkSize) * config.chunkSize, maxSize)-1 #and make sure that it's not bigger than the actual file
  chunks = (chunkEnd - chunkStart)/config.chunkSize

  Fiber( ->
    baseName = pth.basename path
    #save location
    location = pth.join(config.cacheLocation, "download","#{baseName}-#{chunkStart}-#{chunkEnd}")


    #check if the data has been cached or not
    #otherwise, download from the web

    if exists(location).wait()
      readSize = end - start;
      cb(null,failedArguments)
      return null
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
            if result instanceof Error
                _cb(null, {error: result})
            else
              if result instanceof Error
                _cb(null, {error: result})
              else
                if response.headers["content-type"].length == 0 #if it's raw data
                  _cb(null, {error:null, data: response.raw, response: response})
                else
                  try #check to see if it's json
                    data = JSON.parse(result)
                    _cb(null, {error:null, data: data, response: response})
                  catch #it might return html for some reason
                    _cb(null, {error:null, data: response.raw, response: response})


      _download = Future.wrap(_download,0)
      res = _download().wait()

      if res.error
        cb(res.error.message,failedArguments)
        return

      data = res.data
      response = res.response

      if not (data instanceof Buffer)
        logger.log("debug", "failed to download #{location} -- typeof data: #{typeof data} -- length #{data.length} -- invalid type -- content-type: #{response.headers["content-type"]} -- encoding #{response.headers["content-encoding"]} - path : #{path}")
        logger.log("debug", data)
        if data.error
          if data.error.code
            code = data.error.code
            if code == 2001 or code == 2003 or code == 3001
              return cb "delete"
            if code == 9006
              fn = ->
                cb "api rate limit reached"
              return setTimeout( fn, 61000 )
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
        writeFile(location,data).wait()

        return cb null, args


  ).run()

ipc.serve ->
  ipc.server.on 'download', (inData, socket) ->
    callback = (err, data) ->
      if data == "delete"
        outData =
          ostart: inData.start #original start
          path: inData.path
          delete: true
      else
        outData =
          ostart: inData.start #original start
          path: inData.path
          delete: false
      ipc.server.emit socket, 'downloaded',outData
    download( inData.path,  inData.name,  inData.start, inData.end, inData.maxSize, callback )
    return null
ipc.server.start()
