# Night Shift 🌙

**Wall Street closes at 4pm. Night Shift doesn't.**

74% of Robinhood Stock Token volume happens while the NYSE is closed. With no live reference price, onchain pools drift: tokenized HIMS traded 112% above its NYSE close during one weekend. Nobody holds inventory to keep prices honest after hours.

Night Shift is a vault that runs the after-hours desk for stock tokens on Robinhood Chain.

## How it works

| When | What happens |
|---|---|
| **NYSE open** (Mon–Fri 9:30–16:00 ET) | LPs deposit USDG at NAV and receive `nsUSDG` shares. The desk is closed. |
| **NYSE closed** (nights, weekends, holidays) | Anyone can buy or sell stock tokens against the vault at **last Chainlink close ± spread**. When onchain pools drift, arbitrageurs trade with the desk and the spread goes to LPs. |
| **Any time** | LPs burn shares for a pro-rata slice of everything in the vault (USDG + stock tokens). |

Market hours, including US daylight saving time, are computed onchain. The owner can mark holidays.

## The agent can't steal

An AI agent tunes the desk, but the contract boxes it in:

- It can only **set the spread** (0.1%–10%) and **pause the desk**.
- Only the owner can unpause.
- **Neither the agent nor the owner can move vault funds.** No admin withdrawal exists. Assets leave only through desk trades or LP withdrawals.

## Hard limits (enforced in code)

- Per-stock exposure cap (max 30% of NAV)
- Max trade size
- Chainlink price older than 5 days is rejected
- New shares are locked for 24h, so nobody can deposit and instantly pull a stock basket at oracle price

## Risks

- **Weekend news gap:** the desk quotes Friday's close. If big news breaks on Saturday, traders can pick off the vault before Monday. Mitigations are the agent widening the spread or pausing, plus the exposure caps. LPs carry this risk.
- **USDG peg:** prices assume 1 USDG = $1.
- **Issuer controls:** Robinhood can freeze stock tokens, including ones held by the vault.
- **Not available to US persons:** stock tokens are restricted.

Testnet demo only. Not audited.

## Develop

```bash
forge build
forge test
forge coverage
```

## Deploy to Robinhood Chain testnet

Deploys mock USDG, mock TSLA/NVDA/AAPL and mock price feeds (open faucets, testnet only), then the vault with the deployer as owner and agent.

```bash
forge script script/DeployTestnet.s.sol --rpc-url https://rpc.testnet.chain.robinhood.com --private-key $PRIVATE_KEY --broadcast
```
