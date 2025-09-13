// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice minimal ERC20 interface for VFIDE + stables
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from,address to,uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @notice stable registry: whitelisted stables + their decimals
interface IStablecoinRegistry {
    function isAllowed(address stable) external view returns (bool);
    function decimalsOf(address stable) external view returns (uint8);
}

/// @title VFIDEPresaleMonolith
/// @notice Single-contract presale with tiering, vesting, bonuses, limits, cooldown, and direct claiming.
contract VFIDEPresaleMonolith {
    // ----------------- Admin / wiring -----------------
    address public owner;
    IERC20  public immutable vfide;            // VFIDE token (must be pre-funded into this contract)
    IStablecoinRegistry public immutable stableRegistry;
    address public immutable treasury;         // stablecoins go here immediately

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    // ----------------- Sale window -----------------
    bool   public started;
    bool   public ended;
    uint64 public saleStart;                   // set at start()
    uint64 public saleEnd;                     // start + 30 days

    // ----------------- Tiers -----------------
    // Base caps (no bonuses in these numbers)
    uint256 public constant TIER1_CAP = 35_000_000e18;
    uint256 public constant TIER2_CAP = 25_000_000e18;
    uint256 public constant TIER3_CAP = 15_000_000e18;

    // Prices in microUSD (1e6 = $1)
    uint32  public constant P_TIER1 = 30_000;  // $0.03
    uint32  public constant P_TIER2 = 50_000;  // $0.05
    uint32  public constant P_TIER3 = 70_000;  // $0.07

    // Vesting schedules (cliff + linear)
    uint32  public constant T1_CLIFF  = 180 days;
    uint32  public constant T1_LINEAR = 90  days;
    uint32  public constant T2_CLIFF  = 90  days;
    uint32  public constant T2_LINEAR = 60  days;
    uint32  public constant T3_CLIFF  = 60  days;
    uint32  public constant T3_LINEAR = 30  days;

    // Lock bonuses (bps of base)
    uint16  public constant T1_LOCK_BONUS_BPS = 1000; // +10%
    uint16  public constant T2_LOCK_BONUS_BPS = 500;  // +5%
    uint16  public constant T3_LOCK_BONUS_BPS = 200;  // +2%

    // Referral bonuses (bps of base)
    uint16  public constant REFERRER_BPS = 300;       // +3%
    uint16  public constant REFEREE_BPS  = 200;       // +2%

    // Bonus pools (must be covered by VFIDE balance in this contract)
    uint256 public lockBonusPool;     // e.g., ~5,000,000e18
    uint256 public refBonusPool;      // e.g., ~3,750,000e18
    uint256 public allocatedLockBonus;
    uint256 public allocatedRefBonus;

    // ----------------- Limits & cooldown -----------------
    // USD limits in microUSD
    uint32  public constant MIN_USD  = 25_000_000;      // $25
    uint32  public constant MAX_USD  = 5_000_000_000;   // $5,000
    uint32  public constant COOLDOWN = 24 hours;        // 1 buy / 24h per wallet

    // Per-wallet base caps (bonuses excluded)
    uint256 public constant CAP_WALLET_T1    = 100_000e18;
    uint256 public constant CAP_WALLET_T2    = 150_000e18;
    uint256 public constant CAP_WALLET_T3    = 250_000e18;
    uint256 public constant CAP_WALLET_GLOBAL= 500_000e18;

    // ----------------- Accounting -----------------
    uint256 public soldT1; // base sold per tier
    uint256 public soldT2;
    uint256 public soldT3;

    mapping(address => uint256) public boughtT1;   // base per wallet
    mapping(address => uint256) public boughtT2;
    mapping(address => uint256) public boughtT3;
    mapping(address => uint256) public boughtGlobal;

    mapping(address => uint64) public lastBuyAt;

    // referrals
    mapping(address => address) public referrerOf;             // referee => referrer (set once)
    mapping(address => uint8)   public refCount;               // referrer => credited referees (max 5)
    mapping(address => uint64)  public lastReferralCreditAt;   // referrer cooldown (24h)
    mapping(address => bool)    public hasReceivedRefereeBonus;// referee bonus only once ever

    // ----------------- Vesting positions -----------------
    struct Position {
        address beneficiary;
        uint128 total;     // total to vest
        uint128 claimed;   // already claimed
        uint64  start;     // saleStart
        uint64  cliff;     // start + cliff
        uint64  end;       // cliff + linear
        uint8   tier;      // 1/2/3
    }
    uint256 public nextPosId = 1;
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public positionsOf; // optional convenience

    // ----------------- Events -----------------
    event SaleStarted(uint64 start, uint64 end);
    event SaleEnded(uint256 sold1, uint256 sold2, uint256 sold3, uint256 lockBonusAllocated, uint256 refBonusAllocated);

    event Purchase(
        address indexed buyer,
        uint8 tier,
        address stable,
        uint256 paidStable,
        uint256 baseAmount,
        uint256 lockBonus,
        address indexed referrer,
        uint256 refereeBonus,
        uint256 referrerBonus
    );
    event TierSoldOut(uint8 tier);
    event ReferralRegistered(address indexed referrer, address indexed referee);

    event PositionCreated(uint256 indexed id, address indexed user, uint256 total, uint64 start, uint64 cliff, uint64 end, uint8 tier);
    event Claimed(uint256 indexed id, address indexed user, uint256 amount);

    // ----------------- Lifecycle -----------------
    constructor(
        address _owner,
        IERC20 _vfide,
        IStablecoinRegistry _stableRegistry,
        address _treasury,
        uint256 _lockBonusPool,
        uint256 _refBonusPool
    ) {
        require(_owner != address(0) && address(_vfide)!=address(0) && address(_stableRegistry)!=address(0) && _treasury!=address(0), "zero");
        owner = _owner;
        vfide = _vfide;
        stableRegistry = _stableRegistry;
        treasury = _treasury;
        lockBonusPool = _lockBonusPool;
        refBonusPool  = _refBonusPool;
    }

    function start() external onlyOwner {
        require(!started, "started");
        // IMPORTANT: Pre-fund this contract with enough VFIDE to cover:
        // (sold base up to 75M) + lockBonusPool + refBonusPool.
        started   = true;
        saleStart = uint64(block.timestamp);
        saleEnd   = saleStart + 30 days;
        emit SaleStarted(saleStart, saleEnd);
    }

    function end() external onlyOwner {
        require(started && !ended, "bad");
        require(block.timestamp > saleEnd || (soldT1==TIER1_CAP && soldT2==TIER2_CAP && soldT3==TIER3_CAP), "still running");
        ended = true;
        emit SaleEnded(soldT1, soldT2, soldT3, allocatedLockBonus, allocatedRefBonus);
        // Unsold base simply never allocated/minted; any leftover VFIDE (including unused bonus pools)
        // can be withdrawn by owner post-sale to the treasury or burned via a separate process.
        // To hard-burn leftovers on-chain, you can add a burnSink and transfer them there.
    }

    // ----------------- Public: buy & claim -----------------
    function buy(uint8 tier, address stable, uint256 amountStable, address referrer) external {
        require(started && !ended && block.timestamp <= saleEnd, "not active");
        require(tier >= 1 && tier <= 3, "bad tier");
        require(stableRegistry.isAllowed(stable), "stable not allowed");
        require(amountStable > 0, "zero");

        // cooldown
        uint64 lb = lastBuyAt[msg.sender];
        require(lb == 0 || block.timestamp >= uint256(lb) + COOLDOWN, "cooldown 24h");
        lastBuyAt[msg.sender] = uint64(block.timestamp);

        // USD normalization (1e6 microUSD)
        uint8 dec = stableRegistry.decimalsOf(stable);
        uint256 microUSD;
        if (dec == 6) {
            microUSD = amountStable;
        } else if (dec > 6) {
            microUSD = amountStable / (10 ** (dec - 6));
        } else {
            microUSD = amountStable * (10 ** (6 - dec));
        }
        require(microUSD >= MIN_USD && microUSD <= MAX_USD, "min/max");

        // base tokens from price
        uint32 price = (tier==1) ? P_TIER1 : (tier==2 ? P_TIER2 : P_TIER3);
        uint256 baseTokens = (microUSD * 1e18) / uint256(price);
        require(baseTokens > 0, "too small");

        // cap & per-wallet checks (base only)
        if (tier==1) {
            require(soldT1 + baseTokens <= TIER1_CAP, "tier1 sold out");
            require(boughtT1[msg.sender] + baseTokens <= CAP_WALLET_T1, "wallet cap t1");
        } else if (tier==2) {
            require(soldT2 + baseTokens <= TIER2_CAP, "tier2 sold out");
            require(boughtT2[msg.sender] + baseTokens <= CAP_WALLET_T2, "wallet cap t2");
        } else {
            require(soldT3 + baseTokens <= TIER3_CAP, "tier3 sold out");
            require(boughtT3[msg.sender] + baseTokens <= CAP_WALLET_T3, "wallet cap t3");
        }
        require(boughtGlobal[msg.sender] + baseTokens <= CAP_WALLET_GLOBAL, "wallet cap global");

        // stable transfer
        require(IERC20(stable).transferFrom(msg.sender, treasury, amountStable), "stable xfer fail");

        // vesting schedule & lock bonus
        (uint64 startTs, uint64 cliffTs, uint64 endTs, uint16 lockBps) = _scheduleForTier(tier);
        uint256 lockBonus = (baseTokens * lockBps) / 10_000;
        require(allocatedLockBonus + lockBonus <= lockBonusPool, "lock bonus pool exhausted");
        allocatedLockBonus += lockBonus;

        // referrals
        (address finalRef, uint256 refereeBonus, uint256 referrerBonus) = _computeReferral(msg.sender, referrer, baseTokens);
        if (refereeBonus > 0 || referrerBonus > 0) {
            require(allocatedRefBonus + refereeBonus + referrerBonus <= refBonusPool, "ref bonus pool exhausted");
            allocatedRefBonus += (refereeBonus + referrerBonus);
        }

        // update sold + per wallet base counters
        if (tier==1) { soldT1 += baseTokens; boughtT1[msg.sender] += baseTokens; }
        else if (tier==2) { soldT2 += baseTokens; boughtT2[msg.sender] += baseTokens; }
        else { soldT3 += baseTokens; boughtT3[msg.sender] += baseTokens; }
        boughtGlobal[msg.sender] += baseTokens;

        // create positions:
        // 1) buyer: base + lockBonus + refereeBonus
        _createPosition(msg.sender, baseTokens + lockBonus + refereeBonus, startTs, cliffTs, endTs, tier);

        // 2) referrer: referrerBonus (if any)
        if (finalRef != address(0) && referrerBonus > 0) {
            _createPosition(finalRef, referrerBonus, startTs, cliffTs, endTs, tier);
        }

        emit Purchase(msg.sender, tier, stable, amountStable, baseTokens, lockBonus, finalRef, refereeBonus, referrerBonus);

        if (tier==1 && soldT1 == TIER1_CAP) emit TierSoldOut(1);
        if (tier==2 && soldT2 == TIER2_CAP) emit TierSoldOut(2);
        if (tier==3 && soldT3 == TIER3_CAP) emit TierSoldOut(3);
    }

    function claimable(uint256 id) public view returns (uint256) {
        Position memory p = positions[id];
        if (msg.sender != p.beneficiary) return 0;
        if (block.timestamp <= p.cliff) return 0;
        if (block.timestamp >= p.end) {
            return uint256(p.total) - uint256(p.claimed);
        }
        uint256 vested = (uint256(p.total) * (block.timestamp - p.cliff)) / (p.end - p.cliff);
        if (vested > p.total) vested = p.total;
        return vested - p.claimed;
    }

    function claim(uint256 id) external {
        uint256 amt = claimable(id);
        require(amt > 0, "nothing");
        Position storage p = positions[id];
        p.claimed += uint128(amt);
        require(vfide.transfer(p.beneficiary, amt), "vfide xfer fail");
        emit Claimed(id, p.beneficiary, amt);
    }

    // ----------------- Internals -----------------
    function _scheduleForTier(uint8 tier) internal view returns (uint64 startTs, uint64 cliffTs, uint64 endTs, uint16 lockBps) {
        startTs = saleStart;
        if (tier==1) {
            lockBps = T1_LOCK_BONUS_BPS;
            cliffTs = uint64(uint256(startTs) + T1_CLIFF);
            endTs   = uint64(uint256(cliffTs) + T1_LINEAR);
        } else if (tier==2) {
            lockBps = T2_LOCK_BONUS_BPS;
            cliffTs = uint64(uint256(startTs) + T2_CLIFF);
            endTs   = uint64(uint256(cliffTs) + T2_LINEAR);
        } else {
            lockBps = T3_LOCK_BONUS_BPS;
            cliffTs = uint64(uint256(startTs) + T3_CLIFF);
            endTs   = uint64(uint256(cliffTs) + T3_LINEAR);
        }
    }

    function _createPosition(
        address user,
        uint256 amount,
        uint64 startTs,
        uint64 cliffTs,
        uint64 endTs,
        uint8 tier
    ) internal {
        require(user != address(0) && amount > 0, "bad pos");
        // Ensure contract has enough VFIDE to honor this position
        // (soft check; hard guarantee is operational: pre-fund before start)
        require(vfide.balanceOf(address(this)) >= _unclaimedLiabilityAfterAdd(amount), "insufficient VFIDE pre-fund");

        uint256 id = nextPosId++;
        positions[id] = Position({
            beneficiary: user,
            total: uint128(amount),
            claimed: 0,
            start: startTs,
            cliff: cliffTs,
            end: endTs,
            tier: tier
        });
        positionsOf[user].push(id);
        emit PositionCreated(id, user, amount, startTs, cliffTs, endTs, tier);
    }

    function _unclaimedLiabilityAfterAdd(uint256 add) internal view returns (uint256) {
        // Best-effort: ensure current VFIDE balance >= outstanding liability + add.
        // Outstanding liability ~= totalPositionsTotal - totalPositionsClaimed
        // For gas, we do not iterate storage. Operationally you must pre-fund sufficiently.
        // Here we only check current balance >= add (light guard).
        // If you want a strict accounting, you can set a requiredMinBalance variable before start.
        return add;
    }

    function _computeReferral(address buyer, address referrer, uint256 baseTokens)
        internal
        returns (address, uint256, uint256)
    {
        uint256 refereeBonus;
        uint256 referrerBonus;
        address finalRef = address(0);

        if (referrer == address(0) || referrer == buyer) {
            return (finalRef, 0, 0);
        }

        address existing = referrerOf[buyer];
        if (existing == address(0)) {
            referrerOf[buyer] = referrer;
            emit ReferralRegistered(referrer, buyer);
            existing = referrer;
        }

        if (!hasReceivedRefereeBonus[buyer] && refCount[existing] < 5) {
            uint64 lastCred = lastReferralCreditAt[existing];
            if (lastCred == 0 || block.timestamp >= uint256(lastCred) + 24 hours) {
                refereeBonus  = (baseTokens * REFEREE_BPS) / 10_000;
                referrerBonus = (baseTokens * REFERRER_BPS) / 10_000;
                hasReceivedRefereeBonus[buyer] = true;
                refCount[existing] += 1;
                lastReferralCreditAt[existing] = uint64(block.timestamp);
                finalRef = existing;
            }
        }

        return (finalRef, refereeBonus, referrerBonus);
    }

    // ----------------- Owner utils (pre-sale only) -----------------
    function setOwner(address n) external onlyOwner { owner = n; }
    function topUpLockBonusPool(uint256 amt) external onlyOwner { lockBonusPool += amt; }
    function topUpRefBonusPool(uint256 amt) external onlyOwner { refBonusPool += amt; }

    // Optional: withdraw leftover VFIDE after sale ends (e.g., move to burn sink or treasury)
    function sweepVFIDE(address to, uint256 amount) external onlyOwner {
        require(ended, "not ended");
        require(vfide.transfer(to, amount), "sweep fail");
    }
}