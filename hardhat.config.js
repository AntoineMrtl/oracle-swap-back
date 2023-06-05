require("@nomicfoundation/hardhat-toolbox");

module.exports = {
  solidity: "0.8.0",
  networks: {
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      accounts: ["XXX"],
      chainId: 43113,
      blockConfirmations: 6,
    },
  },
  etherscan: {
    apiKey: "CVTGX2EYNZ3RUNJ2J87QFIYZTB6K7APU75",
  },
};
