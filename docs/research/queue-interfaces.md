# Withdrawal-queue interfaces: verified research notes

Research date: 2026-10-29 (chain time checked: Ethereum block 26298497, `block.timestamp` ~1793277947, about 12:45 UTC).

How things were verified:
- **Source**: verified contract source pulled from the Blockscout v2 API (`https://eth.blockscout.com/api/v2/smart-contracts/<addr>`). Blockscout mirrors Etherscan/Sourcify verification. The Etherscan v2 API needs a key; a keyless call returned `"Missing/Invalid API Key"`, so it wasn't used. Where noted, that source was diffed byte-for-byte against the protocol's official GitHub repo.
- **Live state**: `cast call` / raw `curl` JSON-RPC against `https://ethereum-rpc.publicnode.com`, `https://base-rpc.publicnode.com`, and the publicnode Hoodi, Sepolia and Base Sepolia endpoints.
- Anything marked **[INFERENCE]** is my reading, not stated in source or docs. Anything marked **[UNVERIFIED]** I could not confirm.

---

## 0. Public RPC check

| RPC | Result |
|---|---|
| `https://ethereum-rpc.publicnode.com` | OK. `eth_blockNumber` -> `0x191487f` (26,298,495) |
| `https://base-rpc.publicnode.com` | OK. `eth_chainId` -> `0x2105` (8453) |
| `https://ethereum-hoodi-rpc.publicnode.com` | OK. chainId 560048 |
| `https://ethereum-sepolia-rpc.publicnode.com` | OK. chainId 11155111 |
| `https://base-sepolia-rpc.publicnode.com` | OK. chainId 84532 |

Raw `eth_call` results (Ethereum mainnet, `latest`, 2026-10-29 ~12:48 UTC):

```
# Lido WithdrawalQueueERC721 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1
getLastRequestId()            selector 0x19c2b4c3
{"jsonrpc":"2.0","id":1,"result":"0x00000000000000000000000000000000000000000000000000000000000222ef"}   # = 140015

getLastFinalizedRequestId()   selector 0x4f069a13
{"jsonrpc":"2.0","id":1,"result":"0x00000000000000000000000000000000000000000000000000000000000222e3"}   # = 140003

# Ethena StakedUSDeV2 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497
cooldownDuration()            selector 0x35269315
{"jsonrpc":"2.0","id":1,"result":"0x0000000000000000000000000000000000000000000000000000000000015180"}   # = 86400 s = 1 day
```

---

## 1. Lido WithdrawalQueueERC721 (unstETH NFT)

### Addresses

| Network | WithdrawalQueueERC721 (proxy) | Implementation | Status |
|---|---|---|---|
| Ethereum mainnet | `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1` | `0xE42C659Dc09109566720EA8b2De186c2Be7D94D9` (EIP-1967 slot read live) | Live. `LidoLocator.withdrawalQueue()` returns this address |
| Hoodi (560048) | `0xfe56573178f1bcdf53F01A6E9977670dcBBD9186` | `0xd0a60e52837e045f4567193cf8921191c486ecd5` (live slot read; docs table lists `0x83BCE68B...` elsewhere, so check before relying on it) | **Primary, active Lido testnet** per docs. Live: lastRequestId=5478, lastFinalized=5476, not paused. Hoodi `LidoLocator` `0xe2EF9536DAAAEBFf5b1c130957AB3E80056b06D8` -> `withdrawalQueue()` returns this address |
| Sepolia | `0x1583C7b3f4C3B008720E6BcE5726336b0aB25fdd` | n/a | Docs say **"fully deprecated"**. Live: lastRequestId=0, `isPaused()=true`. Not usable |
| Holesky | `0xc7cc160b58F8Bb0baC94b80847E2CF2800565C50` | n/a | Docs say **"fully deprecated"** |

Related mainnet addresses (from docs, confirmed live through `LidoLocator 0xC1d0b3DE6792Bf6b4b37EccdcC24e45978Cfd2Eb`):
- stETH / Lido: `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84` (also `WithdrawalQueue.STETH()`)
- AccountingOracle (proxy): `0x852deD011285fe67063a08005c71a85690503Cee`. Impl `0xe4f03D1107d1905B6F2A28FCb6Af221E0CE19136`, contractVersion 5, consensusVersion 6
- HashConsensus for AccountingOracle: `0xD624B08C83bAECF0807Dd2c6880C3154a5F0B288` (`AccountingOracle.getConsensusContract()` returns this live; `getReportProcessor()` returns the AccountingOracle)
- OracleReportSanityChecker: `0x147f8d3cf3004FAf9Bf94E88B54b6C06De507be9`
- Docs list the mainnet protocol version as `v4.1.0`.

