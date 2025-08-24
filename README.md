### Contract -> ST19K1EHHHDAXS6Z9SYP3006RFACGBEQSAS7NY4QF.GasLessSwap

# Gasless Swap DEX

A decentralized exchange (DEX) implementation on Stacks that enables gasless trading through meta-transactions, allowing users to trade tokens without needing to hold STX for gas fees.

## Overview

This smart contract implements an Automated Market Maker (AMM) DEX with the following key features:

- **Gasless Trading**: Users can execute swaps without paying gas fees by using meta-transactions with signature verification
- **Liquidity Pools**: Create and provide liquidity to token pairs to earn fees
- **SIP-010 Compliance**: Supports standard Stacks tokens implementing the SIP-010 trait
- **Constant Product Formula**: Uses x*y=k formula for pricing with 0.3% protocol fee

## How It Works

### Regular Swap (With Gas)
Users with STX can directly call the `swap` function to execute token swaps while paying their own gas fees.

### Gasless Swap (Meta-Transactions)
Users without STX can:
1. Create a signed message containing their swap parameters
2. Have a relayer submit the transaction on their behalf
3. The contract verifies the signature and executes the swap without the user needing STX

## Core Functions

### Adding Liquidity
```clarity
(add-liquidity token-a token-b amount-a-desired amount-b-desired amount-a-min amount-b-min)
```
Creates or adds to a liquidity pool, minting LP tokens proportional to the contribution.

### Removing Liquidity
```clarity
(remove-liquidity token-a token-b liquidity amount-a-min amount-b-min)
```
Withdraws tokens from a pool by burning LP tokens.

### Regular Swap
```clarity
(swap token-in token-out amount-in min-amount-out)
```
Executes a token swap with the caller paying gas fees.

### Gasless Swap
```clarity
(swap-tokens-for-tokens token-in token-out amount-in min-amount-out nonce signature public-key)
```
Executes a swap using meta-transactions with signature verification.

## View Functions

- `get-reserves`: Returns pool reserves for a token pair
- `get-balance`: Returns a user's LP token balance
- `get-amount-out`: Calculates output amount for a given input
- `is-nonce-used`: Checks if a nonce has been used for meta-transactions

## Error Codes

| Code | Error | Description |
|------|-------|-------------|
| u100 | ERR-NOT-AUTHORIZED | Caller not authorized |
| u101 | ERR-INVALID-NONCE | Invalid nonce provided |
| u102 | ERR-SLIPPAGE | Output amount below minimum |
| u103 | ERR-INSUFFICIENT-LIQUIDITY | Not enough liquidity |
| u104 | ERR-IDENTICAL-TOKENS | Cannot trade identical tokens |
| u105 | ERR-ZERO-AMOUNT | Zero amount provided |
| u106 | ERR-INSUFFICIENT-BALANCE | Insufficient user balance |
| u107 | ERR-POOL-EXISTS | Pool already exists |
| u108 | ERR-POOL-NOT-EXISTS | Pool doesn't exist |
| u109 | ERR-INVALID-SIGNATURE | Invalid signature provided |

## Events

- `swap-event`: Emitted on successful swaps
- `liquidity-event`: Emitted on liquidity additions/removals

## Technical Details

- **Fee Structure**: 0.3% protocol fee on swaps
- **Signature Scheme**: ECDSA with secp256k1
- **Pricing**: Constant product formula with fee adjustment
- **LP Tokens**: Represent share of pool using square root of product approximation

## Security Notes

- Nonces prevent replay attacks for meta-transactions
- Slippage protection ensures minimum output amounts
- Signature verification prevents unauthorized transactions
- Input validation protects against common attacks

## Usage Example

### Adding Liquidity
```clarity
(constract-call? .gasless-swap add-liquidity 
    token-a token-b 
    amount-a amount-b 
    min-amount-a min-amount-b)
```

### Gasless Swap
Users sign a message containing (nonce, amount-in, min-amount-out) and a relayer submits the transaction with their signature.

## Deployment

Deploy to Stacks mainnet or testnet using Clarinet or similar deployment tools. Ensure all token contracts implement the SIP-010 trait.

Deployed Block: https://explorer.hiro.so/txid/0xc0c77409ed4a8bac66511d2af8f6cd05f5b788e5c174cf4d2506c60fe8ccecf4?chain=testnet
Contract Address: ST19K1EHHHDAXS6Z9SYP3006RFACGBEQSAS7NY4QF.GasLessSwap
<img width="1919" height="862" alt="image" src="https://github.com/user-attachments/assets/752642e9-5f74-4635-8331-080bb5e4314a" />

