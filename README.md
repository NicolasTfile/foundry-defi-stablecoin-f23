# Foundry DeFi Stablecoin

A decentralized, algorithmic, exogenously collateralized stablecoin protocol built with Foundry. Users deposit WETH or WBTC as collateral and receive DSC (Decentralized Stable Coin), a token pegged to the US Dollar. The system is designed to always remain overcollateralized — the value of all collateral in the protocol will always exceed the total value of all DSC in circulation.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Core Contracts](#core-contracts)
- [Security](#security)
- [Testing](#testing)
- [Test Coverage](#test-coverage)
- [Getting Started](#getting-started)
- [Usage](#usage)
- [Acknowledgements](#acknowledgements)

---

## Overview

DSC is a stablecoin with the following properties:

- **Pegged to USD** — 1 DSC = $1.00
- **Exogenously collateralized** — backed by external assets (WETH and WBTC), not the protocol's own token
- **Algorithmically stable** — no centralized governance or manual intervention maintains the peg; the protocol enforces it through overcollateralization and liquidation logic
- **Overcollateralized** — the protocol enforces a minimum collateralization threshold at all times; users whose positions fall below the threshold can be liquidated

This design is inspired by MakerDAO's DAI but stripped of governance complexity, making it a clean, auditable reference implementation.

---

## How It Works

### Depositing Collateral and Minting DSC

Users deposit WETH or WBTC into the protocol as collateral. Based on the USD value of their collateral (sourced from Chainlink price feeds), they can mint up to a certain amount of DSC. The protocol enforces a **collateralization ratio of 200%**, meaning a user must hold at least $2 worth of collateral for every $1 of DSC they mint.

### Health Factor

Every position has a health factor — a numerical representation of how safely collateralized a user's position is. A health factor below 1 means the position is undercollateralized and eligible for liquidation.

```
Health Factor = (Collateral Value in USD × Liquidation Threshold) / Total DSC Minted
```

### Liquidation

If a user's health factor drops below the minimum threshold, any external actor can liquidate their position. The liquidator repays a portion of the user's DSC debt and receives the equivalent collateral plus a **10% liquidation bonus** as an incentive. This mechanism keeps the protocol solvent and the peg intact.

### Redeeming Collateral

Users can burn their DSC to retrieve their collateral at any time, provided their health factor remains above the minimum after the operation.

---

## Project Structure

```
foundry-defi-stablecoin-f23/
├── src/
│   ├── DSCEngine.sol                  # Core protocol logic
│   ├── DecentralizedStableCoin.sol    # ERC20 DSC token
│   └── libraries/
│       └── OracleLib.sol              # Chainlink oracle safety wrapper
├── script/
│   ├── DeployDSC.s.sol                # Deployment script
│   └── HelperConfig.s.sol             # Network configuration
├── test/
│   ├── fuzz/
│   │   └── Handler.t.sol              # Handler for invariant testing
│   └── mocks/
│       └── MockV3Aggregator.sol       # Mock Chainlink price feed
├── lib/                               # Dependencies
├── foundry.toml                       # Foundry configuration
└── README.md
```

---

## Core Contracts

### `DSCEngine.sol`

The heart of the protocol. It handles all core logic including:

- Collateral deposits and withdrawals (WETH and WBTC)
- DSC minting and burning
- Health factor calculation and enforcement
- Liquidation logic
- Integration with Chainlink price feeds via OracleLib

All functions that change state enforce a health factor check on exit via the `_revertIfHealthFactorIsBroken` internal function. This ensures no operation can leave a user's position undercollateralized.

### `DecentralizedStableCoin.sol`

An ERC20 token representing DSC. Minting and burning are controlled exclusively by `DSCEngine`, which is set as the owner on deployment. Users never interact with this contract directly.

### `OracleLib.sol`

A safety wrapper around Chainlink's `latestRoundData()`. Chainlink's native function does not revert if the oracle becomes stale — it silently returns outdated price data, which could allow users to mint DSC against artificially inflated collateral values.

`OracleLib` solves this by implementing `staleCheckLatestRoundData()`, which fetches the price feed data and reverts if the timestamp of the last update exceeds a defined staleness threshold (3 hours). Every price feed call in `DSCEngine` routes through this function instead of calling `latestRoundData()` directly.

```solidity
function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
    public
    view
    returns (uint80, int256, uint256, uint256, uint80)
{
    (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
    uint256 secondsSince = block.timestamp - updatedAt;
    if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();
    return priceFeed.latestRoundData();
}
```

---

## Security

Security was a first-class concern throughout development. The following measures were implemented:

**Oracle safety** — All price feed calls are wrapped in `OracleLib.staleCheckLatestRoundData()` to protect against stale or manipulated oracle data.

**Health factor enforcement** — Every state-changing function checks the caller's health factor after execution and reverts if it falls below the minimum. This is a defense-in-depth pattern that makes it impossible to leave the protocol in an invalid state through any single function call.

**Reentrancy protection** — The `nonReentrant` modifier from OpenZeppelin is applied to all functions that transfer tokens or ETH.

**CEI pattern** — All functions follow the Checks-Effects-Interactions pattern. State is updated before any external calls are made.

**Overcollateralization invariant** — The protocol is architecturally designed so that the total collateral value (in USD) must always exceed total DSC supply. This is enforced both at the contract level and verified through invariant testing (see below).

---

## Testing

This project implements a full testing suite covering three tiers: unit testing, stateless fuzz testing, and stateful fuzz testing (invariant testing).

### Unit Tests

Standard unit tests cover individual functions for both success cases and expected reverts. Tests are written using Foundry's `forge-std` library with `vm.prank`, `vm.expectRevert`, and `vm.expectEmit` cheatcodes.

### Stateless Fuzz Testing

Individual functions are tested with random, auto-generated inputs across hundreds of runs. This surfaces edge cases in boundary conditions and input validation that would never be caught by hand-written test cases — extreme amounts, zero values, type max values, and so on.

Example:
```solidity
function testFuzzDepositCollateral(uint256 amount) public {
    vm.assume(amount > 0 && amount <= 1000 ether);
    vm.startPrank(user);
    ERC20Mock(weth).approve(address(dscEngine), amount);
    dscEngine.depositCollateral(weth, amount);
    vm.stopPrank();
    assertEq(dscEngine.getCollateralBalanceOfUser(user, weth), amount);
}
```

### Stateful Fuzz Testing (Invariant Testing)

The most powerful tier of testing. Invariant tests define properties that must hold true regardless of the sequence of operations performed. Foundry's fuzzer then generates random sequences of function calls and checks these properties after every step.

The core invariant tested:

```
Total DSC supply must never exceed the total USD value of all collateral in the protocol
```

```solidity
function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
    uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

    uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
    uint256 wbtcValue = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

    assert(wethValue + wbtcValue >= totalSupply);
}
```

### Handler.t.sol

Raw invariant testing without constraints is noisy — the fuzzer will spend most of its runs calling functions with inputs that immediately revert (e.g. trying to mint DSC without any collateral deposited). This wastes runs and reduces coverage of meaningful execution paths.

`Handler.t.sol` solves this by acting as a middleware between the fuzzer and the protocol. The handler constrains the fuzzer to call functions in valid sequences with realistic inputs — depositing collateral before minting, using only supported collateral tokens, and so on. This allows `fail_on_revert = true` to be set in `foundry.toml`, meaning any unexpected revert is treated as a test failure, dramatically increasing signal quality.

```toml
[invariant]
runs = 128
depth = 128
fail_on_revert = true
```

---

## Test Coverage

```
| File                                | % Lines          | % Statements     | % Branches      | % Functions     |
| ----------------------------------- | ---------------- | ---------------- | --------------- | --------------- |
| src/DecentralizedStableCoin.sol     | 100.00% (14/14)  | 100.00% (13/13)  | 100.00% (4/4)   | 100.00% (2/2)   |
| src/libraries/OracleLib.sol         | 100.00% (6/6)    | 85.71% (6/7)     | 0.00% (0/1)     | 100.00% (1/1)   |
| test/fuzz/Handler.t.sol             | 97.92% (47/48)   | 98.08% (51/52)   | 83.33% (5/6)    | 100.00% (5/5)   |
| test/mocks/MockV3Aggregator.sol     | 52.17% (12/23)   | 52.94% (9/17)    | 100.00% (0/0)   | 50.00% (3/6)    |
| ----------------------------------- | ---------------- | ---------------- | --------------- | --------------- |
| Total                               | 90.46% (218/241) | 91.53% (216/236) | 64.00% (16/25)  | 90.57% (48/53)  |
```

All tests pass. Run coverage yourself with:

```bash
forge coverage
```

---

## Getting Started

### Prerequisites

- [Git](https://git-scm.com/)
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

Verify your installations:
```bash
git --version
forge --version
```

### Installation

```bash
git clone https://github.com/NicolasTfile/foundry-defi-stablecoin-f23
cd foundry-defi-stablecoin-f23
forge build
```

### Environment Setup

Create a `.env` file in the project root:

```env
PRIVATE_KEY=your_private_key_here
SEPOLIA_RPC_URL=your_sepolia_rpc_url_here
ETHERSCAN_API_KEY=your_etherscan_api_key_here
```

> ⚠️ Never use a wallet with real funds for development. Use a dedicated test wallet.

---

## Usage

### Run Tests

```bash
# Run all tests
forge test

# Run with verbose output
forge test -v

# Run a specific test file
forge test --match-path test/unit/DSCEngineTest.t.sol

# Run invariant tests only
forge test --match-path test/fuzz/Invariants.t.sol
```

### Check Coverage

```bash
forge coverage
```

### Deploy to Sepolia

```bash
forge script script/DeployDSC.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Interact with the Protocol (Sepolia)

Get WETH:
```bash
cast send <WETH_ADDRESS> "deposit()" \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Approve DSCEngine to spend WETH:
```bash
cast send <WETH_ADDRESS> "approve(address,uint256)" \
  <DSC_ENGINE_ADDRESS> 100000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Deposit collateral and mint DSC:
```bash
cast send <DSC_ENGINE_ADDRESS> "depositCollateralAndMintDsc(address,uint256,uint256)" \
  <WETH_ADDRESS> 100000000000000000 10000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## Acknowledgements

Built as part of the [Cyfrin Updraft Advanced Foundry course](https://updraft.cyfrin.io). Protocol design inspired by [MakerDAO](https://makerdao.com/) and the broader DeFi ecosystem.