Hoodi equivalents: AccountingOracle `0xcb883B1bD0a41512b42D2dB267F2A2cd919FB216`, HashConsensus `0x32EC59a78abaca3f91527aeB2008925D5AaC1eFC` (frame = 225 epochs, confirmed live).

### Source verification
Verified source of the mainnet implementation `0xE42C...94D9`: contract `WithdrawalQueueERC721`, solc `0.8.9+commit.e5eed63a`. Its `WithdrawalQueueBase.sol`, `WithdrawalQueue.sol` and `WithdrawalQueueERC721.sol` are **byte-identical** to `lidofinance/core` branch `master`, `contracts/0.8.9/`. `getContractVersion()` returns 1.

### Verified interface (exact signatures from source)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILidoWithdrawalQueueERC721 {
    // from WithdrawalQueueBase.sol (exact struct, field order matters for ABI decoding)
    struct WithdrawalRequestStatus {
        uint256 amountOfStETH;   // stETH locked for THIS request (not cumulative)
        uint256 amountOfShares;  // shares locked for THIS request
        address owner;           // can claim / transfer
        uint256 timestamp;       // block.timestamp at request creation
        bool    isFinalized;     // requestId <= getLastFinalizedRequestId()
        bool    isClaimed;       // claimable iff isFinalized && !isClaimed
    }

    // WithdrawalQueueBase
    function getLastRequestId() external view returns (uint256);           // 0 if none; ids start at 1
    function getLastFinalizedRequestId() external view returns (uint256);  // 0 if none
    function getLockedEtherAmount() external view returns (uint256);
    function getLastCheckpointIndex() external view returns (uint256);
    function unfinalizedRequestNumber() external view returns (uint256);   // lastRequestId - lastFinalizedRequestId
    function unfinalizedStETH() external view returns (uint256);
    function MAX_BATCHES_LENGTH() external view returns (uint256);          // public constant = 36

    // WithdrawalQueue
    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestsIds); // unbounded; view-only use
    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external view returns (WithdrawalRequestStatus[] memory statuses);
    function getClaimableEther(uint256[] calldata _requestIds, uint256[] calldata _hints)
        external view returns (uint256[] memory claimableEthValues);       // 0 if not finalized or claimed
    function findCheckpointHints(uint256[] calldata _requestIds, uint256 _firstIndex, uint256 _lastIndex)
        external view returns (uint256[] memory hintIds);                  // ids must be sorted asc; _firstIndex >= 1
    function isBunkerModeActive() external view returns (bool);
    function bunkerModeSinceTimestamp() external view returns (uint256);   // type(uint256).max when bunker is off
    function STETH() external view returns (address);
    function WSTETH() external view returns (address);                     // [UNVERIFIED getter name; immutable present in source]
    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256); // live: 100
    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256); // live: 1000e18
    function getContractVersion() external view returns (uint256);

    // PausableUntil (contracts/0.8.9/utils/PausableUntil.sol)
    function isPaused() external view returns (bool);                      // block.timestamp < resumeSince
    function getResumeSinceTimestamp() external view returns (uint256);
    function PAUSE_INFINITELY() external view returns (uint256);            // type(uint256).max

    // WithdrawalQueueERC721 (ERC-721 surface)
    function ownerOf(uint256 _requestId) external view returns (address);   // reverts if id==0, id>last, or claimed
    function balanceOf(address _owner) external view returns (uint256);
    function supportsInterface(bytes4 interfaceId) external view returns (bool); // 0x80ac58cd -> true (live)
    function name() external view returns (string memory);                  // "Lido: stETH Withdrawal NFT"
}
```

Errors worth decoding in an adapter (selectors computed with `cast sig`):
- `InvalidRequestId(uint256)` = `0xc969e0f2`. Thrown by `getWithdrawalStatus` / `ownerOf` for id 0 or id > lastRequestId. Confirmed live: calling with 140016 reverted with `0xc969e0f2...222f0`.
- `RequestAlreadyClaimed(uint256)` = `0xf0e0cc2d`. Thrown by `ownerOf` once a request is claimed.

Live sample (`getWithdrawalStatus([140003,140004,140015])`):
```
(199999925871094330296, 160332899999999999999, 0xdd647CE113505b34c62412d2A804cE1bfBCFc737, 1793266283, true,  false)
(20000000000000000,     16033295942653412,     0x09Fe61730Fa2dD980D0F2982c30bccA2BBD7Cb75, 1793268083, false, false)
(600000000000000000,    480969310383325501,    0xd6a245820E69A92fC528289FbE4088422963eC88, 1793277947, false, false)
```
Other live values: `unfinalizedStETH()` = 205577197572206903965 (~205.58 stETH), `unfinalizedRequestNumber()` = 12, `isPaused()` = false, `isBunkerModeActive()` = false, `getLastCheckpointIndex()` = 1263, `getLockedEtherAmount()` = 32069263151057183471482.

### Cumulative stETH / "queued ahead" data
- Storage holds `struct WithdrawalRequest { uint128 cumulativeStETH; uint128 cumulativeShares; address owner; uint40 timestamp; bool claimed; uint40 reportTimestamp; }` in `mapping(uint256 => WithdrawalRequest)` at the unstructured slot `keccak256("lido.WithdrawalQueue.queue")`.
- **No public getter exposes `cumulativeStETH`, `cumulativeShares` or the per-request queue struct.** The queue mapping is `internal`, accessed via `_getQueue()`. Checkpoints (`fromRequestId`, `maxShareRate`) are also internal. The only public outputs are `getLastCheckpointIndex()` and `findCheckpointHints()`.
- `unfinalizedStETH()` is the only cumulative-derived getter. It returns `queue[last].cumulativeStETH - queue[lastFinalized].cumulativeStETH`, which is the **total** unfinalized stETH, not the amount ahead of N.
- So, to get stETH queued ahead of request N (N > lastFinalized) on-chain, sum `getWithdrawalStatus([lastFinalized+1 .. N-1]).amountOfStETH`. That takes one external call with an array. It is O(N - lastFinalized), bounded by `unfinalizedRequestNumber()` (12 right now). You can also compute `unfinalizedStETH() - sum(statuses[N..last])` from the other side. **[INFERENCE]** Off-chain you could use `eth_getStorageAt` on `keccak256(abi.encode(N, keccak256("lido.WithdrawalQueue.queue")))` to read the cumulative fields directly. A Solidity adapter can't do that (no `extsload` on this contract).

### Ownership
- `WithdrawalRequestStatus.owner`, equivalently `ownerOf(requestId)`, is the address that can claim or transfer. Ownership changes on ERC-721 transfer.
- `ownerOf` **reverts** for claimed requests. `getWithdrawalStatus` does not; it returns `isClaimed=true` and the last owner. Prefer `getWithdrawalStatus` in an adapter that shouldn't revert.
- `getWithdrawalRequests(owner)` returns the owner's unclaimed request ids (EnumerableSet). The source warns its cost is unbounded.

### Finalization timing
How it works (from source):
1. Requests are finalized only by the AccountingOracle report. `AccountingOracle` calls `withdrawalQueue.onOracleReport(isBunker, bunkerStart, _getSlotTimestamp(data.refSlot))` and then `Accounting.handleOracleReport(...)`, which finalizes up to the last id in `withdrawalFinalizationBatches`.
2. Reports happen once per HashConsensus **frame**. Mainnet live values:
   - `HashConsensus.getChainConfig()` -> `(slotsPerEpoch=32, secondsPerSlot=12, genesisTime=1606824023)`
   - `HashConsensus.getFrameConfig()` -> `(initialEpoch=201600, epochsPerFrame=225, fastLaneLengthSlots=100)`. 225 epochs x 32 x 12 s = **86400 s = 1 day**.
   - `HashConsensus.getCurrentFrame()` -> `(refSlot=15537599, reportProcessingDeadlineSlot=15544799)`
   - `AccountingOracle.getLastProcessingRefSlot()` -> `15537599`. That equals the current refSlot, so this frame's report is already processed.
   - refSlot timestamps = `genesisTime + refSlot*12`. Current refSlot 15537599 is 2026-10-29 12:00:11 UTC. The next frame refSlot is 15544799 (current + 7200), which is 2026-10-30 12:00:11 UTC.
3. Sanity-checker margin: `OracleReportSanityChecker._checkLastFinalizableId` reverts unless `reportTimestamp >= request.timestamp + requestTimestampMargin`. Here `reportTimestamp` is the refSlot timestamp. Live `getOracleReportLimits().requestTimestampMargin` (field index 9 of the 16-field `LimitsList` in the deployed source) = **7680 s (2 h 8 min)**.
4. Finalization also depends on available ETH (buffer, withdrawal vault, EL rewards, validator exits) and on bunker mode. **No on-chain value gives an upper bound on when a request will be finalized.**

**[INFERENCE] Earliest-possible lower bound** an adapter can compute:
- Find the first frame refSlot `R` with `genesisTime + R*12 >= request.timestamp + requestTimestampMargin`, and `R > getLastProcessingRefSlot()`.
- Frame refSlots are `getCurrentFrame().refSlot + k * epochsPerFrame * slotsPerEpoch`.
- Finalization cannot happen before the report for `R` is submitted, which is some time after `R`'s timestamp.
- This is a lower bound only; there is no latest bound.

Signatures (from `lidofinance/core` master, `contracts/0.8.9/oracle/HashConsensus.sol` and `BaseOracle.sol`, `contracts/0.8.9/sanity_checks/OracleReportSanityChecker.sol`):
```solidity
interface IHashConsensus {
    function getChainConfig() external view returns (uint256 slotsPerEpoch, uint256 secondsPerSlot, uint256 genesisTime);
    function getFrameConfig() external view returns (uint256 initialEpoch, uint256 epochsPerFrame, uint256 fastLaneLengthSlots);
    function getCurrentFrame() external view returns (uint256 refSlot, uint256 reportProcessingDeadlineSlot);
    function getInitialRefSlot() external view returns (uint256);   // live: 6451199
    function getReportProcessor() external view returns (address);
}
interface IBaseOracle { // AccountingOracle
    function getConsensusContract() external view returns (address);
    function getLastProcessingRefSlot() external view returns (uint256);
    function getConsensusReport() external view returns (bytes32 hash, uint256 refSlot, uint256 processingDeadlineTime, bool processingStarted);
        // [UNVERIFIED] 4th return name/type; only the first 3 were read from source
    function SECONDS_PER_SLOT() external view returns (uint256); // live 12
    function GENESIS_TIME() external view returns (uint256);     // live 1606824023
}
// OracleReportSanityChecker.getOracleReportLimits() returns LimitsList (16 uint256 fields in the deployed version;
// requestTimestampMargin is index 9). Field order differs between versions: decode against the deployed source.
```
Note: the HashConsensus/BaseOracle signatures above come from GitHub master. Calling them live with these exact signatures returned sensible values, but I did **not** diff the deployed HashConsensus source against GitHub.

### Lido off-chain estimate API (wq-api)
Base URL `https://wq-api.lido.fi`. OpenAPI JSON is at `https://wq-api.lido.fi/api-json`, Swagger UI at `https://wq-api.lido.fi/api`. Endpoints: `/v1/request-time`, `/v2/request-time`, `/v2/request-time/calculate`, `/v1/nft/{tokenId}`, `/v1/nft/{tokenId}/image`, `/v1/estimate-gas`, `/v1/validators-info`.

