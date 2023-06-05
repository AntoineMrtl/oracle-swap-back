// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Oracle-based AMM with incentivized liquidity providing and arbitrage
//
// The base contract was a fork of : https://github.com/pyth-network/pyth-crosschain/tree/main/target_chains/ethereum/examples/oracle_swap
//
// The contract holds a pool of two ERC-20 tokens, the BASE and the QUOTE, and allows users to swap tokens
// for the pair BASE/QUOTE. For example, the base could be WETH and the quote could be USDC, in which case you can
// buy WETH for USDC and vice versa. The pool offers to swap between the tokens at the current Pyth exchange rate for
// BASE/QUOTE, which is computed from the BASE/USD price feed and the QUOTE/USD price feed.
//
// Users can deposit tokens (both BASE and QUOTE) at a fixed ratio (which will be considered to be close to the token price) to the liquidity pool to allow the swap.
// As the price is external and do not depend of the contract, the pool can become unbalanced, which can lead to a non optimal efficiency for liquidity providers (e.g. must deposit a 20:1 ratio in the liquidity whereas the price is 2:1,
// which can lead to a lot of token completly unused and less liquidity deposited)
// To fix the imbalance issue, there is an incentive to arbitrate between the pool price and the real price : if the pool price is imbalance (the difference with the real price exceeds a certain threshold), arbiters are allows to buy (or sell according
// to the imbalance side) directly on the contract liquidity pool to bring the pool price closer to the real price. The base oracle-based swap can remain open or not during an imbalance event at the wish of the operator.
// Finally, fees are taken for each swap to encourage the deposit of liquidity.

