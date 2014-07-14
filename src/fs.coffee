config = require('./config.json')
f4js = require 'fuse4js'

BitcasaClient = module.exports.client

#bitcasa client
client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
#get folder attributes in the background
client.getFolders()

errnoMap =
    EPERM: 1,
    ENOENT: 2,
    EACCES: 13,
    EINVAL: 22,
    ENOTEMPTY: 39


getattr = (path, cb) ->
  folderTree =  client.folderTree
  if folderTree.has(path)
    return client.folderTree.get(path).getAttr(cb)
  else
    return cb(-2)
readdir = (path, cb) ->
  folderTree =  client.folderTree
  if folderTree.has(path)
    return cb(0,client.folderTree.get(path).children)
  else
    return cb(-2)

readlink = (path,cb ) ->
  return cb(-errnoMap.EACCES)

chmod = (path,mod, cb) ->
  return cb(-errnoMap.EACCES)

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
handlers =
  getattr: getattr,
  readdir: readdir,
  # readlink: readlink,
  # chmod: chmod,
  read: read,
  # write: write,
  # release: release,
  # create: create,
  # unlink: unlink,
  # rename: rename,
  # mkdir: mkdir,
  # rmdir: rmdir,
  # init: init,
  # destroy: destroy


console.log('mount point ', config.mountPoint)

try
  console.log 'attempting to start f4js'
  opts = ['-o', 'allow_other']
  # f4js.start(config.mountPoint, handlers, true,opts);
catch e
  console.log("Exception when starting file system: " + e);