- `GET /v2/request-time?ids=140015&ids=140004` returns an array of `RequestTimeByRequestIdDto`:
  ```json
  [{"requestInfo":{"requestId":"140015","requestedAt":"2026-10-29T12:45:47.000Z","finalizationIn":85193669,
    "finalizationAt":"2026-10-30T12:30:23.000Z","type":"buffer"},
    "status":"calculated","nextCalculationAt":"2026-10-29T12:55:00.167Z"}, ...]
  ```
  - `finalizationIn` is in milliseconds.
  - `type` is one of `buffer | bunker | vaultsBalance | rewardsOnly | validatorBalances | requestTimestampMargin | exitValidators`.
  - `status` is one of `initializing | calculating | finalized | calculated`.
- `GET /v2/request-time/calculate?amount=1` returns `{"requestInfo":{"finalizationIn":..,"finalizationAt":..,"type":..},"status":..,"nextCalculationAt":..}`.
- `GET /v1/request-time?amount=` (legacy) returns `{"days":3,"stethLastUpdate":..,"validatorsLastUpdate":..,"steth":"205577197572206903965","requests":12,"status":"calculated"}`.
- Optional header `WQ-Request-Source: widget|sdk|unknown`.
- No Hoodi wq-api host was found. `wq-api.hoodi.testnet.fi` did not resolve.

