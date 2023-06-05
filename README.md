# Oracle Swap
## An Oracle-based AMM with incentivized liquidity providing and arbitrage

The base contract was a fork of : https://github.com/pyth-network/pyth-crosschain/tree/main/target_chains/ethereum/examples/oracle_swap

The contract holds a pool of two ERC-20 tokens, the BASE and the QUOTE, and allows users to swap tokens for the pair BASE/QUOTE. For example, the base could be WETH and the quote could be USDC, in which case you can buy WETH for USDC and vice versa. The pool offers to swap between the tokens at the current Pyth exchange rate for BASE/QUOTE, which is computed from the BASE/USD price feed and the QUOTE/USD price feed.

Users can deposit tokens (both BASE and QUOTE) at a fixed ratio (which will be considered to be close to the token price) to the liquidity pool to allow the swap. As the price is external and do not depend of the contract, the pool can become unbalanced, which can lead to a non optimal efficiency for liquidity providers (e.g. must deposit a 20:1 ratio in the liquidity whereas the price is 2:1, which can lead to a lot of token completly unused and less liquidity deposited)

To fix the imbalance issue, there is an incentive to arbitrate between the pool price and the real price : if the pool price is imbalance (the difference with the real price exceeds a certain threshold), arbiters are allows to buy (or sell according to the imbalance side) directly on the contract liquidity pool to bring the pool price closer to the real price. The base oracle-based swap can remain open or not during an imbalance event at the wish of the operator. Finally, fees are taken for each swap to encourage the deposit of liquidity.
