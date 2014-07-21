config = require('./config.json')
fs = require 'fs'
winston = require 'winston'
memoize = require 'memoizee'
pth = require 'path'

location = config.cacheLocation
maxCache = config.maxCacheSize  * 1024 * 1024

logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/somefile.log', level:'debug' })
    ]
})

zip = () ->
  lengthArray = (arr.length for arr in arguments)
  length = Math.min(lengthArray...)
  for i in [0...length]
    arr[i] for arr in arguments

sortStats = (x,y) ->
   return x[1].atime.getTime() - y[1].atime.getTime()

locked = false
statfs = memoize(fs.statSync, {maxAge:60000} )
watcher = fs.watch location, (event, filename) ->
  logger.log("silly", "Watcher: event #{event} triggered by #{filename} - status: #{locked} - #{not locked}")
  if locked == false
    locked = true
    console.log("location : #{location} - maxCache: #{maxCache}")
    try
      files = fs.readdirSync(location)
      stats = (statfs(pth.join(location,file)) for file in files)
      sizes = (stat.size for stat in stats)
      totalSize = sizes.reduce (x,y) -> x + y
      if totalSize > maxCache
        all = zip(files,stats)
        all.sort(sortStats)

        for info in all
          if totalSize < maxCache
            break
          totalSize -= info[1].size
          fs.unlinkSync(pth.join(location,info[0]))
    catch error
      console.log("error", "Watcher: there was a problem: #{error}")
    locked = false