The live estimate (2026-10-30 12:30 UTC) is consistent with the next refSlot (12:00:11 UTC) plus report-submission latency.

Sources:
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/WithdrawalQueueBase.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/WithdrawalQueue.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/WithdrawalQueueERC721.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/utils/PausableUntil.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/oracle/HashConsensus.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/oracle/AccountingOracle.sol
- https://github.com/lidofinance/core/blob/master/contracts/0.8.9/sanity_checks/OracleReportSanityChecker.sol
- https://docs.lido.fi/deployed-contracts/ (source: https://github.com/lidofinance/docs/blob/main/docs/deployed-contracts/index.md), `/hoodi`, `/sepolia`, `/holesky`
- https://etherscan.io/address/0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1#code (verified source fetched via Blockscout: https://eth.blockscout.com/address/0xE42C659Dc09109566720EA8b2De186c2Be7D94D9)
- https://wq-api.lido.fi/api-json

---

## 2. Ethena StakedUSDeV2 (sUSDe)

### Addresses (Ethereum mainnet)
- sUSDe `StakedUSDeV2`: `0x9D39A5DE30e57443BfF2A8307A4256c8797A3497`. **Not a proxy** (EIP-1967 impl slot is zero).
- USDe (asset): `0x4c9EDD5852cd905f086C759E8383e09bff1E68B3` (live `asset()`)
- USDeSilo: `0x7FC7c91D556B400AFa565013E3F32055a0713425` (live `silo()`; also linked in Ethena docs)

