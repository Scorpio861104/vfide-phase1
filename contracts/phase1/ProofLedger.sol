// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title ProofLedger - ENHANCED BEHAVIORAL RECORD SYSTEM
 * @dev Complete trust metrics and behavioral tracking for VFIDE ecosystem
 * @notice Immutable record of honor, trust, and community standing
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

/* ================================ ENUMS ================================ */

enum ActivityType {
    TRANSFER,       // Token transfer activity
    HOLDING,        // Long-term holding
    BURN,           // Token burn activity
    STAKE,          // Staking engagement
    VOTE,           // Governance participation
    REPORT,         // Reporting suspicious activity
    DONATION,       // Charitable contribution
    MERCHANT_TX,    // Merchant transaction
    SECURITY_ACTION,// Security measure taken
    PROTOCOL_USE,   // Protocol usage (swap, vault)
    PROOF_UPDATE,   // ProofScore update
    REFERRAL,       // Referral activity
    LEARNING,       // Education engagement
    COMMUNITY_HELP  // Community assistance
}

enum BadgeType {
    FLAME_KEEPER,   // For consistent burning
    VOWED,          // For long-term holding
    GUARDIAN,       // For protection actions
    MERCHANT,       // For merchant activities
    PHILANTHROPIST, // For donations
    SAGE,           // For governance wisdom
    PROTECTOR,      // For security actions
    PIONEER         // For early adoption
}

/* ================================ STRUCTS ================================ */

struct ProofScore {
    uint256 trust;      // Trust score (0-1000)
    uint256 security;   // Security score (0-1000)
    uint256 community;  // Community score (0-1000)
    uint256 loyalty;    // Loyalty score (0-1000)
    uint256 activity;   // Activity score (0-1000)
    uint256 lastUpdate;
    uint256 totalActivities;
    uint256 streak;     // Consecutive days
}

struct ActivityRecord {
    ActivityType activityType;
    uint256 amount; 
    uint256 timestamp;
    uint256 scoreImpact;
    bytes32 ref; // reference to offchain or onchain context
}

struct TrustMetrics {
    uint256 trustScore;
    uint256 positiveInteractions;
    uint256 negativeInteractions;
    uint256 disputesResolved;
    uint256 endorsements;
    uint256 flags;
}

struct Badge {
    BadgeType badgeType;
    uint256 level;
    uint256 grantedAt;
    bool active;
}

/* ================================ CONTRACT ================================ */

