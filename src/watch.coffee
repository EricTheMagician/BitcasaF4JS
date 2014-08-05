config = require('./config.json')
fs = require 'fs'
winston = require 'winston'
memoize = require 'memoizee'
pth = require 'path'
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait

location = config.cacheLocation
downloadLocation = pth.join(config.cacheLocation, "download")
maxCache = config.maxCacheSize  * 1024 * 1024

logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/BitcasaF4JS.log', level:'debug' })
    ]
})

zip = () ->
  lengthArray = (arr.length for arr in arguments)
  length = Math.min(lengthArray...)
  for i in [0...length]
    arr[i] for arr in arguments

sortStats = (x,y) ->
  diff = x[1].atime.getTime() - y[1].atime.getTime()
  switch
    when diff < 0 then return -1
    when diff == 0 then return 0
    else return 1
readdir = Future.wrap(fs.readdir,1)
_statfs = (path, cb) ->
  fs.stat path, (err,attr)->
    cb(err,attr )
_memStatfs = Future.wrap(_statfs)
_memStatfs2 = (path) ->
  return _memStatfs(path).wait()
statfs = memoize(_memStatfs2, {maxAge:14400000} ) #remember for 4 hours
_unlink = (path, cb) ->
  fs.unlink path, ->
    cb(null, true)
unlink = Future.wrap(_unlink)
locked = false
watcher = fs.watch location, (event, filename) ->
  logger.log("silly", "Watcher: event #{event} triggered by #{filename} - status: #{locked} - #{not locked}")
  if locked == false
    locked = true
    Fiber( ()->
      try
        files = readdir(location).wait()
        stats = (statfs(pth.join(location,file)) for file in files)
        sizes = (stat.size for stat in stats)
        totalSize = sizes.reduce (x,y) -> x + y
        if totalSize > maxCache
          all = zip(files,stats)
          all.filter (element)->

          all.sort(sortStats)


          for info in all
            if totalSize < maxCache
              break
            totalSize -= info[1].size
            unlink(pth.join(location,info[0])).wait()
      catch error
        logger.log("debug", "Watcher: there was a problem: #{error}")
      locked = false
    ).run()