Verified source: Blockscout reports `StakedUSDeV2`, solc `0.8.19+commit.7dd6d404`, `contracts/StakedUSDeV2.sol`. The same files are in `ethena-labs/code4arena-contest/protocols/USDe/contracts/`. I didn't diff those byte-for-byte; the snippets below come from the **deployed verified source**.

### Verified interface (exact)
```solidity
// contracts/interfaces/IStakedUSDeCooldown.sol (deployed source)
struct UserCooldown {
    uint104 cooldownEnd;        // unix timestamp
    uint152 underlyingAmount;   // USDe held in silo for this user
}

interface IStakedUSDeV2 /* is IERC4626 */ {
    // public state getters in StakedUSDeV2.sol
    function cooldowns(address) external view returns (uint104 cooldownEnd, uint152 underlyingAmount); // mapping(address => UserCooldown) public
    function silo() external view returns (address);              // USDeSilo public immutable
    function MAX_COOLDOWN_DURATION() external view returns (uint24); // 90 days = 7776000
    function cooldownDuration() external view returns (uint24);

    function cooldownAssets(uint256 assets) external returns (uint256 shares);  // ensureCooldownOn
    function cooldownShares(uint256 shares) external returns (uint256 assets);  // ensureCooldownOn
    function unstake(address receiver) external;
    function setCooldownDuration(uint24 duration) external;       // DEFAULT_ADMIN_ROLE only

    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);
    error InvalidCooldown();
    error ExcessiveRedeemAmount();
    error ExcessiveWithdrawAmount();
}

// contracts/USDeSilo.sol
interface IUSDeSilo {
    function withdraw(address to, uint256 amount) external; // onlyStakingVault
}
```
Selectors: `cooldownDuration()` = `0x35269315`, `cooldownShares(uint256)` = `0x9343d9e1`, `cooldownAssets(uint256)` = `0xcdac52ed`.

### Semantics (from source)
- One aggregate cooldown per address, keyed by `msg.sender`, which is the share owner. There is no request id. Each `cooldownShares`/`cooldownAssets` call **adds** to `underlyingAmount` and **resets** `cooldownEnd = block.timestamp + cooldownDuration` for the whole accumulated amount.
- The USDe amount is fixed at cooldown time: assets are transferred into the silo, so later yield doesn't accrue.
- `unstake(receiver)` succeeds when `block.timestamp >= cooldownEnd || cooldownDuration == 0`. It withdraws the full `underlyingAmount` and zeroes the struct. There is no partial unstake.
- Adapter state mapping **[INFERENCE]**:
  - `underlyingAmount == 0` means none.
  - `now < cooldownEnd && cooldownDuration != 0` means pending.
  - Otherwise claimable. Earliest equals latest claim time, which is `cooldownEnd`.
  - There is no "amount queued ahead"; the cooldown is per-user and time-based.
