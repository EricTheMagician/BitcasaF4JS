#do this for mocha testing
if Object.keys( module.exports ).length == 0
  config = require('../build/test.config.json')
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
client.validateAccessToken (err, data) ->
  if err
    throw new Error("access token is not valid")
  client.loadFolderTree true


#get folder attributes in the background

#http://lxr.free-electrons.com/source/include/uapi/asm-generic/errno-base.h#L23
errnoMap =
    EPERM: 1,
    ENOENT: 2,
    EIO: 5,
    EACCES: 13,
    EEXIST: 17,
    ENOTDIR: 20,
    EISDIR: 21,
    EINVAL: 22,
    ESPIPE: 29,
    ENOTEMPTY: 39

#setup ipc for folder listing
ipc = require 'node-ipc'
ipc.config =
  appspace        : 'bitcasaf4js.',
  socketRoot      : '/tmp/',
  id              : "client",
  networkHost     : 'localhost',
  networkPort     : 8000,
  encoding        : 'utf8',
  silent          : true,
  maxConnections  : 100,
  retry           : 500,
  maxRetries      : 100,
  stopRetrying    : false

ipc.serve ->
  ipc.server.on 'ls:add', (data, socket) ->
    client.logger.log "debug", "ls:add", data

    #add object to parent's children array.
    parentPath = Bitcasa.convertReal(pth.dirname obj.path)
    parent = client.folderTree.get(parentPath)
    parent.children.push obj.name

    if data.size
      obj = new BitcasaFile(client, data.path, data.name, data.size, data.ctime, data.mtime, true)
    else
      obj = new BitcasaFolder(client, data.path, data.name, data.ctime, data.mtime,[], true)
    client.folderTree.set data.realPath, obj

  ipc.server.on 'ls:delete', (inData, socket) ->
    client.folderTree.remove inData

    #remove object from parent folder listing
    parent = client.folderTree.get pth.dirname inData
    name = pth.basename inData
    idx = parent.children.indexOf name
    parent.splice idx, 1
    client.logger.log "debug", "ls:delete", inData

ipc.server.start()

getattr = (path, cb) ->
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
  folderTree =  client.folderTree
  if folderTree.has(path)
    chunkStart = Math.floor((offset)/client.chunkSize) * client.chunkSize
    callback = (dataBuf,dataStart,dataEnd) ->
      try
        dataBuf.copy(buf,0,dataStart,dataEnd);
        return cb(dataEnd-dataStart);
      catch error
        client.logger.log( "error", "failed reading: #{error}")
        cb(-errnoMap.EIO)

    #make sure that we are only reading a file
    file = client.folderTree.get(path)
    if file instanceof BitcasaFile

      #make sure the offset request is not bigger than the file itself
      if offset < file.size
        file.download(offset, offset+len-1,true,callback)
      else
        cb(-errnoMap.ESPIPE)
    else
      cb(-errnoMap.EISDIR)

  else
    return cb(-errnoMap.ENOENT)


init = (cb) ->
  logger.log('info', 'Starting fuse4js on BitcasaFuse4JS')
  # logger.log('info', "client token #{client.accessToken}")
  return cb(0)

open = (path, flags, cb) ->
  err = 0 # assume success
  folderTree =  client.folderTree
  if folderTree.has(path)
    return cb(0,null)
  else
    return cb(-errnoMap.ENOENT)# // we don't return a file handle, so fuse4js will initialize it to 0

flush = (buf, cb) ->
  return cb(0)

release =  (path, fh, cb) ->
  return cb(0)

statfs= (cb) ->
  return cb(0, {
        bsize: Math.floor(config.chunkSize/2),
        iosize: Math.floor(config.chunkSize/2),
        frsize: Math.floor(config.chunkSize/2),
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
  folderTree =  client.folderTree
  names = []

  if folderTree.has(path)
    object = folderTree.get(path)
    if object instanceof BitcasaFile
      err = -errnoMap.ENOTDIR
    else if object instanceof BitcasaFolder
      err = 0
      names = object.children
    else
      err = -errnoMap.ENOENT
  else
    err = -errnoMap.ENOENT

  return cb( err, names );

#delete files and folder
unlink = (path, cb) ->
  object = client.folderTree.get path
  callback = (err,args) ->
    if err
      cb -errnoMap.ENOTEMPTY
    else
      cb 0

  if object == undefined
    cb -errnoMap.ENOENT
    return
  else if object instanceof BitcasaFile
    object.delete callbback
    return
  else if object instanceof BitcasaFolder
    object.delete callback
    return

mkdir = (path, mode, cb) ->
  callback = (err, args) ->
    if err
      cb -errnoMap.ENOENT
    else
      cb 0
  parent = pth.dirname path
  name = pth.basename path
  folder = client.folderTree.get parent
  if folder
    folder.createFolder name, callback
  else
    cb -errnoMap.ENOENT

rmdir = (path, cb) ->
  folder = client.folderTree.get path
  if folder
    if folder instanceof BitcasaFolder
      callback = (err, args) ->
        if err
          cb -errnoMap.EPERM
        else
          cb 0
      folder.delete callback
    else
      cb -errnoMap.ENOTDIR
  else
    cb -errnoMap.ENOENT

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
  unlink: unlink,
  # rename: rename,
  mkdir: mkdir,
  rmdir: rmdir,
  # init: init,
  destroy: destroy

try
  client.logger.log "info", 'attempting to start f4js'
  opts = switch os.type()
    when 'Linux' then  ["-o", "allow_other"]
    when 'Darwin' then  ["-o", "allow_other", "-o", "noappledouble", "-o", "daemon_timeout=0", '-o', 'noubc']
    else []
  fs.ensureDirSync(config.mountPoint)
  f4js.start(config.mountPoint, handlers, false, opts);
  logger.log('info', "mount point: #{config.mountPoint}")
catch e
  client.logger.log( "error", "Exception when starting file system: #{e}")
