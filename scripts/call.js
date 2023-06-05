const { ethers, network } = require("hardhat");
require("@nomicfoundation/hardhat-toolbox");
const Web3 = require("web3");
const { EvmPriceServiceConnection } = require("@pythnetwork/pyth-evm-js");
const fs = require("fs");
const path = require("path");

const web3 = new Web3(
  new Web3.providers.HttpProvider("https://api.avax-test.network/ext/bc/C/rpc")
);

const connection = new EvmPriceServiceConnection(
  "https://xc-testnet.pyth.network"
);

// Set price ids (here btc and eth for testing)

const priceIds = [
  "0xf9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b", // BTC/USD
  "0x651071f8c7ab2321b6bdd3bc79b94a50841a92a6e065f9e3b8b9926a8fb5a5d1", // ETH/USD
];

const PythABI = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, "IPyth.json"))
);

// https://docs.pyth.network/pythnet-price-feeds/evm#networks

async function main() {
  // Get price update data

  const oracleSwapAddress = "0x6AFd864C3C5EAa77c61D56517C03F062940A2dD5";
  const pythAddress = "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C";

  const priceFeedsUpdateData = await connection.getPriceFeedsUpdateData(
    priceIds
  );

  const OracleSwap = await hre.ethers.getContractAt(
    "OracleSwap",
    oracleSwapAddress
  );

  const Pyth = new web3.eth.Contract(PythABI, pythAddress);
  const fees = await Pyth.methods.getUpdateFee(priceFeedsUpdateData).call();

  const result = await OracleSwap.arbitrate(
    "10000000000000000000",
    priceFeedsUpdateData,
    {
      value: fees,
    }
  );
  /*
  const result = await OracleSwap.swap(
    true,
    "10000000000000000000",
    priceFeedsUpdateData,
    {
      value: fees,
    }
  );
  */

  console.log(result);
}

main();