contract ProofLedger is Ownable, ReentrancyGuard, Pausable {
    // Authorized loggers (Seer, Token, Presale, etc.)
    mapping(address => bool) public authorizedLoggers;

    // User -> proof scores
    mapping(address => ProofScore) public proofScores;

    // Activity weights (by type)
    mapping(ActivityType => uint256) public activityWeights;

    // Badge requirements (by type)
    mapping(BadgeType => uint256) public badgeRequirements;

    // User activity history (most recent first or last? append order; consumers can read last N)
    mapping(address => ActivityRecord[]) public activityHistory;

    // Badges per user
    mapping(address => Badge[]) public userBadges;

    // Streaks
    mapping(address => uint256) public currentStreak;
    mapping(address => uint256) public longestStreak;
    mapping(address => uint256) public lastActivityDate;
    mapping(address => uint256) public dailyActivityCount;
    mapping(address => uint256) public firstActivityTime;

    // Trust graph
    mapping(address => mapping(address => uint256)) public trustRelationships;
    mapping(address => address[]) public trustedBy;
    mapping(address => address[]) public trusts;
    mapping(address => uint256) public trustNetworkSize;
    
    // Community metrics
    mapping(address => uint256) public communityReports;
    mapping(address => uint256) public helpfulActions;
    mapping(address => uint256) public charitableDonations;
    mapping(address => uint256) public governanceParticipation;
    
    // Historical data
    mapping(address => bytes32[]) public behaviorHistory;
    mapping(bytes32 => string) public behaviorDescriptions;

    /* ================================ EVENTS ================================ */

    event ActivityLogged(address indexed user, ActivityType activityType, uint256 amount, uint256 scoreImpact);
    event BehaviorPatternDetected(address indexed user, bytes32 patternId, string patternName);
    event TrustMetricsUpdated(address indexed user, uint256 oldScore, uint256 newScore, string reason);
    event BadgeEarned(address indexed user, BadgeType badgeType, uint256 level);
    event BadgeUpgraded(address indexed user, BadgeType badgeType, uint256 oldLevel, uint256 newLevel);
    event BadgeRevoked(address indexed user, BadgeType badgeType, string reason);
    event ProofScoreUpdated(address indexed user, uint256[5] oldScores, uint256[5] newScores);
    event StreakAchieved(address indexed user, uint256 streakDays);
    event MilestoneReached(address indexed user, string milestone, uint256 value);
    event TrustRelationshipEstablished(address indexed truster, address indexed trustee, uint256 level);
    event TrustRelationshipUpdated(address indexed truster, address indexed trustee, uint256 oldLevel, uint256 newLevel);
    event CommunityActionRecorded(address indexed user, string action, uint256 impact);
    event ReputationMilestone(address indexed user, uint256 totalScore, uint256 age);

    /* ================================ MODIFIERS ================================ */

    modifier onlyAuthorizedLogger() {
        require(authorizedLoggers[msg.sender] || msg.sender == owner(), "Unauthorized logger");
        _;
    }
    
    modifier validUser(address user) {
        require(user != address(0), "Invalid user address");
        _;
    }
    
    /* ================================ CONSTRUCTOR ================================ */
    
    constructor() Ownable() {
        _initializeActivityWeights();
        _initializeBadgeRequirements();
    }
    
    /**
     * @dev Initialize activity weights for scoring
     */
    function _initializeActivityWeights() internal {
        activityWeights[ActivityType.TRANSFER] = 1;
        activityWeights[ActivityType.HOLDING] = 2;
        activityWeights[ActivityType.BURN] = 3;
        activityWeights[ActivityType.STAKE] = 2;
        activityWeights[ActivityType.VOTE] = 4;
        activityWeights[ActivityType.REPORT] = 5;
        activityWeights[ActivityType.DONATION] = 3;
        activityWeights[ActivityType.MERCHANT_TX] = 2;
        activityWeights[ActivityType.SECURITY_ACTION] = 5;
        activityWeights[ActivityType.PROTOCOL_USE] = 2;
        activityWeights[ActivityType.PROOF_UPDATE] = 1;
        activityWeights[ActivityType.REFERRAL] = 2;
        activityWeights[ActivityType.LEARNING] = 1;
        activityWeights[ActivityType.COMMUNITY_HELP] = 3;
    }
    
    /**
     * @dev Initialize badge requirements
     */
    function _initializeBadgeRequirements() internal {
        badgeRequirements[BadgeType.FLAME_KEEPER] = 1000; // 1000 burns
        badgeRequirements[BadgeType.VOWED] = 365; // 365 days holding
        badgeRequirements[BadgeType.GUARDIAN] = 10; // 10 successful protections
        badgeRequirements[BadgeType.MERCHANT] = 100; // 100 merchant transactions
        badgeRequirements[BadgeType.PHILANTHROPIST] = 50; // 50 charitable donations
        badgeRequirements[BadgeType.SAGE] = 25; // 25 governance votes
        badgeRequirements[BadgeType.PROTECTOR] = 5; // 5 security actions
        badgeRequirements[BadgeType.PIONEER] = 30; // 30 days early adoption
    }
    
    /* ================================ CORE ACTIVITY LOGGING ================================ */
    
    /**
     * @dev Log user activity
     */
    function logActivity(
        address user, 
        ActivityType activityType, 
        uint256 amount, 
        uint256 scoreImpact,
        bytes32 ref
    ) external onlyAuthorizedLogger validUser(user) whenNotPaused {
        // Update activity
        activityHistory[user].push(ActivityRecord({
            activityType: activityType,
            amount: amount,
            timestamp: block.timestamp,
            scoreImpact: scoreImpact,
            ref: ref
        }));

        // Streak tracking
        uint256 today = block.timestamp / 1 days;
        if (lastActivityDate[user] != today) {
            if (today == lastActivityDate[user] + 1) {
                currentStreak[user]++;
                if (currentStreak[user] > longestStreak[user]) {
                    longestStreak[user] = currentStreak[user];
                    emit StreakAchieved(user, currentStreak[user]);
                }
            } else if (lastActivityDate[user] != 0) {
                currentStreak[user] = 1;
            } else {
                currentStreak[user] = 1;
                firstActivityTime[user] = block.timestamp;
            }
            
            lastActivityDate[user] = today;
            dailyActivityCount[user] = 0;
        }
        
        dailyActivityCount[user]++;
        
        // Score updates
        uint256 weightedImpact = scoreImpact * activityWeights[activityType];
        ProofScore storage scores = proofScores[user];
        uint256[5] memory oldScores = [scores.trust, scores.security, scores.community, scores.loyalty, scores.activity];
        
        // Simple example mapping (can evolve under DAO)
        if (activityType == ActivityType.TRANSFER || activityType == ActivityType.PROTOCOL_USE) {
            scores.activity = _boundedAdd(scores.activity, weightedImpact);
        } else if (activityType == ActivityType.HOLDING || activityType == ActivityType.STAKE) {
            scores.loyalty = _boundedAdd(scores.loyalty, weightedImpact);
        } else if (activityType == ActivityType.BURN || activityType == ActivityType.REPORT || activityType == ActivityType.SECURITY_ACTION) {
            scores.security = _boundedAdd(scores.security, weightedImpact);
        } else if (activityType == ActivityType.VOTE || activityType == ActivityType.COMMUNITY_HELP) {
            scores.community = _boundedAdd(scores.community, weightedImpact);
        } else if (activityType == ActivityType.DONATION || activityType == ActivityType.MERCHANT_TX || activityType == ActivityType.REFERRAL) {
            scores.trust = _boundedAdd(scores.trust, weightedImpact);
        } else if (activityType == ActivityType.LEARNING || activityType == ActivityType.PROOF_UPDATE) {
            // spread small improvements to all
            uint256 share = weightedImpact / 5;
            scores.trust = _boundedAdd(scores.trust, share);
            scores.security = _boundedAdd(scores.security, share);
            scores.community = _boundedAdd(scores.community, share);
            scores.loyalty = _boundedAdd(scores.loyalty, share);
            scores.activity = _boundedAdd(scores.activity, share);
        }

        scores.totalActivities++;
        scores.lastUpdate = block.timestamp;

        emit ActivityLogged(user, activityType, amount, weightedImpact);
        emit ProofScoreUpdated(user, oldScores, [scores.trust, scores.security, scores.community, scores.loyalty, scores.activity]);
    }

    /**
     * @dev Record a behavior pattern (e.g., manipulation or positive behavior)
     */
    function recordBehaviorPattern(
        address user, 
        bytes32 patternId,
        string calldata patternName,
        int256 scoreDelta, // can be negative
        bytes32 ref
    ) external onlyAuthorizedLogger validUser(user) whenNotPaused {
        behaviorHistory[user].push(patternId);
        behaviorDescriptions[patternId] = patternName;

        ProofScore storage scores = proofScores[user];
        uint256[5] memory oldScores = [scores.trust, scores.security, scores.community, scores.loyalty, scores.activity];

        // Apply deltas (negative allowed)
        if (scoreDelta > 0) {
            uint256 d = uint256(scoreDelta);
            scores.security = _boundedAdd(scores.security, d);
            scores.trust    = _boundedAdd(scores.trust, d / 2);
        } else if (scoreDelta < 0) {
            uint256 d = uint256(-scoreDelta);
            scores.security = _boundedSub(scores.security, d);
            scores.trust    = _boundedSub(scores.trust, d / 2);
        }
        scores.lastUpdate = block.timestamp;

        emit BehaviorPatternDetected(user, patternId, patternName);
        emit ProofScoreUpdated(user, oldScores, [scores.trust, scores.security, scores.community, scores.loyalty, scores.activity]);
    }

    /* ================================ TRUST GRAPH ================================ */

    function establishTrustRelationship(address trustee, uint256 level) external validUser(trustee) {
        require(level <= 1000, "level>1000");
        uint256 old = trustRelationships[msg.sender][trustee];
        trustRelationships[msg.sender][trustee] = level;
        if (old == 0) {
            trusts[msg.sender].push(trustee);
            trustedBy[trustee].push(msg.sender);
            trustNetworkSize[msg.sender]++;
            trustNetworkSize[trustee]++;
            emit TrustRelationshipEstablished(msg.sender, trustee, level);
        } else {
            emit TrustRelationshipUpdated(msg.sender, trustee, old, level);
        }

        // reflect some trust into score
        ProofScore storage s = proofScores[trustee];
        uint256[5] memory oldScores = [s.trust, s.security, s.community, s.loyalty, s.activity];
        s.trust = _boundedAdd(s.trust, level / 50); // small incremental bump
        s.lastUpdate = block.timestamp;
        emit TrustMetricsUpdated(trustee, oldScores[0], s.trust, "trust relationship");
        emit ProofScoreUpdated(trustee, oldScores, [s.trust, s.security, s.community, s.loyalty, s.activity]);
    }

    /* ================================ QUERIES ================================ */

    function getProofScore(address user) external view returns (
        uint256 trust,
        uint256 security,
        uint256 community, 
        uint256 loyalty,
        uint256 activity
    ) {
        ProofScore storage scores = proofScores[user];
        return (scores.trust, scores.security, scores.community, scores.loyalty, scores.activity);
    }
    
    /**
     * @dev Get behavior history
     */
    function getBehaviorHistory(address user) external view returns (bytes32[] memory) {
        return behaviorHistory[user];
    }
    
    /**
     * @dev Get user badges
     */
    function getUserBadges(address user) external view returns (Badge[] memory) {
        return userBadges[user];
    }
    
    /**
     * @dev Get activity history (last N activities)
     */
    function getActivityHistory(address user, uint256 count) external view returns (ActivityRecord[] memory) {
        ActivityRecord[] storage list = activityHistory[user];
        if (count == 0 || count > list.length) count = list.length;
        ActivityRecord[] memory out = new ActivityRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = list[list.length - 1 - i];
        }
        return out;
    }
    
    /**
     * @dev Get trust metrics
     */
    function getTrustMetrics(address user) external view returns (TrustMetrics memory) {
        return TrustMetrics({
            trustScore: proofScores[user].trust,
            positiveInteractions: trustNetworkSize[user],
            negativeInteractions: communityReports[user], // simplistic mapping
            disputesResolved: helpfulActions[user],
            endorsements: governanceParticipation[user],
            flags: communityReports[user]
        });
    }
    
    /**
     * @dev Get user statistics
     */
    function getUserStatistics(address user) external view returns (
        uint256 totalActivities_,
        uint256 streak_,
        uint256 longestStreak_,
        uint256 firstActivity_,
        uint256 lastUpdate_
    ) {
        ProofScore storage s = proofScores[user];
        return (s.totalActivities, currentStreak[user], longestStreak[user], firstActivityTime[user], s.lastUpdate);
    }

    /* ================================ GOV / ADMIN ================================ */

    function addAuthorizedLogger(address logger) external onlyOwner {
        authorizedLoggers[logger] = true;
    }

    function removeAuthorizedLogger(address logger) external onlyOwner {
        authorizedLoggers[logger] = false;
    }

    function setVFIDEToken(address _vfideToken) external onlyOwner {
        // reserved for future cross-validation if needed
        _vfideToken; // silence warning
    }

    function updateActivityWeight(ActivityType activityType, uint256 weight) external onlyOwner {
        activityWeights[activityType] = weight;
    }

    function updateBadgeRequirement(BadgeType badgeType, uint256 requirement) external onlyOwner {
        badgeRequirements[badgeType] = requirement;
    }

    function emergencyPause() external onlyOwner {
        _pause();
    }

    function emergencyUnpause() external onlyOwner {
        _unpause();
    }

    function cleanupOldData(address[] calldata users, uint256 batchSize) external onlyOwner {
        // Implementation for cleaning up old activity records
        // to manage storage costs - would process in batches
    }

    /**
     * @notice Return a single aggregated ProofScore in [0,1000] for integration (e.g., VFIDEToken).
     * @dev Uses the average of the five categories, clamped to 0..1000.
     */
    function proofScoreOf(address user) external view returns (uint16) {
        ProofScore storage s = proofScores[user];
        uint256 total = s.trust + s.security + s.community + s.loyalty + s.activity;
        uint256 avg = total / 5;
        if (avg > 1000) avg = 1000;
        return uint16(avg);
    }

    /* ================================ INTERNAL UTILS ================================ */

    function _boundedAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c > 1000 ? 1000 : c;
        }
    }

    function _boundedSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}