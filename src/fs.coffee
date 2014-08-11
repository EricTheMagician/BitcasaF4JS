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
client.validateAccessToken (err, data) ->
  if err
    throw new Error("access token is not valid")
  client.loadFolderTree true


#get folder attributes in the background

#http://lxr.free-electrons.com/source/include/uapi/asm-generic/errno-base.h#L23
errnoMap =
    EPERM: 1,
    ENOENT: 2,
    EACCES: 13,
    ENOTDIR: 20,
    EINVAL: 22,
    ENOTEMPTY: 39


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
        bsize: 65536,
        iosize: 65536,
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
