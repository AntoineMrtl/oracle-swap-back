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

  const pythAddress = "0xff1a0f4744e8582DF1aE09D5611b887B6a12925C";

  const Pyth = new web3.eth.Contract(PythABI, pythAddress);

  // Deploy mock BTC for testing

  const BTC = await ethers.getContractFactory("MockERC20");
  const btc = await BTC.deploy("Bitcoin", "BTC", 18, "1200000000000000000000");

  await btc.deployed();
  console.log("Mock BTC deployed : " + btc.address);

  await verify(btc.address, ["Bitcoin", "BTC", 18, "1200000000000000000000"]);

  // Deploy mock ETH for testing

  const ETH = await ethers.getContractFactory("MockERC20");
  const eth = await ETH.deploy("Ethereum", "ETH", 18, "1200000000000000000000");

  await eth.deployed();
  console.log("Mock ETH deployed : " + eth.address);

  await verify(eth.address, ["Ethereum", "ETH", 18, "1200000000000000000000"]);

  // Deploy oracle swap pool for BTC/ETH pair

  const OracleSwap = await ethers.getContractFactory("OracleSwap");
  const oracleSwap = await OracleSwap.deploy(
    pythAddress,
    priceIds[0],
    priceIds[1],
    btc.address,
    eth.address
  );

  await oracleSwap.deployed();
  console.log("Oracle Swap deployed : " + oracleSwap.address);

  await verify(oracleSwap.address, [
    pythAddress,
    priceIds[0],
    priceIds[1],
    btc.address,
    eth.address,
  ]);

  // Approve oracle swap contract

  var tx;

  tx = await btc.approve(
    oracleSwap.address,
    "99999999999999999999999999999999999999999"
  );
  await tx.wait();

  tx = await eth.approve(
    oracleSwap.address,
    "99999999999999999999999999999999999999999"
  );
  await tx.wait();

  console.log("Approve done");

  // Add liquidity

  tx = await oracleSwap.addLiquidity(
    "100000000000000000000",
    "100000000000000000000"
  );
  await tx.wait();

  console.log("Liquidity added");

  // Perform a swap (1 ETH => BTC)

  const priceUpdateData = await connection.getPriceFeedsUpdateData(priceIds);
  const fees = await Pyth.methods.getUpdateFee(priceUpdateData).call();

  tx = await oracleSwap.swap(true, "10000000000000000000", priceUpdateData, {
    value: fees,
  });
  await tx.wait();

  console.log("Swap done");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
