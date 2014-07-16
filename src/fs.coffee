config = require('./config.json')
f4js = require 'fuse4js'
winston = require 'winston'
BitcasaClient = module.exports.client

#bitcasa client
client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
#get folder attributes in the background
client.getFolders()
logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'debug' }),
      new (winston.transports.File)({ filename: '/tmp/somefile.log', level:'debug' })
    ]
  })
errnoMap =
    EPERM: 1,
    ENOENT: 2,
    EACCES: 13,
    EINVAL: 22,
    ENOTEMPTY: 39


getattr = (path, cb) ->
  logger.log('debug', "getattr #{path}")
  folderTree =  client.folderTree
  if folderTree.has(path)
    callback = (status, attr)->
      logger.log('debug', "attr size: #{attr.size}")
      logger.log('debug', "attr mtime: #{attr.mtime}")
      cb(status, attr)
    return client.folderTree.get(path).getAttr(callback)
  else
    return cb(-errnoMap.ENOENT)
readdir = (path, cb) ->
  logger.log('debug', "readdir #{path}")
  client.getFolders path
  folderTree =  client.folderTree
  if folderTree.has(path)
    return cb(0,client.folderTree.get(path).children)
  else
    return cb(-errnoMap.ENOENT)

readlink = (path,cb ) ->
  return cb(-errnoMap.ENOENT)

chmod = (path,mod, cb) ->
  return cb(-errnoMap.ENOENT)

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
  logger.log('debug', "reading file #{path}, offset #{offset}")
  folderTree =  client.folderTree
  if folderTree.has(path)
    callback = (dataBuf,dataStart,dataEnd)->
      dataBuf.copy(buf,0,dataStart,dataEnd);
      cb(dataEnd-dataStart+1);

    client.folderTree.get(path).download(offset, offset+len,true, callback)


  else
    return cb(-errnoMap.ENOENT)


init = (cb) ->
  logger.log('info', 'Starting fuse4js on node-bitcasa')
  # logger.log('info', "client token #{client.accessToken}")
  cb()

statfs= (cb) ->
    cb(0, {
        bsize: 1000000,
        frsize: 1000000,
        blocks: 1000000,
        bfree: 1000000,
        bavail: 1000000,
        files: 1000000,
        ffree: 1000000,
        favail: 1000000,
        fsid: 1000000,
        flag: 1000000,
        namemax: 1000000
    })

handlers =
  getattr: getattr,
  readdir: readdir,
  init: init,
  statfs: statfs
  readlink: readlink,
  chmod: chmod,
  open:open,
  # read: read,
  # write: write,
  # release: release,
  # create: create,
  # unlink: unlink,
  # rename: rename,
  # mkdir: mkdir,
  # rmdir: rmdir,
  # init: init,
  # destroy: destroy

try
  console.log 'attempting to start f4js'
  opts = ['-o', 'allow_other']
  f4js.start(config.mountPoint, handlers, true,opts);
  logger.log('debug', "mount point: #{config.mountPoint}")
catch e
  console.log("Exception when starting file system: #{e}")