- **Can cooldown be 0?** Yes. `setCooldownDuration` accepts 0..90 days. When it is 0, `withdraw`/`redeem` (ERC-4626) are enabled (`ensureCooldownOff`), `cooldownShares`/`cooldownAssets` revert with `OperationNotAllowed`, and redeems are synchronous. Existing silo balances become claimable immediately through `unstake`. When it is greater than 0, `withdraw`/`redeem` revert.
- **Current value (live)**: `cooldownDuration()` = **86400 (1 day)**.
  - Ethena docs ("Staking Key Functions") only say the admin can set it "up to a maximum value of 90 days" and don't state a current number. The 1-day value comes from chain only.
  - Constructor default was `MAX_COOLDOWN_DURATION`.
- Live sample: tx `0xce782cdc...33d6` (`cooldownShares`) from `0xBa07E4628214fBc9EB7353E671088A3b3f0B5e7A`, then `cooldowns(...)` returned `(cooldownEnd=1793364023, underlyingAmount=162239452273777610743)`. That's about now + 86400.

### Testnet
- Ethena docs ("Testnet") list only **USDe** on Sepolia: `0x9458caaca74249abbe9e964b3ce155b98ec88ef2` (live `symbol()` = "USDe").
- They recommend testing against a mainnet fork (Anvil/Tenderly).
- **[UNVERIFIED] No official Sepolia sUSDe address found.** Use an Anvil fork of mainnet.

Sources:
- https://etherscan.io/address/0x9d39a5de30e57443bff2a8307a4256c8797a3497#code (verified source fetched via https://eth.blockscout.com/api/v2/smart-contracts/0x9D39A5DE30e57443BfF2A8307A4256c8797A3497)
- https://github.com/ethena-labs/code4arena-contest/tree/main/protocols/USDe/contracts
- https://docs.ethena.fi/solution-design/key-addresses
- https://docs.ethena.fi/technical-design/staking-usde/staking-key-functions
- https://docs.ethena.fi/resources/testnet

---

## 3. Live ERC-7540 async vaults (Ethereum / Base)

### ERC-7540 interface IDs (computed with `cast sig` XOR; match EIP-7540 text)
- `IERC7540Operator` = `0xe3bc4e65` (`setOperator`, `isOperator`)
- `IERC7540Deposit` = `0xce3bbe50`
- `IERC7540Redeem` = `0x620ee8e4`
- `IERC7575` = `0x2f0a18c5`

Solidity `type(I).interfaceId` excludes inherited functions, which is why Redeem's ID doesn't include Operator's functions.

```solidity
// Exact, from Centrifuge verified source src/misc/interfaces/IERC7540.sol (matches EIP-7540)
interface IERC7540Redeem /* is IERC7540Operator */ {
    event RedeemRequest(address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 pendingShares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 claimableShares);
}
interface IERC7540Deposit /* is IERC7540Operator */ {
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 pendingAssets);
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 claimableAssets);
    function deposit(uint256 assets, address receiver, address controller) external returns (uint256 shares);
    function mint(uint256 shares, address receiver, address controller) external returns (uint256 assets);
}
// Centrifuge also implements ERC-7887 cancel:
//   function pendingCancelRedeemRequest(uint256 requestId, address controller) external view returns (bool isPending);
//   function claimableCancelRedeemRequest(uint256 requestId, address controller) external view returns (uint256 claimableShares);
```
Topic0 of `RedeemRequest(address,address,uint256,address,uint256)` = `0x1fdc681a13d8c5da54e301c7ce6542dcde4581e4725043fdab2db12ddc574506`.

### Centrifuge V3: requestId is always 0
Source: verified `AsyncVault` (solc 0.8.28) at `0xfe6920eb...` (Blockscout), file `src/vaults/BaseVaults.sol`:
- `uint256 internal constant REQUEST_ID = 0;` `requestRedeem`/`requestDeposit` return `REQUEST_ID` and emit it.
- `pendingRedeemRequest(uint256, address controller)` **ignores** the requestId and returns `asyncRedeemManager.pendingRedeemRequest(this, controller)`.
- `claimableRedeemRequest(uint256, address controller)` ignores the requestId and returns `maxRedeem(controller)`.
- Live: `pendingRedeemRequest(1, x)` returns the same as id 0 and doesn't revert.