/*
[
  "0x01000000000100528586eb2afdc8ced3cb02a6353db2535340cc336d8df0257f650a3b89bb21e04eebf1ac0bd0fb52e83b76c8403354d2f0b8323e5e7af09eb1d236c295593ce800647b563d00000000001aa27839d641b07743c0cb5f68c51f8cd31d2c0762bec00dc6fcd25433ef1ab5b6000000000400e93d0150325748000300010001020005009d1cdb1a5e1e3456d2977ee0d3d70765239f08a42855b9508fd479e15c6dc4d1feecf553770d9b10965f8fb64771e93f5690a182edc32be4a3236e0caaa6e0581a000000072b3a1d7f0000000001a6e646fffffff800000007292b040000000000017bcd4c01000000010000000200000000647b563d00000000647b563d00000000647b563b000000072b3a1d7f0000000001a6e64600000000647b563b6a20671c0e3f8cb219ce3f46e5ae096a4f2fdf936d2bd4da8925f70087d51dd830029479598797290e3638a1712c29bde2367d0eca794f778b25b5a472f192de00000002ad588b9e00000000007d0f1efffffff800000002ad2c8f30000000000096077501000000010000000200000000647b563d00000000647b563d00000000647b563b00000002ad588b9e00000000007d0f1e00000000647b563b28fe05d2708c6571182a7c9d1ff457a221b465edf5ea9af1373f9562d16b8d15f9c0172ba10dfa4d19088d94f5bf61d3b54d5bd7483a322a982e1373ee8ea31b000002794dc42ac00000000029b185e0fffffff80000027900ef9680000000002a1772ec01000000010000000200000000647b563d00000000647b563d00000000647b563b000002794dc42ac00000000029b185e000000000647b563b8b38db700e8b34640e681ec9a73e89608bda29415547a224f96585192b4b9dc794bce4aee88fdfa5b58d81090bd6b3784717fa6df85419d9f04433bb3d615d5c000000000513af700000000000016234fffffff800000000051617aa0000000000018bf101000000010000000200000000647b563d00000000647b563d00000000647b563b000000000513af70000000000001623400000000647b563b3b69a3cf075646c5fd8148b705b8107e61a1a253d5d8a84355dcb628b3f1d12031775e1d6897129e8a84eeba975778fb50015b88039e9bc140bbd839694ac0ae00000000006efa92000000000000153ffffffff800000000006ee5a600000000000016ff01000000010000000200000000647b563d00000000647b563d00000000647b563b00000000006efab200000000000016e600000000647b563b",
  "0x01000000000100af944c89ea885d61e527786015dff792f760dbdcb3ab2e30def736bd89a4364f7a419a29c77cc7cffaaf9e06b7cf0716fc08321695708892b67d489738aef57d01647b563d00000000001aa27839d641b07743c0cb5f68c51f8cd31d2c0762bec00dc6fcd25433ef1ab5b6000000000400e93e0150325748000300010001020005009d431cc2fd0ef4af4bc7c85fffae2f63d51b26d162179682d149ae619b1221c00bfc309467defa4b198c6b5bd59c08db4b9dfb27ddbcc32f31560f217b4ff8fc2b0000002c3cc30aec00000000092d2158fffffff80000002c41f5c9a000000000090d0ce401000000010000000200000000647b563d00000000647b563d00000000647b563b0000002c3cc30aec00000000092d215800000000647b563bf42aaf884c7b1454894170be0aaf1db39b4b78d3a56a27fd49bd8b39ef2c33d7651071f8c7ab2321b6bdd3bc79b94a50841a92a6e065f9e3b8b9926a8fb5a5d10000002ddd0ac980000000000a9c1080fffffff80000002de36f5a70000000000a27110c01000000010000000200000000647b563d00000000647b563d00000000647b563b0000002ddd126aa0000000000aa3b1a000000000647b563b1801eb03803af0244523ee2a86c3f27b126abe8904db4b45a82adb5fe21708b4ca80ba6dc32e08d06f1aa886011eed1d77c77be9eb761cc10d72b7d0a2fd57a60000002c46affe1f000000000383c4d9fffffff80000002c4d83d7580000000003af9c9c01000000010000000200000000647b563d00000000647b563d00000000647b563b0000002c46affe1f000000000383c4d900000000647b563b7ddf0d82af531f0af109d5e9ce9ec27ba9f00e9ee8ab71c912afffa16d715836b7abd25a76ddaffdf847224f03198ccb92723f90b2429cf33f0eecb96e352a860000002c3f49628500000000369e09e6fffffff80000002c454fb688000000001d57d8a801000000010000000200000000647b563d00000000647b563d00000000647b563b0000002c3f49628500000000369e09e600000000647b563bd5a5c2f30e06bd6f38e01c2c4c8cdd7ca7c1c12d47a7336e459fc6db4171bae660fd61b2d90eba47f281505a88869b66133d9dc58f203b019f5aa47f1b39343e0000002d2366ea1a0000000022b037f9fffffff80000002d21b4c3980000000022aefd9001000000010000000200000000647b563d000000006447fcf2000000006447fcf00000002d2366ea1a0000000022b037f9000000006447fcf2"
]
*/

const verify = async (contractAddress, args) => {
  console.log("Verifying contract...");
  try {
    await run("verify:verify", {
      address: contractAddress,
      constructorArguments: args,
    });
  } catch (e) {
    if (e.message.toLowerCase().includes("already verified")) {
      console.log("Already Verified!");
    } else {
      console.log(e);
    }
  }
};