contract OracleSwap {
    event Transfer(address from, address to, uint amountUsd, uint amountWei);

    IPyth pyth;

    bytes32 baseTokenPriceId;
    bytes32 quoteTokenPriceId;

    ERC20 public baseToken;
    ERC20 public quoteToken;

    uint public constant DECIMALS = 10e8;
    int public constant intDECIMALS = 10e8; // save gas
    uint public constant FEES = (95 * DECIMALS) / 100; // Liquidity providers fees
    uint public constant IMBALANCE_THRESHOLD = (10 * DECIMALS) / 100; // At which percentage offset between pool price and real price the contract consider an imbalanced pool

    uint public totalLiquidityOwned;

    bool public authorizeSwapWhenImbalance; // Is the oracle's price swap is authorized in imbalance period ?

    mapping(address => uint) public liquidityOwned; // Liquidity pool amount owned for each liquidity provider (based on base token amount)

    constructor(
        address _pyth,
        bytes32 _baseTokenPriceId,
        bytes32 _quoteTokenPriceId,
        address _baseToken,
        address _quoteToken
    ) {
        pyth = IPyth(_pyth);
        baseTokenPriceId = _baseTokenPriceId;
        quoteTokenPriceId = _quoteTokenPriceId;
        baseToken = ERC20(_baseToken);
        quoteToken = ERC20(_quoteToken);

        authorizeSwapWhenImbalance = true;
    }

    // Buy or sell a quantity of the base token. `size` represents the quantity of the base token with the same number
    // of decimals as expected by its ERC-20 implementation. If `isBuy` is true, the contract will send the caller
    // `size` base tokens; if false, `size` base tokens will be transferred from the caller to the contract. Some
    // number of quote tokens will be transferred in the opposite direction; the exact number will be determined by
    // the current pyth price. The transaction will fail if either the pool or the sender does not have enough of the
    // requisite tokens for these transfers.
    //
    // `pythUpdateData` is the binary pyth price update data (retrieved from Pyth's price
    // service); this data should contain a price update for both the base and quote price feeds.
    // See the frontend code for an example of how to retrieve this data and pass it to this function.
    function swap(
        bool isBuy,
        uint size,
        bytes[] calldata pythUpdateData
    ) external payable {
        // Retreive the prices of the two pool's assets
        (uint basePrice, uint quotePrice) = getAssetsPrices(pythUpdateData);

        // Check if the oracles's price swap is authorized
        if (!authorizeSwapWhenImbalance)
            require(
                isImbalanced(basePrice, quotePrice) == 0,
                "Swap at oracle's price is not authorized because of imbalanced pool"
            );

        // This computation loses precision. The infinite-precision result is between [quoteSize, quoteSize + 1]
        // We need to round this result in favor of the contract.
        uint256 quoteSize = (size * basePrice) / quotePrice;

        // TODO: use confidence interval

        if (isBuy) {
            // Transfer to the user his amount with the fees (the fees stay in the pool so the liquidity providers' tokens owned increase)
            uint amountWithFees = (size * FEES) / DECIMALS;
            require(amountWithFees < baseBalance(), "Insufficient liquidity");

            // (Round up)
            quoteSize += 1;

            quoteToken.transferFrom(msg.sender, address(this), quoteSize);
            baseToken.transfer(msg.sender, amountWithFees);
        } else {
            // Transfer to the user his amount with the fees (the fees stay in the pool so the liquidity providers' tokens owned increase)
            uint amountWithFees = (quoteSize * FEES) / DECIMALS;
            require(amountWithFees < quoteBalance(), "Insufficient liquidity");

            baseToken.transferFrom(msg.sender, address(this), size);
            quoteToken.transfer(msg.sender, amountWithFees);
        }
    }

    // Arbitrate the reserves of the pool to bring the pool price closer to the real feed price so the liquidity is at optimum efficiency (e.g. there isn't 10 times more of token A than of token B whereas the price is 1:1 - here there would be a lot of token A unused)
    // Note: when the imbalance between the two prices is too high, this function allows a buy or a sell (depending the sign of the difference) directly to the pool price so the keeper can sell (or buy) at the real price in the market and make a profit
    function arbitrate(
        uint tokenAmount,
        bytes[] calldata pythUpdateData
    ) external payable {
        (uint basePrice, uint quotePrice) = getAssetsPrices(pythUpdateData);

        uint imbalanced = isImbalanced(basePrice, quotePrice);
        require(imbalanced != 0, "Pool must be imbalanced to arbitrate");

        uint reserve0 = baseBalance();
        uint reserve1 = quoteBalance();

        if (imbalanced == 1) {
            baseToken.transferFrom(msg.sender, address(this), tokenAmount);
            quoteToken.transfer(
                msg.sender,
                getAmountOut(tokenAmount, reserve0, reserve1)
            );

            // We need to check that the arbitrage doesn't imbalance is the other side the pool
            require(
                isImbalanced(basePrice, quotePrice) != 2,
                "Arbitrage have too much price impact"
            );
        } else {
            quoteToken.transferFrom(msg.sender, address(this), tokenAmount);
            baseToken.transfer(
                msg.sender,
                getAmountOut(tokenAmount, reserve1, reserve0)
            );

            // We need to check that the arbitrage doesn't imbalance is the other side the pool
            require(
                isImbalanced(basePrice, quotePrice) != 1,
                "Arbitrage have too much price impact"
            );
        }
    }

    // Add liquidity to the pool
    // Note: if there is no liquidity, both liquidityBaseToken and liquidityQuoteToken must be superior to 0 because the liquidity is initialized
    // else, exactly one of the two must be equal to 0, and will be calculated according to the other one value.
    function addLiquidity(
        uint liquidityBaseToken,
        uint liquidityQuoteToken
    ) external {
        uint _poolPrice = poolPrice();

        // if there is no liquidity, initialize the pool
        if (_poolPrice == 0) {
            _createLiquidity(liquidityBaseToken, liquidityQuoteToken); // if there is no liquidity, initialize the pool
            return;
        }

        // else, simply add liquidity to the existing one

        // retreive the right liquidity amounts
        (liquidityBaseToken, liquidityQuoteToken) = getLiquidityToAdd(
            liquidityBaseToken,
            liquidityQuoteToken,
            _poolPrice
        );

        // now we have both liquidity base and quote token amounts that fit with the current pool reserve ratio, we can add them.
        // poolPrice (before adding liquidity) is then equal to poolPrice (after adding liquidity)
        baseToken.transferFrom(msg.sender, address(this), liquidityBaseToken);
        quoteToken.transferFrom(msg.sender, address(this), liquidityQuoteToken);

        liquidityOwned[msg.sender] += liquidityBaseToken;
        totalLiquidityOwned += liquidityBaseToken;
    }

    // Remove liquidity from the pool
    // Note: share is the percentage the user want to remove (in fixed percentage 1-100)
    function removeLiquidity(uint percentage) external {
        require(percentage > 0 && percentage <= 100, "Wronge percentage");

        uint liquidityShareToRemove = (getPoolShare(msg.sender) * percentage) /
            100;

        uint baseTokenAmount = (liquidityShareToRemove * baseBalance()) /
            DECIMALS;
        uint quoteTokenAmount = (liquidityShareToRemove * quoteBalance()) /
            DECIMALS;

        baseToken.transfer(msg.sender, baseTokenAmount);
        quoteToken.transfer(msg.sender, quoteTokenAmount);

        liquidityOwned[msg.sender] = percentage == 100
            ? 0
            : liquidityOwned[msg.sender] - baseTokenAmount;

        totalLiquidityOwned -= baseTokenAmount;
    }

    // Create the base liquidity, with a base token amount and a quote token amount which will define the pool price
    function _createLiquidity(
        uint liquidityBaseToken,
        uint liquidityQuoteToken
    ) private {
        require(
            liquidityBaseToken > 0 && liquidityQuoteToken > 0,
            "Invalid liquidity amounts"
        );

        baseToken.transferFrom(msg.sender, address(this), liquidityBaseToken);
        quoteToken.transferFrom(msg.sender, address(this), liquidityQuoteToken);

        liquidityOwned[msg.sender] = liquidityBaseToken;
        totalLiquidityOwned = liquidityBaseToken;
    }

    // Return if there is an imbalance between the pool price (proportion of pool reserves) and the real asset price
    // Note: Return 0 for no imbalance, 1 for pool price too high and 2 for pool price too low
    function isImbalanced(
        uint basePrice,
        uint quotePrice
    ) public view returns (uint) {
        uint targetPrice = ((basePrice * DECIMALS) / quotePrice); // Compute the real price of the pair

        int delta = (int(poolPrice()) - int(targetPrice)) * intDECIMALS;
        uint spread = delta > 0
            ? uint(delta) / targetPrice
            : uint(-delta) / targetPrice;

        if (spread >= IMBALANCE_THRESHOLD) {
            return delta > 0 ? 1 : 2;
        }
        return 0;
    }

    // Get the pool share percentage (with DECIMALS precision)
    function getPoolShare(address provider) public view returns (uint) {
        return (liquidityOwned[provider] * DECIMALS) / totalLiquidityOwned;
    }

    // Retreive both assets price from pyth price feed
    function getAssetsPrices(
        bytes[] calldata pythUpdateData
    ) public payable returns (uint basePrice, uint quotePrice) {
        uint updateFee = pyth.getUpdateFee(pythUpdateData);
        pyth.updatePriceFeeds{value: updateFee}(pythUpdateData);

        PythStructs.Price memory currentBasePrice = pyth.getPrice(
            baseTokenPriceId
        );
        PythStructs.Price memory currentQuotePrice = pyth.getPrice(
            quoteTokenPriceId
        );

        // Note: this code does all arithmetic with 18 decimal points. This approach should be fine for most
        // price feeds, which typically have ~8 decimals. You can check the exponent on the price feed to ensure
        // this doesn't lose precision.
        basePrice = convertToUint(currentBasePrice, 18);
        quotePrice = convertToUint(currentQuotePrice, 18);
    }

    // Return the pool price (with DECIMALS precision)
    // Return 0 if the pool doesn't have any liquidity
    function poolPrice() public view returns (uint) {
        uint _baseBalance = baseBalance();
        return
            _baseBalance != 0 ? (quoteBalance() * DECIMALS) / _baseBalance : 0;
    }

    // (from uniswap v2 library) - given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    function getAmountOut(
        uint amountIn,
        uint reserveIn,
        uint reserveOut
    ) public pure returns (uint amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        uint amountInWithFee = amountIn * FEES;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * DECIMALS) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function getLiquidityToAdd(
        uint liquidityBaseToken,
        uint liquidityQuoteToken,
        uint _poolPrice
    ) internal pure returns (uint, uint) {
        if (liquidityBaseToken > 0 && liquidityQuoteToken == 0) {
            // if base token amount is not null, compute quote token liquidity amount
            liquidityQuoteToken = (liquidityBaseToken * _poolPrice) / DECIMALS;
        } else if (liquidityBaseToken == 0 && liquidityQuoteToken > 0) {
            // if quote token amount is not null, compute base token liquidity amount
            liquidityBaseToken = (liquidityQuoteToken * DECIMALS) / _poolPrice;
        } else {
            revert("Invalid liquidity amounts");
        }
        return (liquidityBaseToken, liquidityQuoteToken);
    }

    // TODO: we should probably move something like this into the solidity sdk
    function convertToUint(
        PythStructs.Price memory price,
        uint8 targetDecimals
    ) private pure returns (uint256) {
        if (price.price < 0 || price.expo > 0 || price.expo < -255) {
            revert();
        }

        uint8 priceDecimals = uint8(uint32(-1 * price.expo));

        if (targetDecimals - priceDecimals >= 0) {
            return
                uint(uint64(price.price)) *
                10 ** uint32(targetDecimals - priceDecimals);
        } else {
            return
                uint(uint64(price.price)) /
                10 ** uint32(priceDecimals - targetDecimals);
        }
    }

    // Get the number of base tokens in the pool
    function baseBalance() public view returns (uint256) {
        return baseToken.balanceOf(address(this));
    }

    // Get the number of quote tokens in the pool
    function quoteBalance() public view returns (uint256) {
        return quoteToken.balanceOf(address(this));
    }

    // Send all tokens in the oracle AMM pool to the caller of this method.
    // (This function is for demo purposes only. You wouldn't include this on a real contract.)
    function withdrawAll() external {
        baseToken.transfer(msg.sender, baseToken.balanceOf(address(this)));
        quoteToken.transfer(msg.sender, quoteToken.balanceOf(address(this)));
    }

    // Reinitialize the parameters of this contract.
    // (This function is for demo purposes only. You wouldn't include this on a real contract.)
    function reinitialize(
        bytes32 _baseTokenPriceId,
        bytes32 _quoteTokenPriceId,
        address _baseToken,
        address _quoteToken
    ) external {
        baseTokenPriceId = _baseTokenPriceId;
        quoteTokenPriceId = _quoteTokenPriceId;
        baseToken = ERC20(_baseToken);
        quoteToken = ERC20(_quoteToken);
    }

    // Set if the swap at oracle's price is authorized when the pool is unbalanced
    // (This function is for demo purposes only. You wouldn't include this on a real contract.)
    function setAuthorizeSwapWhenImbalance(bool authorized) external {
        authorizeSwapWhenImbalance = authorized;
    }

    receive() external payable {}
}
