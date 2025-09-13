const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ABI shape checks (no deploy)", function () {
  it("VFIDEToken exposes ERC20 functions", async function () {
    const F = await ethers.getContractFactory("contracts/phase1/VFIDEToken.sol:VFIDEToken");
    const I = F.interface;
    expect(I.getFunction("totalSupply")).to.exist;
    expect(I.getFunction("balanceOf")).to.exist;
    expect(I.getFunction("decimals")).to.exist;
    expect(I.getFunction("symbol")).to.exist;
    expect(I.getFunction("transfer")).to.exist;
    expect(I.getFunction("transferFrom")).to.exist;
    expect(I.getFunction("approve")).to.exist;
    expect(I.getFunction("allowance")).to.exist;
  });

  it("VFIDEPresale has a buy-like function", async function () {
    const F = await ethers.getContractFactory("contracts/phase1/VFIDEPresale.sol:VFIDEPresale");
    const I = F.interface;
    const names = ["buyWithUSDC", "buy", "purchase"];
    const hasBuy = names.some((n) => { try { return !!I.getFunction(n); } catch { return false; } });
    expect(hasBuy, "Presale must have buyWithUSDC/buy/purchase").to.equal(true);
  });

  it("ProofLedger exposes proofScoreOf", async function () {
    const F = await ethers.getContractFactory("contracts/phase1/ProofLedger.sol:ProofLedger");
    expect(F.interface.getFunction("proofScoreOf")).to.exist;
  });

  it("SanctumFund compiles", async function () {
    const F = await ethers.getContractFactory("contracts/phase1/SanctumFund.sol:SanctumFund");
    expect(F.interface).to.exist;
  });
});
