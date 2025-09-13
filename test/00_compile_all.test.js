const { expect } = require("chai");
const { ethers } = require("hardhat");

const CONTRACTS = [
  "contracts/phase1/VFIDEToken.sol:VFIDEToken",
  "contracts/phase1/VFIDEPresale.sol:VFIDEPresale",
  "contracts/phase1/ProofLedger.sol:ProofLedger",
  "contracts/phase1/SanctumFund.sol:SanctumFund"
];

describe("Compile all Phase-1 contracts (no deploy)", function () {
  for (const fqn of CONTRACTS) {
    it(`loads factory for ${fqn}`, async function () {
      const F = await ethers.getContractFactory(fqn);
      expect(F.interface).to.exist;
    });
  }
});
