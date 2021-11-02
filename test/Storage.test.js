const { expect } = require("chai")
const { ethers } = require("hardhat")
const { hashRequest, hashBid, sign } = require("./marketplace")
const { exampleRequest, exampleBid } = require("./examples")

describe("Storage", function () {

  const request = exampleRequest()
  const bid = exampleBid()

  let storage
  let token
  let client, host

  beforeEach(async function () {
    [client, host] = await ethers.getSigners()
    let Token = await ethers.getContractFactory("TestToken")
    let StorageContracts = await ethers.getContractFactory("Storage")
    token = await Token.connect(host).deploy()
    storage = await StorageContracts.deploy(token.address)
  })

  describe("creating a new storage contract", function () {

    let id

    beforeEach(async function () {
      await token.approve(storage.address, 20)
      await storage.connect(host).increaseStake(20)
      let requestHash = hashRequest(request)
      let bidHash = hashBid({...bid, requestHash})
      await storage.newContract(
        request.duration,
        request.size,
        request.contentHash,
        request.proofPeriod,
        request.proofTimeout,
        request.nonce,
        bid.price,
        await host.getAddress(),
        bid.bidExpiry,
        await sign(client, requestHash),
        await sign(host, bidHash)
      )
      id = bidHash
    })

    it("created the contract", async function () {
      expect(await storage.duration(id)).to.equal(request.duration)
      expect(await storage.size(id)).to.equal(request.size)
      expect(await storage.contentHash(id)).to.equal(request.contentHash)
      expect(await storage.price(id)).to.equal(bid.price)
      expect(await storage.host(id)).to.equal(await host.getAddress())
    })

    it("requires storage proofs", async function (){
      expect(await storage.proofPeriod(id)).to.equal(request.proofPeriod)
      expect(await storage.proofTimeout(id)).to.equal(request.proofTimeout)
    })
  })

  it("doesn't create contract when insufficient stake", async function () {
    let requestHash = hashRequest(request)
    let bidHash = hashBid({...bid, requestHash})
    await expect(storage.newContract(
      request.duration,
      request.size,
      request.contentHash,
      request.proofPeriod,
      request.proofTimeout,
      request.nonce,
      bid.price,
      await host.getAddress(),
      bid.bidExpiry,
      await sign(client, requestHash),
      await sign(host, bidHash)
    )).to.be.revertedWith("Insufficient stake")
  })
})

// TODO: configurable amount of stake
// TODO: lock up stake when new contract
// TODO: unlock stake at end of contract
// TODO: payment when new contract
// TODO: contract start and timeout
// TODO: failure to start contract burns host and client
// TODO: implement checking of actual proofs of storage, instead of dummy bool
// TODO: only allow proofs after start of contract
// TODO: proofs no longer required after contract duration
// TODO: payout