So state is one aggregate per (vault, controller). Fulfilment is epoch-based through the Hub/BatchRequestManager. **[INFERENCE] There is no on-chain claimable-time estimate and no queue position.**

Centrifuge V3 core (same addresses on Ethereum and Base, from `centrifuge/protocol` branch `live`, `env/ethereum.json` / `env/base.json`):
- `asyncRequestManager` `0xF48256AbDDf96EcDDc4B3DbD23E8C1921f9761Ae`. Every vault below returns this from `asyncRedeemManager()`.
- `spoke` `0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB`
- `vaultRegistry` `0xd9531AC47928c3386346f82d9A2478960bf2CA7B`
- `asyncVaultFactory` `0x55cde53B7dbc24336E34FFE233AF8DF10f72F0Be`
- `syncDepositVaultFactory` `0xdb9C27762045Addd713182521C0580C68BDF700A`
- `root` `0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f`

Vault list from the Centrifuge indexer `https://api.centrifuge.io` (GraphQL `vaults(where:{status: Linked})`). Every row below was then checked live with `share()`, `asset()`, `poolId()`, `scId()`, `supportsInterface`, and `pendingRedeemRequest`/`claimableRedeemRequest(0, 0x…dEaD)` (all returned 0 without reverting):

| Chain | Vault | Kind | Asset | Share (symbol) | 7540Redeem `0x620ee8e4` | 7540Deposit `0xce3bbe50` | Operator `0xe3bc4e65` | 7575 |
|---|---|---|---|---|---|---|---|---|
| Ethereum | `0xfe6920eb6c421f1179ca8c8d4170530cdbdfd77a` | Async | USDC `0xA0b8…eB48` | JTRSY `0x8c213ee7…4b86` (Janus Henderson Treasury) | true | true | true | true |
| Ethereum | `0x4880799ee5200fc58da299e965df644fbf46780b` | Async | USDC | JAAA `0x5a0F93D0…cf64` (Janus Henderson AAA CLO) | true | true | true | true |
| Ethereum | `0x74a739ea1dc67c5a0179ebad665d1d3c4b80b712` | Async | USDC | ACRDX `0x9477724B…A74f` (Anemoy Apollo credit) | true | true | true | true |
| Base | `0x2aef271f00a9d1b0da8065d396f4e601dbd0ef0b` | Async | USDC `0x8335…2913` | JAAA `0x5a0F93D0…cf64` | true | true | true | true |
| Base | `0x99e9092bae6d4394e54034ecb1e45441678323b9` | Async | USDC | SPXA `0x09B61343…0dB2` | true | true | true | true |
| Base | `0xeb5e9b9db4b1b6800ea00929b5966ccf70bad603` | SyncDepositAsyncRedeem | USDC | deJAAA `0xAAA0008C…82Cc` | true | **false** | true | true |

Notes:
- On SyncDepositAsyncRedeem vaults, `pendingDepositRequest` and `manager()` revert. Gate deposit-side reads on `supportsInterface(0xce3bbe50)`.
- Only the Ethereum `0xfe6920…` vault source was pulled and read (verified `AsyncVault`). The others are factory deployments sharing the same manager. **[INFERENCE]** They use the same code; their behaviour matched live.
- Recent `RedeemRequest` controllers on the JAAA Ethereum vault (e.g. `0x3deac8a895a3bcbdad206e3fb6105bc7a71d94d4`, block 26297483) already show pending=0 and claimable=0. **[INFERENCE]** They were fulfilled and claimed in the same epoch, or the controller is a router/operator. I didn't find a live non-zero pending position to use as a fixture.

### Lagoon (non-zero requestIds: a useful contrast)
Source: `hopperlabsxyz/lagoon-v0`, `src/v0.5.2/ERC7540.sol` and `src/v0.6.0/libraries/ERC7540Lib.sol`.
- **requestId = epoch id**. Passing `requestId == 0` means "the controller's `lastRedeemRequestId`".
- Pending if `requestId > lastRedeemEpochIdSettled`, claimable otherwise.

Live (Ethereum):

| Vault | Version | Asset | 7540R / 7540D / Op |
|---|---|---|---|
| `0x936facdf10c8c36294e7b9d28345255539d81bc7` (RockSolid rETH Vault) | `version()` = "v0.5.2", beacon-style proxy impl `0x8a051dd8…f92c` | rETH | true / true / true |
| `0xd17049ed25d8f99fe3bfd10cef2263da9995cfd8` (synUSD+) | "v0.5.0" | USDC | true / true / true |

