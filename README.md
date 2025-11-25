# SlothLabs Smart Contracts

Smart contracts powering the SlothLabs ecosystem - a decentralized platform for dream creation, IP protection, crowdfunding, and staking.

## Overview

| Contract | Purpose |
|----------|---------|
| `DreamNFT` | ERC-721 NFTs with IP protection tiers and ERC-2981 royalties |
| `DreamMarketplace` | NFT marketplace with fixed price, auctions, and offers |
| `MilestoneCrowdfunding` | Crowdfunding with milestone-based fund release |
| `DreamsStaking` | Stake DREAMS tokens, earn USD-denominated rewards |
| `DreamsTreasurySale` | Buy DREAMS via DEX with treasury fee |
| `UniswapTwapOracle` | TWAP price oracle for DREAMS token |
| `ChainlinkPriceOracle` | Production price feeds from Chainlink |

## Quick Start

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests
npx hardhat test

# Run tests with gas reporting
REPORT_GAS=true npx hardhat test
```

## Test Results

```
197 passing
```

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed system documentation including:
- Contract relationships and dependencies
- Money flow diagrams
- Key constants reference
- Deployment checklist

## Project Structure

```
contracts/
├── DreamNFT.sol              # Core NFT contract
├── crowdfunding/
│   ├── MilestoneCrowdfunding.sol
│   ├── PriceOracle.sol       # Test oracle + ChainlinkPriceOracle
│   ├── SlothPriceOracle.sol  # Price router
│   └── UniswapTwapOracle.sol # TWAP oracle
├── marketplace/
│   └── DreamMarketplace.sol
├── staking/
│   └── DreamsStaking.sol
├── treasury/
│   └── DreamsTreasurySale.sol
├── token/
│   └── DreamsOFT.sol         # LayerZero OFT token
├── interfaces/               # Contract interfaces
├── libraries/                # Shared libraries
└── mocks/                    # Test mocks
```

## Chains

- **Base** (Primary)
- **Avalanche** (Secondary)

Cross-chain bridging via LayerZero OFT standard.

## Environment Setup

```bash
cp .env.example .env
# Edit .env with your values
```

Required variables:
- `PRIVATE_KEY` - Deployer wallet private key
- `BASE_RPC_URL` / `AVALANCHE_RPC_URL` - RPC endpoints
- `BASESCAN_API_KEY` / `SNOWTRACE_API_KEY` - For contract verification

## Deployment

```bash
# Deploy to Base
npx hardhat run scripts/deploy-base.js --network base

# Deploy to Avalanche
npx hardhat run scripts/deploy-avalanche.js --network avalanche

# Set up OFT peers for cross-chain
npx hardhat run scripts/set-oft-peers.js --network base
```

## Security

- All contracts use OpenZeppelin's audited libraries
- ReentrancyGuard on all state-changing functions
- Two-step admin transfers
- Flash loan protection via vote locking
- Price staleness checks on all oracles

## License

MIT

## Links

- [Architecture Documentation](./ARCHITECTURE.md)
- [Cross-Chain Plan](./docs/DREAMS_CROSSCHAIN_PLAN.md)
