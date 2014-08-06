#do this for mocha testing
if Object.keys( module.exports ).length == 0
  config = require('../build/config.json')
  BitcasaClient = require( '../src/client.coffee').client
  BitcasaFolder = require( '../src/folder.coffee').folder
  BitcasaFile = require( '../src/file.coffee').file
else
  config = require('./config.json')
  BitcasaClient = module.exports.client
  BitcasaFolder = module.exports.folder
  BitcasaFile = module.exports.file

f4js = require 'fuse4js'
winston = require 'winston'
os = require 'os'
Fiber = require 'fibers'
dict = require 'dict'
Future = require('fibers/future')
wait = Future.wait
fs = require 'fs-extra'
pth = require 'path'

logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/BitcasaF4JS.log', level:'debug' })
    ]
  })
#bitcasa client
client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)
#get folder attributes in the background
client.getFolders "/"

#http://lxr.free-electrons.com/source/include/uapi/asm-generic/errno-base.h#L23
errnoMap =
    EPERM: 1,
    ENOENT: 2,
    EACCES: 13,
    ENOTDIR: 20,
    EINVAL: 22,
    ENOTEMPTY: 39

_getFolder = (path, depth, cb) ->
  args =
    path:
      path: path
      depth: depth
  returned = false
  req = client.client.methods.getFolder args, (data, response) ->
    if not returned
      returned = true
      cb(null, data)

  req.on 'error', (err) ->
    if not returned
      returned = true
      cb(err)
  callback = ->
    if not returned
      returned = true
      cb("taking too long to receive a folder")

  setTimeout callback, 180000

getFolder = Future.wrap(_getFolder)

#this function will udpate all the folders content
getAllFolders = ->
  folders = [client.folderTree.get('/')]
  folderTree = new dict()
  client.folderTree.forEach (value, key) ->
    if value instanceof BitcasaFolder
      try
        if value.bitcasaPath.match(/\//g).length == 2
          folderTree.set key,  new BitcasaFolder(client, value.bitcasaPath, value.name, value.ctime, value.mtime, [])
          folders.push value
      catch error
        client.logger.log "error", "there was an error listing folder #{key}: #{value} -- #{error}"
  folderTree.set '/', new BitcasaFolder(client, '/', 'root', (new Date()).getTime(), (new Date()).getTime(),[])
  Fiber( ->
    fiber = Fiber.current
    fiberRun = ->
      fiber.run()
    start = new Date()

    retry = 0
    while folders.length > 0 and retry < 5
      retry++
      processing = []
      while processing.length < folders.length
        tokens = Math.min(Math.ceil(client.rateLimit.getTokensRemaining()/12), folders.length - processing.length)
        for i in [0...tokens]
          if not client.rateLimit.tryRemoveTokens(1)
            setTimeout fiberRun, 1000
            Fiber.yield()
          depth = 3
          if folders[i].bitcasaPath == '/'
            depth = 1
          processing.push getFolder(folders[i].bitcasaPath,depth)
        if processing.length < folders.length
          setTimeout fiberRun, 4500
          Fiber.yield()
      for i in [0...processing.length]
        if not processing[i].isResolved()
          try #catch socket connection error
            processing[i].wait()
            data = processing[i].get()
          catch error
            client.logger.log("error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error}")
            continue

        try
          result = JSON.parse(data)
        catch error
          folders.push(folders[i])
          client.logger.log "error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error} - folders length - #{folders.length}"
          continue

        if result.error
          client.logger.log "error", "there was an error getting folder: #{result.error.code} - #{result.error.message}"
          continue
        for o in result.result.items
          #get real path of parent
          parent = client.bitcasaTree.get(pth.dirname(o.path))
          realPath = pth.join(parent,o.name)

          #add child to parent folder
          parentFolder = folderTree.get parent
          if o.name not in parentFolder.children
            parentFolder.children.push o.name

          if o.category == 'folders'
            # keep track of the conversion of bitcasa path to real path
            client.bitcasaTree.set o.path, realPath
            folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), []) )
          else
            folderTree.set realPath,    new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime))
      folders.splice 0, processing.length
      client.logger.log "debug", "folders length after splicing: #{folders.length}"
    client.logger.log "debug", "it took #{Math.ceil( ((new Date())-start)/60000)} minutes to update folders"
    client.folderTree = folderTree
    setTimeout getAllFolders, 900000

    return null

  ).run()
getAllFolders()

