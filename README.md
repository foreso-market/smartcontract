# Prediction Market Contracts

Solidity contracts for a conditional-tokens prediction market: ERC-1155 outcome positions, off-chain order matching, on-chain settlement, oracle adapters, and Gnosis Safe proxy wallets.

## Stack

- Solidity `0.8.22` (core), `0.7.6` (Safe compatibility)
- [Hardhat](https://hardhat.org/)
- OpenZeppelin Contracts v5
- Gnosis Safe modules

## Layout

```
contracts/
  core/           ConditionalTokens, CTFExchange, MarketFactory
  adapters/       CTFAdapter
  mixins/         Trading, orders, fees, auth
  oracle/         UMA and AI optimistic oracle adapters
  safe/           Proxy wallet module and factory
  utility/        Disperse
  interfaces/
```

## Setup

```bash
npm install
npm run compile
```

Optional: create `.env` with `PRIVATE_KEY` and `RPC_URL` if you add deployment scripts later.

## License

MIT