Vault list came from `https://app.lagoon.finance/api/vaults`. **[UNVERIFIED]**:
- I didn't diff the deployed Lagoon bytecode/source against GitHub.
- Public epoch getters (`redeemEpochId()`, `lastRedeemEpochIdSettled()`) are **not** exposed under those names; the calls reverted.
- I didn't check Lagoon vaults on Base.

Sources:
- https://eips.ethereum.org/EIPS/eip-7540
- https://github.com/centrifuge/protocol/tree/live/env (ethereum.json, base.json, sepolia.json, base-sepolia.json)
- https://eth.blockscout.com/address/0xfe6920eb6c421f1179ca8c8d4170530cdbdfd77a (verified AsyncVault; files `src/vaults/BaseVaults.sol`, `src/misc/interfaces/IERC7540.sol`)
- https://api.centrifuge.io (GraphQL indexer; URL from `centrifuge/sdk` `src/Centrifuge.ts`)
- https://github.com/hopperlabsxyz/lagoon-v0 , https://app.lagoon.finance/api/vaults

---

## 4. Testnet deployments to test against

| Protocol | Network | Address | Live check |
|---|---|---|---|
| Lido WithdrawalQueueERC721 | **Hoodi** (560048) | `0xfe56573178f1bcdf53F01A6E9977670dcBBD9186` | Active: lastRequestId 5478, lastFinalized 5476, unfinalizedStETH ~27.01, not paused |
| Lido AccountingOracle / HashConsensus | Hoodi | `0xcb883B1bD0a41512b42D2dB267F2A2cd919FB216` / `0x32EC59a78abaca3f91527aeB2008925D5AaC1eFC` | `getFrameConfig()` = (91574, 225, 100) |
| Lido WQ | Sepolia | `0x1583C7b3f4C3B008720E6BcE5726336b0aB25fdd` | Deprecated: paused, 0 requests. Don't use |
| Ethena USDe | Sepolia | `0x9458caaca74249abbe9e964b3ce155b98ec88ef2` | USDe only; no official sUSDe found. Use a mainnet fork |
| Centrifuge V3 AsyncVault | Sepolia | `0x1115d870a0db74d41706c160f4bef757e0a7fc90` | asset Sepolia USDC `0x1c7D4B19…7238`, share "ARKTV3"; 7540R and 7540D true |
| Centrifuge V3 AsyncVault | Base Sepolia | `0x3cde73809e32ea066343ae5957da4e3e5c9bb786` | asset "p.one" `0x3ef69288…8367`, share "p.two"; 7540R and 7540D true |
| Centrifuge V3 core (testnet) | Sepolia and Base Sepolia (same addresses) | asyncRequestManager `0x10A17F06375621150E3B91486c2c4Ed408B77DF6`, spoke `0x634f692730978450A27F8FCA6F2dDe356a9B55A1`, vaultRegistry `0x9E7d9003c07a896d5E7b075fA6F4D1d7a2fDf672` | from `centrifuge/protocol@live/env/sepolia.json` and `base-sepolia.json` |

The Centrifuge testnet vault list comes from the testnet indexer `https://api-v3-test.cfg.embrio.tech` (URL from the Centrifuge SDK). For realistic sUSDe and Lido mainnet state, an `anvil --fork-url https://ethereum-rpc.publicnode.com` fork is the most faithful option.

---

## 5. Open items / not verified
- Etherscan pages weren't fetched directly because the API needs a key. Verification relied on Blockscout, which mirrors Etherscan/Sourcify.
- Not byte-diffed against GitHub: Lido HashConsensus/AccountingOracle deployed source, Ethena (vs `code4arena-contest`), Lagoon. Lido WithdrawalQueue sources **were** diffed and are identical.
- `IBaseOracle.getConsensusReport` 4th return value and the `WSTETH()` getter name on the WQ are unconfirmed. An adapter doesn't need them.
- The Hoodi WQ implementation address from a live slot read (`0xd0a60e52…`) differs from the address in one docs table row (`0x83BCE68B…`). Check before relying on it; the proxy address is confirmed either way.
- No official Ethena sUSDe testnet deployment was found.
- No live Centrifuge controller with a non-zero pending redeem was found to use as a fixture.
