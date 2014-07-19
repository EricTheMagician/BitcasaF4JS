config = require('./config.json')
fs = require 'fs'
winston = require 'winston'
location = config.cacheLocation
pth = require 'path'
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

watcher = fs.watch location, (event, filename) ->
  logger.log("debug", "Watcher: event #{event} triggered by #{filename}")

  files = fs.readdirSync(location)
  stats = (fs.statSync(pth.join(location,file)) for file in files)
  sizes = (stat.size for stat in stats)
  totalSize = sizes.reduce (x,y) -> x + y

  if totalSize > maxCache
    all = zip(files,stats)
    all.sort(sortStats)

    for info in all
      if totalSize > maxCache
        break
      totalSize -= info[1].size
      fs.unlinkSync(pth.join(info[0]))
