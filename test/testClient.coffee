chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
modules = require '../src/client.coffee'
config = require '../build/config.json'
fs = require 'fs'
BitcasaClient = modules.client
Future = require('fibers/future')
Fiber = require 'fibers'
wait = Future.wait


logger = new (winston.Logger)({
    transports: [
      new (winston.transports.Console)({ level: 'debug' }),
    ]
  })


describe 'BitcasaClient', ->

  it 'should have the right login url', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, 2*1024*1024)
    expect(client.loginUrl()).to.equal("https://developer.api.bitcasa.com/v1/oauth2/authenticate?client_id=#{config.clientId}&redirect_url=#{config.redirectUrl}")

  it 'should fail to validate an invalid accesToken', (done) ->
    client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, logger, "#{config.accessToken}sadfasdfasdf1", config.chunkSize, config.advancedChunks, config.cacheLocation
    cb = (err, data) ->
      if err
        done()
      else
        done(data)
    client.validateAccessToken(cb)

  it 'should validate a valid accessToken', (done) ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)
    cb = (err, data) ->
      if err
        done()
      else
        err(data)
    client.validateAccessToken(cb)
  describe 'when in use', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, config.chunkSize, config.advancedChunks, config.cacheLocation)
    download = Future.wrap(client.download)
    #
    # it 'should be able to download text files properly', (done)->
    #   Fiber( ->
    #     res = download(client,'/Yz_YeHx0RLqIXWEQo6V8Eg/Dp4K3RLQTW2ilY1lo81Iww','file.ext',0,321,322, true).wait()
    #     buffer = res.buffer.slice(start,end)
    #     start = res.start
    #     end = res.end
    #     expect(end-start).to.equal(322)
    #     expect( md5(buffer.slice(start,end)) ).to.equal('599b9f55c2474fcea19e2147fe91e8ab')
    #     done()
    #   ).run()
    # it 'should be able to download binary files properly', (done)->
    #   Fiber( ->
    #     res = download(client,'/m__k6DI5SGOHivKQlBuqyw/NJgui8PDQa-v51BIW1Pj3Q','file.ext',0,1378573,1378574, true).wait()
    #     newbuf = res.buffer.slice( start,end)
    #     start = res.start
    #     end = res.end
    #     expect(end-start).to.equal(1378574)
    #     expect(newbuf.length).to.equal(1378574)
    #     expect( md5(newbuf) ).to.equal('4c898a28359a0aa8962adb0fc9661906')
    #     done()
    #   ).run()
    # it 'should download large files properly', () ->
    #   buffer = new Buffer 69695838
    #   callback = (dataBuf, start, end)->
    #     data
    #   # client.download('/BqRTHzyOSm2PVYt02cTNCw/HzERXLW7TkOvT7ld8NF_mw')