getattr = (path, cb) ->
  logger.log('silly', "getattr #{path}")
  if client.folderTree.has(path)
    callback = (status, attr)->
      cb(status, attr)
    return client.folderTree.get(path).getAttr(callback)
  else
    return cb(-errnoMap.ENOENT)

readlink = (path,cb ) ->
  return cb(-errnoMap.ENOENT)

chmod = (path,mod, cb) ->
  return cb(0)

# /*
#  * Handler for the read() system call.
#  * path: the path to the file
#  * offset: the file offset to read from
#  * len: the number of bytes to read
#  * buf: the Buffer to write the data to
#  * fh:  the optional file handle originally returned by open(), or 0 if it wasn't
#  * cb: a callback of the form cb(err), where err is the Posix return code.
#  *     A positive value represents the number of bytes actually read.
#  */
read = (path, offset, len, buf, fh, cb) ->
  logger.log('silly', "reading file #{path} - (#{offset}-#{offset+len-1})")
  folderTree =  client.folderTree
  if folderTree.has(path)
    chunkStart = Math.floor((offset)/client.chunkSize) * client.chunkSize
    callback = (dataBuf,dataStart,dataEnd) ->
      try
        dataBuf.copy(buf,0,dataStart,dataEnd);
        p = "#{file.bitcasaBasename}-#{chunkStart}"
        client.logger.log "silly", "logging from read callback #{dataEnd-dataStart} -- #{  client.downloadTree.has(p)}"
        return cb(dataEnd-dataStart);
      catch error
        console.log("failed reading:", error)
    file = client.folderTree.get(path)
    file.download(offset, offset+len-1,callback)

  else
    return cb(-errnoMap.ENOENT)


init = (cb) ->
  logger.log('info', 'Starting fuse4js on BitcasaFuse4JS')
  # logger.log('info', "client token #{client.accessToken}")
  return cb(0)

open = (path, flags, cb) ->
  err = 0 # assume success
  folderTree =  client.folderTree
  logger.log('silly', "opening file #{path}, #{flags},  exists #{folderTree.has(path)}")
  if folderTree.has(path)
    return cb(0,null)
  else
    return cb(-errnoMap.ENOENT)# // we don't return a file handle, so fuse4js will initialize it to 0

flush = (buf, cb) ->
  logger.log("silly", "#{typeof buf}")
  return cb(0)

release =  (path, fh, cb) ->
  return cb(0)

statfs= (cb) ->
  return cb(0, {
        bsize: 262144,
        iosize: 262144,
        frsize: 65536,
        blocks: 1000000,
        bfree: 1000000,
        bavail: 1000000,
        files: 1000000,
        ffree: 1000000,
        favail: 1000000,
        fsid: 1000000,
        flag: 0,
        namemax: 64
    })

# /*
#  * Handler for the readdir() system call.
#  * path: the path to the file
#  * cb: a callback of the form cb(err, names), where err is the Posix return code
#  *     and names is the result in the form of an array of file names (when err === 0).
#  */
readdir = (path, cb) ->
  logger.log('silly', "reading dir #{path}")
  folderTree =  client.folderTree
  names = []

  if folderTree.has(path)
    object = folderTree.get(path)
    if object instanceof BitcasaFile
      err = -errnoMap.ENOTDIR
    else if object instanceof BitcasaFolder
      err = 0
      names = object.children
      if names.length == 0
        fn = ->
          client.getFolders( path )
        setTimeout(fn, 50)
    else
      err = -errnoMap.ENOENT
  else
    err = -errnoMap.ENOENT

  return cb( err, names );
destroy = (cb) ->
  return cb(0)

handlers =
  getattr: getattr,
  readdir: readdir,
  init: init,
  statfs: statfs
  # readlink: readlink,
  chmod: chmod,
  open:open,
  flush: flush
  read: read,
  # write: write,
  # release: release,
  # create: create,
  # unlink: unlink,
  # rename: rename,
  # mkdir: mkdir,
  # rmdir: rmdir,
  # init: init,
  destroy: destroy

try
  console.log 'attempting to start f4js'
  opts = switch os.type()
    when 'Linux' then  ["-o", "allow_other"]
    when 'Darwin' then  ["-o", "allow_other", "-o", "noappledouble", "-o", "daemon_timeout=0"]
    else []
  fs.ensureDirSync(config.mountPoint)
  f4js.start(config.mountPoint, handlers, false, opts);
  logger.log('info', "mount point: #{config.mountPoint}")
catch e
  console.log("Exception when starting file system: #{e}")
