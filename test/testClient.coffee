chai = require "chai"
winston = require 'winston'
expect = chai.expect
md5 = require 'MD5'
modules = require '../src/client.coffee'
config = require '../build/config.json'
fs = require 'fs'
BitcasaClient = modules.client


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
    client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken)
    it 'should restpect rate limits and get root with infinite drive', (done) ->
      expect(client.rateLimit.getTokensRemaining()).to.equal(180)
      client.getRoot ()->
        # console.log client.folderTree.get('/')
        expect(client.folderTree.get('/').children).to.include.members(['Bitcasa Infinite Drive'])
        done()
      expect(client.rateLimit.getTokensRemaining()).to.be.closeTo(179,0.5)
    it.skip 'should get folders', (done) ->
      client.getFolders done

    it 'should be able to download text files properly', (done)->
      callback = (buf, start,end) ->
        buffer = buf.slice(start,end)
        expect(end-start).to.equal(322)
        # expect( md5(buf.slice(start,end)) ).to.equal('599b9f55c2474fcea19e2147fe91e8ab')
        expect( md5(buf.slice(start,end)) ).to.equal('599b9f55c2474fcea19e2147fe91e8ab')
        done()
      client.download('/Yz_YeHx0RLqIXWEQo6V8Eg/Dp4K3RLQTW2ilY1lo81Iww','file.ext',0,321,322,false, callback)

    it 'should be able to download binary files properly', (done)->
      client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, logger, config.accessToken, 1024*1024*2)

      callback = (buf, start,end, data) ->
        newbuf = buf.slice( start,end)
        expect(end-start).to.equal(1378574)
        expect(newbuf.length).to.equal(1378574)
        expect( md5(newbuf) ).to.equal('4c898a28359a0aa8962adb0fc9661906')
        done()
      # file = '/tmp/node-bitcasa/file.ext-0-1378573'
      # if fs.existsSync(file)
      #   fs.unlink(file)
      client.download('/m__k6DI5SGOHivKQlBuqyw/NJgui8PDQa-v51BIW1Pj3Q','file.ext',0,1378573,1378574,false, callback)

    it 'should download large files properly', () ->
      buffer = new Buffer 69695838
      callback = (dataBuf, start, end)->
        data
      # client.download('/BqRTHzyOSm2PVYt02cTNCw/HzERXLW7TkOvT7ld8NF_mw')
describe 'FUSE filesystem', ->
  client = new BitcasaClient(config.clientId, config.secret, config.redirectUrl, config.accessToken, logger)
  it 'should return the right attribute', (done) ->
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
