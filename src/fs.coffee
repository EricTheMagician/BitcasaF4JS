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
      timeout: 120000
  returned = false

  #if not done after 5 minutes, we have a problem
  callback = ->
    if not returned
      returned = true
      cb("taking to long to getFolder")
  timeout = setTimeout callback, 300000

  req = client.client.methods.getFolder args, (data, response) ->
    if not returned
      returned = true
      clearTimeout timeout
      cb(null, data)

  req.on 'error', (err) ->
    if not returned
      returned = true
      clearTimeout timeout
      cb(err)


getFolder = Future.wrap(_getFolder)
loadFolderTree = ->
  jsonFile =  "#{client.cacheLocation}/data/folderTree.json"
  if fs.existsSync(jsonFile)
    fs.readJson jsonFile, (err, data) ->
      for key in Object.keys(data)
        o = data[key]

        #get real path of parent
        parent = client.bitcasaTree.get(pth.dirname(o.path))
        realPath = pth.join(parent,o.name)

        #add child to parent folder
        parentFolder = client.folderTree.get parent

        if o.name not in parentFolder.children
          parentFolder.children.push o.name

        if o.size
          client.folderTree.set key, new BitcasaFile(client, o.path, o.name, o.size, new Date(o.ctime), new Date(o.mtime) )
        else
          # keep track of the conversion of bitcasa path to real path
          client.bitcasaTree.set o.path, realPath
          client.folderTree.set key, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date( o.mtime), [])
      getAllFolders()
  else
    getAllFolders()

saveFolderTree = ->
  toSave = {}
  client.folderTree.forEach (value, key) ->
    toSave[key] =
      name: value.name
      mtime: value.mtime.getTime()
      ctime: value.ctime.getTime()
      path: value.bitcasaPath

    if value instanceof BitcasaFile
      toSave[key].size = value.size
  fs.outputJson "#{client.cacheLocation}/data/folderTree.json", toSave, ->
    setTimeout getAllFolders, 30000

#this function will udpate all the folders content
getAllFolders = ->
  folders = [] #folders to scan
  parseLater = [] #sometimes, certain scans will fail, because the parent failed. add these later

  # get folders that should be
  client.folderTree.forEach (value, key) ->
    if value instanceof BitcasaFolder
      try
        length = value.bitcasaPath.match(/\//g).length
        if length  % 2 == 1
          folders.push value
        if length == 1 and value.name != '' #if not root, but "/Bitcasa Infinite Drive" for example
          folders.pop()
      catch error
        client.logger.log "error", "there was an error listing folder #{key}: #{value} -- #{error}"
  Fiber( ->
    fiber = Fiber.current
    fiberRun = ->
      fiber.run()
    start = new Date()

    while folders.length > 0
      processing = []
      client.logger.log  "silly", "folders length = #{folders.length}, processing length: #{processing.length}"
      tokens = Math.min(Math.floor(client.rateLimit.getTokensRemaining()/6), folders.length - processing.length)
      for i in [0...tokens]
        if not client.rateLimit.tryRemoveTokens(1)
          setTimeout fiberRun, 1000
          Fiber.yield()
        depth = 2
        processing.push getFolder(folders[i].bitcasaPath,depth )
      wait(processing)
      for i in [0...processing.length]
        client.logger.log "silly", "proccessing[#{i}] out of #{processing.length}"
        processingError = false
        try #catch socket connection error
          data = processing[i].wait()
        catch error
          client.logger.log("error", "there was a problem with connection for folder #{folders[i].name} - #{error}")
          processingError = true
          folders.push(folders[i])
        finally
          if processingError
            continue


        try
          result = JSON.parse(data)
        catch error
          folders.push(folders[i])
          client.logger.log "error", "there was a problem processing i=#{i}(#{folders[i].name}) - #{error} - folders length - #{folders.length} - data"
          client.logger.log "debug", "the bad data was: #{data}"
          processingError = true
        finally
          if processingError
            continue


        if result.error
          breakLoop = false
          switch result.error.code
            when 2002 #folder does not exist
              parent = client.bitcasaTree.get(pth.dirname(o.path))
              realPath = pth.join(parent,folders[i].name)
              client.folderTree.delete(realPath)
            when 9006
              client.logger.log "debug", "api rate limit reached while getting folders"
              setTimeout fiberRun, 61000
              Fiber.yield()
              for j in [i...processing.length]
                folders.push(folders[j])
              breakLoop = true
            else
              client.logger.log "error", "there was an error getting folder: #{result.error.code} - #{result.error.message}"

          if breakLoop
            break
          continue

        for o in result.result.items
          #get real path of parent
          parent = client.bitcasaTree.get(pth.dirname(o.path))

          #if the parent does not exist yet, parse later
          if parent == undefined
            parseLater.push o
            continue

          realPath = pth.join(parent,o.name)

          #add child to parent folder
          parentFolder = client.folderTree.get parent

          #if parent is undefined, parse later. sometimes, parent errored out while scanning.
          if parentFolder == undefined
            parseLater.push o
            continue

          if o.name not in parentFolder.children
            parentFolder.children.push o.name

          if o.category == 'folders'
            # keep track of the conversion of bitcasa path to real path
            client.bitcasaTree.set o.path, realPath
            existingFolder = client.folderTree.get(realPath)
            children = []
            if existingFolder != undefined
              children = existingFolder.children
            client.folderTree.set( realPath, new BitcasaFolder(client, o.path, o.name, new Date(o.ctime), new Date(o.mtime), children) )
          else
            client.folderTree.set realPath,    new BitcasaFile(client, o.path, o.name,o.size,  new Date(o.ctime), new Date(o.mtime))
      folders.splice 0, processing.length
      client.logger.log "debug", "folders length after splicing: #{folders.length}"
    client.logger.log "debug", "it took #{Math.ceil( ((new Date())-start)/60000)} minutes to update folders"
    BitcasaFolder.parseItems client, parseLater
    saveFolderTree()
    return null

  ).run()

loadFolderTree()


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
        client.logger.log( "error", "failed reading:", error)
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
  client.logger.log "info", 'attempting to start f4js'
  opts = switch os.type()
    when 'Linux' then  ["-o", "allow_other"]
    when 'Darwin' then  ["-o", "allow_other", "-o", "noappledouble", "-o", "daemon_timeout=0"]
    else []
  fs.ensureDirSync(config.mountPoint)
  f4js.start(config.mountPoint, handlers, false, opts);
  logger.log('info', "mount point: #{config.mountPoint}")
catch e
  client.logger.log( "error", "Exception when starting file system: #{e}")
