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
logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'info' }),
      new (winston.transports.File)({ filename: '/tmp/somefile.log', level:'debug' })
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
  logger.log('silly', "reading file #{path}")
  folderTree =  client.folderTree
  if folderTree.has(path)
    file = client.folderTree.get(path)

    #check to see if part of the file is being downloaded or in use
    chunkStart = Math.floor((offset)/client.chunkSize) * client.chunkSize
    end = Math.min(offset + len - 1, file.size )
    chunkEnd = Math.min( Math.ceil(end/client.chunkSize) * client.chunkSize, file.size)-1 #and make sure that it's not bigger than the actual file
    if client.downloadTree.has("#{path}-#{chunkStart}")
      fn = ->
        read(path, offset, len, buf, fh, cb)
      setTimeout(fn, 20)
      return
    else
      client.downloadTree.set("#{path}-#{chunkStart}", 1)



    callback = (dataBuf,dataStart,dataEnd) ->

      try
        dataBuf.copy(buf,0,dataStart,dataEnd);
        cb(dataEnd-dataStart + 1);
        client.downloadTree.delete("#{path}-#{chunkStart}")
      catch error
        console.log("failed reading:", error)

    file.download(offset, offset+len-1,callback)


  else
    return cb(-errnoMap.ENOENT)


init = (cb) ->
  logger.log('info', 'Starting fuse4js on node-bitcasa')
  # logger.log('info', "client token #{client.accessToken}")
  cb(0)

open = (path, flags, cb) ->
  err = 0 # assume success
  folderTree =  client.folderTree
  logger.log('silly', "opening file #{path}, #{flags},  exists #{folderTree.has(path)}")
  if not folderTree.has(path)
    return cb(0,null)
  else
    return cb(-errnoMap.ENOENT)# // we don't return a file handle, so fuse4js will initialize it to 0

flush = (buf, cb) ->
  logger.log("silly", "#{typeof buf}")
  cb(0)

release =  (path, fh, cb) ->
  cb(0)

statfs= (cb) ->
  return cb(0, {
        bsize: config.chunkSize,
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

  cb( err, names );
destroy = (cb) ->
  cb(0)

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
    when 'Linux' then  ['-o', 'allow_other']
    when 'Darwin' then  ['-o', 'allow_other', '-o','daemon_timeout=300', '-o', 'noappledouble', '-s']
    else []
  f4js.start(config.mountPoint, handlers, false, opts);
  logger.log('info', "mount point: #{config.mountPoint}")
catch e
  console.log("Exception when starting file system: #{e}")
