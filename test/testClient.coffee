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
      new (winston.transports.Console)({ level: 'info' }),
    ]
  })


describe 'BitcasaClient instance', ->
  describe 'after creation', ->
    it 'default access token should be null', ->
      client = new BitcasaClient()
      expect(client).to.exist
      expect(client.accessToken).to.equal(null)

    it 'should have the right login url', ->
      client = new BitcasaClient config.clientId, config.secret, config.redirectUrl, logger,config.accessToken
      expect(client.loginUrl()).to.equal("https://developer.api.bitcasa.com/v1/oauth2/authenticate?client_id=#{config.clientId}&redirect_url=#{config.redirectUrl}")

  describe 'when in use', ->
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, 2*1024*1024)
    download = Future.wrap(client.download)
    it 'should restpect rate limits and get root with infinite drive', (done) ->
      expect(client.rateLimit.getTokensRemaining()).to.equal(175)
      client.getFolders "/", ->
        fn = ->
          expect(client.folderTree.get('/').children).to.include.members(['Bitcasa Infinite Drive'])
          done()
        setTimeout(fn,1500)
      expect(client.rateLimit.getTokensRemaining()).to.be.closeTo(174,0.5)

    it 'should be able to download text files properly', (done)->
      Fiber( ->
        client.downloadTree.set("Dp4K3RLQTW2ilY1lo81Iww-0",1)
        res = download(client,'/Yz_YeHx0RLqIXWEQo6V8Eg/Dp4K3RLQTW2ilY1lo81Iww','file.ext',0,321,322, true).wait()
        buffer = res.buffer.slice(start,end)
        start = res.start
        end = res.end
        expect(end-start).to.equal(322)
        expect( md5(buffer.slice(start,end)) ).to.equal('599b9f55c2474fcea19e2147fe91e8ab')
        done()
      ).run()
    it 'should be able to download binary files properly', (done)->        
      Fiber( ->
        client.downloadTree.set("NJgui8PDQa-v51BIW1Pj3Q-0",1)
        res = download(client,'/m__k6DI5SGOHivKQlBuqyw/NJgui8PDQa-v51BIW1Pj3Q','file.ext',0,1378573,1378574, true).wait()
        newbuf = res.buffer.slice( start,end)
        start = res.start
        end = res.end
        expect(end-start).to.equal(1378574)
        expect(newbuf.length).to.equal(1378574)
        expect( md5(newbuf) ).to.equal('4c898a28359a0aa8962adb0fc9661906')
        done()
      ).run()
    it 'should download large files properly', () ->
      buffer = new Buffer 69695838
      callback = (dataBuf, start, end)->
        data
      # client.download('/BqRTHzyOSm2PVYt02cTNCw/HzERXLW7TkOvT7ld8NF_mw')

    it 'should return the right attribute', (done) ->
      client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken, logger)
      cb = (err, status)->
        done()
      client.folderTree.get('/').getAttr(cb)

    it 'given the wrong attr lookup, it should fail',  ->
      client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken)
      cb = (err, status)->
        done()
      fn = ->
        client.folderTree.get('/..').getAttr(cb)
      expect(fn).to.throw( Error)
