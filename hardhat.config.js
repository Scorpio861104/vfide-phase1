require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: {
    version: "0.8.30",
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: "paris" }
  },
  mocha: { timeout: 120000 }
};
