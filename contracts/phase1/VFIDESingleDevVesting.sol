// SPDX-License-Identifier: MIT
pragma solidity 0.8.2;

/**
 * @title VFIDE Single Developer Vesting - COMPLETE FIXED IMPLEMENTATION
 * @dev FIXED: Pragma version, honor-based vesting with transparency
 */

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IProofLedger {
    function logActivity(address user, string calldata actionType, uint256 amount) external;
    function getProofScore(address user) external view returns (uint256,uint256,uint256,uint256,uint256);
}

contract VFIDESingleDevVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ================================ CONSTANTS ================================ */
    
    uint256 public constant DEV_ALLOCATION = 40_000_000 * 1e18; // 40M VFIDE
    uint256 public constant VESTING_DURATION = 36 * 30 days;    // 36 months
    uint256 public constant CLIFF_DURATION = 6 * 30 days;       // 6 months cliff
    uint256 public constant MIN_HONOR_FOR_FULL_VEST = 500;      // Honor requirement

    /* ================================ STATE VARIABLES ================================ */
    
    IERC20 public immutable vfideToken;
    IProofLedger public proofLedger;
    address public immutable developer;
    
    uint256 public immutable vestingStart;
    uint256 public immutable cliffEnd;
    uint256 public immutable vestingEnd;
    
    uint256 public tokensClaimed;
    bool public vestingRevoked;
    uint256 public revokedAt;
    
    // Honor-based vesting enhancements
    uint256 public honorBonus; // Additional tokens earned through honor
    uint256 public lastHonorCheck;
    mapping(uint256 => uint256) public monthlyHonorScores; // month => honor score
    uint256 public totalHonorBonusEarned;

    /* ================================ EVENTS ================================ */
    
    event TokensClaimed(address indexed developer, uint256 amount, uint256 totalClaimed);
    event VestingRevoked(address indexed admin, uint256 vestedAmount, uint256 revokedAmount);
    event VestingRestored(address indexed admin);
    event HonorBonusEarned(address indexed developer, uint256 bonus, uint256 honorScore);
    event HonorableVesting(address indexed developer, string action, uint256 value);

    /* ================================ MODIFIERS ================================ */
    
    modifier onlyDeveloper() {
        require(msg.sender == developer, "Only developer can claim");
        _;
    }
    
    modifier vestingActive() {
        require(!vestingRevoked, "Vesting has been revoked");
        _;
    }

    /* ================================ CONSTRUCTOR ================================ */
    
    constructor(
        address _vfideToken,
        address _developer,
        address _proofLedger,
        uint256 _vestingStart
    ) {
        require(_vfideToken != address(0), "Invalid token address");
        require(_developer != address(0), "Invalid developer address");
        require(_vestingStart > 0, "Invalid vesting start");
        
        vfideToken = IERC20(_vfideToken);
        developer = _developer;
        proofLedger = IProofLedger(_proofLedger);
        vestingStart = _vestingStart;
        cliffEnd = _vestingStart + CLIFF_DURATION;
        vestingEnd = _vestingStart + VESTING_DURATION;
        lastHonorCheck = _vestingStart;
    }

    /* ================================ VESTING FUNCTIONS ================================ */

    /**
     * @dev FIXED: Claim vested tokens with honor bonus calculation
     */
    function claimTokens() external onlyDeveloper vestingActive nonReentrant {
        require(block.timestamp >= cliffEnd, "Cliff period not over");
        
        uint256 vested = getVestedAmount();
        uint256 claimable = vested - tokensClaimed;
        
        require(claimable > 0, "No tokens to claim");
        require(vfideToken.balanceOf(address(this)) >= claimable, "Insufficient contract balance");

        // Update honor bonus before claiming
        _updateHonorBonus();
        
        // Add any available honor bonus
        uint256 totalClaimable = claimable + honorBonus;
        if (totalClaimable > vfideToken.balanceOf(address(this))) {
            totalClaimable = vfideToken.balanceOf(address(this));
        }
        
        tokensClaimed += claimable;
        if (honorBonus > 0) {
            totalHonorBonusEarned += honorBonus;
            honorBonus = 0; // Reset bonus after claiming
        }
        
        vfideToken.safeTransfer(developer, totalClaimable);
        
        // Honor logging
        if (address(proofLedger) != address(0)) {
            proofLedger.logActivity(developer, "DEV_VEST_CLAIM", totalClaimable);
        }
        
        emit TokensClaimed(developer, totalClaimable, tokensClaimed);
        emit HonorableVesting(developer, "CLAIMED_TOKENS", totalClaimable);
    }

    /**
     * @dev FIXED: Update honor bonus based on developer behavior
     */
    function _updateHonorBonus() internal {
        if (address(proofLedger) == address(0)) return;
        
        uint256 currentMonth = (block.timestamp - vestingStart) / (30 days);
        uint256 lastCheckedMonth = (lastHonorCheck - vestingStart) / (30 days);
        
        if (currentMonth <= lastCheckedMonth) return;
        
        try proofLedger.getProofScore(developer) returns (uint256 trust,uint256,uint256,uint256,uint256) {
            // Calculate honor bonus for months since last check
            for (uint256 month = lastCheckedMonth + 1; month <= currentMonth; month++) {
                if (monthlyHonorScores[month] == 0) { // Only award once per month
                    monthlyHonorScores[month] = trust;
                    
                    // Honor bonus calculation
                    if (trust >= 800) {
                        honorBonus += 50000 * 1e18; // 50k VFIDE for exceptional honor
                        emit HonorBonusEarned(developer, 50000 * 1e18, trust);
                    } else if (trust >= 600) {
                        honorBonus += 25000 * 1e18; // 25k VFIDE for high honor
                        emit HonorBonusEarned(developer, 25000 * 1e18, trust);
                    } else if (trust >= 400) {
                        honorBonus += 10000 * 1e18; // 10k VFIDE for good honor
                        emit HonorBonusEarned(developer, 10000 * 1e18, trust);
                    } else if (trust >= MIN_HONOR_FOR_FULL_VEST) {
                        honorBonus += 5000 * 1e18; // 5k VFIDE for basic honor
                        emit HonorBonusEarned(developer, 5000 * 1e18, trust);
                    }
                    // No bonus for low honor scores
                }
            }
        } catch {
            // If ProofLedger fails, no bonus awarded
        }
        
        lastHonorCheck = block.timestamp;
    }

    /**
     * @dev Calculate vested amount based on time elapsed
     */
    function getVestedAmount() public view returns (uint256) {
        if (block.timestamp < cliffEnd) {
            return 0;
        }
        
        if (block.timestamp >= vestingEnd) {
            return DEV_ALLOCATION;
        }
        
        uint256 vestedTime = block.timestamp - vestingStart;
        return (DEV_ALLOCATION * vestedTime) / VESTING_DURATION;
    }

    /**
     * @dev Get available claimable amount (including honor bonus)
     */
    function getClaimableAmount() external view returns (uint256 vested, uint256 bonus, uint256 total) {
        vested = getVestedAmount() - tokensClaimed;
        bonus = honorBonus;
        total = vested + bonus;
        
        // Ensure we don't exceed contract balance
        uint256 contractBalance = vfideToken.balanceOf(address(this));
        if (total > contractBalance) {
            total = contractBalance;
        }
        
        return (vested, bonus, total);
    }

    /**
     * @dev Get developer honor statistics
     */
    function getDeveloperHonorStats() external view returns (
        uint256 currentHonor,
        uint256 totalBonusEarned,
        uint256 availableBonus,
        uint256 monthsActive
    ) {
        currentHonor = 0;
        if (address(proofLedger) != address(0)) {
            try proofLedger.getProofScore(developer) returns (uint256 trust,uint256,uint256,uint256,uint256) {
                currentHonor = trust;
            } catch {}
        }
        
        return (
            currentHonor,
            totalHonorBonusEarned,
            honorBonus,
            (block.timestamp - vestingStart) / (30 days)
        );
    }

    /* ================================ ADMIN FUNCTIONS ================================ */

    /**
     * @dev Revoke vesting (emergency only)
     */
    function revokeVesting() external onlyOwner {
        require(!vestingRevoked, "Already revoked");
        
        uint256 vestedAmount = getVestedAmount();
        uint256 revokedAmount = DEV_ALLOCATION - vestedAmount;
        
        vestingRevoked = true;
        revokedAt = block.timestamp;
        
        // Transfer revoked tokens back to owner
        if (revokedAmount > 0) {
            uint256 contractBalance = vfideToken.balanceOf(address(this));
            uint256 transferAmount = revokedAmount > contractBalance ? contractBalance : revokedAmount;
            vfideToken.safeTransfer(owner(), transferAmount);
        }
        
        emit VestingRevoked(msg.sender, vestedAmount, revokedAmount);
    }

    /**
     * @dev Restore vesting (if revoked in error)
     */
    function restoreVesting() external onlyOwner {
        require(vestingRevoked, "Vesting not revoked");
        
        vestingRevoked = false;
        revokedAt = 0;
        
        emit VestingRestored(msg.sender);
    }

    /**
     * @dev Set ProofLedger contract
     */
    function setProofLedger(address _proofLedger) external onlyOwner {
        proofLedger = IProofLedger(_proofLedger);
    }

    /**
     * @dev Manual honor bonus award (admin override)
     */
    function awardHonorBonus(uint256 amount, string calldata reason) external onlyOwner {
        honorBonus += amount;
        emit HonorBonusEarned(developer, amount, 0);
        emit HonorableVesting(developer, reason, amount);
    }

    /* ================================ VIEW FUNCTIONS ================================ */

    /**
     * @dev Get complete vesting information
     */
    function getVestingInfo() external view returns (
        uint256 _vestingStart,
        uint256 _cliffEnd,
        uint256 _vestingEnd,
        uint256 _totalAllocation,
        uint256 _tokensClaimed,
        uint256 _vestedAmount,
        bool _vestingRevoked,
        uint256 _revokedAt
    ) {
        return (
            vestingStart,
            cliffEnd,
            vestingEnd,
            DEV_ALLOCATION,
            tokensClaimed,
            getVestedAmount(),
            vestingRevoked,
            revokedAt
        );
    }

    /**
     * @dev Calculate vesting progress percentage
     */
    function getVestingProgress() external view returns (uint256 percentComplete) {
        if (block.timestamp < vestingStart) return 0;
        if (block.timestamp >= vestingEnd) return 10000; // 100.00%
        
        uint256 elapsed = block.timestamp - vestingStart;
        return (elapsed * 10000) / VESTING_DURATION;
    }

    /* ================================ EMERGENCY FUNCTIONS ================================ */

    /**
     * @dev Emergency token recovery (only non-VFIDE tokens)
     */
    function emergencyRecoverTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(vfideToken), "Cannot recover VFIDE tokens");
        IERC20(token).safeTransfer(owner(), amount);
    }

    /**
     * @dev Emergency ETH recovery
     */
    function emergencyRecoverETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    receive() external payable {
        // Contract can receive ETH but should not under normal circumstances
    }
}